import Foundation
import Network

/// Minimal MQTT 3.1.1 client over WebSocket (QoS 0 publish only).
/// Compatible with iOS 15 (no async/await).
final class MQTTWebSocketClient: NSObject, URLSessionWebSocketDelegate {
    // Public configuration
    var wsURL: URL
    var username: String?
    var password: String?
    var topicPrefix: String
    let deviceId: String

    // State
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var isMQTTConnected: Bool = false
    private var keepAliveSeconds: UInt16 = 60

    // Packet identifier for SUBSCRIBE (incremental)
    private var packetIdentifier: UInt16 = 1

    // Callbacks
    public var onMessage: ((String, Data) -> Void)?
    public var onLog: ((String) -> Void)?
    public var onConnectionChange: ((Bool) -> Void)?

    // Reconnect strategy (simple)
    private var reconnectWorkItem: DispatchWorkItem?

    // Publish queue when not connected
    private var pendingPublishes: [(topic: String, payload: Data)] = []

    init(wsURL: URL, username: String?, password: String?, topicPrefix: String, deviceId: String) {
        self.wsURL = wsURL
        self.username = username
        self.password = password
        self.topicPrefix = topicPrefix
        self.deviceId = deviceId
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue())
    }

    deinit {
        disconnect()
    }

    // MARK: - Public API

    func connect() {
        log("WS connecting to: \(wsURL.absoluteString)")
        disconnect()
        let task = session.webSocketTask(with: wsURL, protocols: ["mqtt"])
        self.task = task
        task.resume()
        // Start receiving to capture CONNACK and any control frames
        receiveNext()
        // Send MQTT CONNECT once the WebSocket is open (URLSession delegate will call didOpenWithProtocol)
        // But some servers accept immediate send; we'll also schedule a small delay as fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.sendConnect()
        }
    }

    func disconnect() {
        log("WS disconnect")
        onConnectionChange?(false)
        pingTimer?.invalidate(); pingTimer = nil
        isMQTTConnected = false
        if let task = task {
            task.cancel(with: .goingAway, reason: nil)
        }
        task = nil
    }

    /// Publish JSON status to topic `topicPrefix/deviceId/status`.
    func publishStatus(json: Data) {
        let topic = "\(topicPrefix)/\(deviceId)/status"
        publish(topic: topic, payload: json)
    }

    func publish(topic: String, payload: Data) {
        guard isMQTTConnected else {
            pendingPublishes.append((topic, payload))
            return
        }
        let frame = mqttPublishFrame(topic: topic, payload: payload)
        sendBinary(frame)
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        // WebSocket opened; attempt MQTT CONNECT
        log("WS opened; sending MQTT CONNECT")
        sendConnect()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isMQTTConnected = false
        log("WS closed: code=\(closeCode.rawValue)")
        onConnectionChange?(false)
        scheduleReconnect()
    }

    // MARK: - Internal

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                self.isMQTTConnected = false
                self.scheduleReconnect()
            case .success(let message):
                switch message {
                case .data(let data):
                    self.handleIncoming(data)
                case .string:
                    // MQTT should be binary; ignore
                    break
                @unknown default:
                    break
                }
                // Continue receiving
                self.receiveNext()
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        guard let first = data.first else { return }
        let packetType = first >> 4
        switch packetType {
        case 2: // CONNACK
            // Minimal parse: expect [0x20, remLen, ackFlags, returnCode]
            if data.count >= 4, data[2] == 0x00, data[3] == 0x00 {
                isMQTTConnected = true
                log("MQTT CONNACK success")
                onConnectionChange?(true)
                // Auto-subscribe to cmd topic
                let cmdTopic = "\(topicPrefix)/\(deviceId)/cmd"
                subscribe(topic: cmdTopic)
                flushPendingPublishes()
                startPing()
            } else {
                // Not authorized or error, try reconnect later
                isMQTTConnected = false
                scheduleReconnect()
            }
        case 3: // PUBLISH
            if let (topic, payload) = parsePublish(data) {
                log("MQTT PUBLISH topic=\(topic) bytes=\(payload.count)")
                onMessage?(topic, payload)
            }
        case 13: // PINGRESP
            // ignore
            break
        default:
            // ignore other packets for now
            break
        }
    }

    private func flushPendingPublishes() {
        guard isMQTTConnected else { return }
        let queued = pendingPublishes
        pendingPublishes.removeAll()
        for item in queued { publish(topic: item.topic, payload: item.payload) }
    }

    private func scheduleReconnect() {
        pingTimer?.invalidate(); pingTimer = nil
        reconnectWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: item)
    }

    private func startPing() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(15, Int(keepAliveSeconds) / 2)), repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }

    private func sendConnect() {
        guard let task = task else { return }
        // MQTT CONNECT 3.1.1 (protocol level 4)
        var variableHeader = Data()
        variableHeader.append(mqttString("MQTT")) // Protocol Name
        variableHeader.append(0x04)               // Protocol Level 4
        var connectFlags: UInt8 = 0
        if let _ = username { connectFlags |= 0x80 }
        if let _ = password { connectFlags |= 0x40 }
        // Clean session
        connectFlags |= 0x02
        variableHeader.append(connectFlags)
        // Keep Alive
        variableHeader.append(contentsOf: [UInt8(keepAliveSeconds >> 8), UInt8(keepAliveSeconds & 0xFF)])

        // Payload: Client ID, Username, Password
        var payload = Data()
        payload.append(mqttString("ios-\(deviceId)"))
        if let username = username { payload.append(mqttString(username)) }
        if let password = password { payload.append(mqttString(password)) }

        var remaining = Data()
        remaining.append(variableHeader)
        remaining.append(payload)

        var packet = Data([0x10])
        packet.append(encodeRemainingLength(remaining.count))
        packet.append(remaining)

        task.send(.data(packet)) { _ in }
    }

    private func sendPing() {
        let ping = Data([0xC0, 0x00]) // PINGREQ
        sendBinary(ping)
    }

    private func sendBinary(_ data: Data) {
        task?.send(.data(data)) { [weak self] error in
            if error != nil {
                self?.isMQTTConnected = false
                self?.scheduleReconnect()
            }
        }
    }

    private func mqttPublishFrame(topic: String, payload: Data) -> Data {
        var variable = Data()
        variable.append(mqttString(topic))
        // QoS 0: no packet identifier
        var header = Data()
        header.append(0x30) // PUBLISH, QoS 0
        let remainingLen = variable.count + payload.count
        header.append(encodeRemainingLength(remainingLen))
        var out = Data()
        out.append(header)
        out.append(variable)
        out.append(payload)
        return out
    }

    private func mqttString(_ s: String) -> Data {
        let bytes = Array(s.utf8)
        let lenHi = UInt8((bytes.count >> 8) & 0xFF)
        let lenLo = UInt8(bytes.count & 0xFF)
        var data = Data([lenHi, lenLo])
        data.append(contentsOf: bytes)
        return data
    }

    private func encodeRemainingLength(_ length: Int) -> Data {
        var x = length
        var out = Data()
        repeat {
            var digit = UInt8(x % 128)
            x /= 128
            if x > 0 { digit |= 0x80 }
            out.append(digit)
        } while x > 0
        return out
    }

    private func subscribe(topic: String) {
        // MQTT SUBSCRIBE (0x82), QoS 1 required by spec for SUBSCRIBE itself; we can still request QoS 0 for topic
        let packetId = nextPacketId()
        var payload = Data()
        payload.append(mqttString(topic))
        payload.append(0x00) // requested QoS 0

        var variable = Data()
        variable.append(contentsOf: [UInt8(packetId >> 8), UInt8(packetId & 0xFF)])
        variable.append(payload)

        var header = Data([0x82])
        header.append(encodeRemainingLength(variable.count))

        var frame = Data()
        frame.append(header)
        frame.append(variable)
        sendBinary(frame)
        log("MQTT SUBSCRIBE \(topic) pid=\(packetId)")
    }

    private func nextPacketId() -> UInt16 {
        packetIdentifier &+= 1
        if packetIdentifier == 0 { packetIdentifier = 1 }
        return packetIdentifier
    }

    private func parsePublish(_ data: Data) -> (String, Data)? {
        guard data.count >= 2 else { return nil }
        let header = data[0]
        let qos = (header & 0x06) >> 1
        var index = 1
        guard let remaining = decodeRemainingLength(data, index: &index) else { return nil }
        guard index + remaining <= data.count else { return nil }
        // Topic
        guard index + 2 <= data.count else { return nil }
        let topicLen = Int(data[index]) << 8 | Int(data[index+1])
        index += 2
        guard index + topicLen <= data.count else { return nil }
        let topicData = data.subdata(in: index..<(index + topicLen))
        let topic = String(data: topicData, encoding: .utf8) ?? ""
        index += topicLen
        if qos > 0 {
            // skip packet identifier
            index += 2
        }
        let payloadEnd = min(data.count, index + remaining - (index - 1))
        if payloadEnd > index {
            let payload = data.subdata(in: index..<payloadEnd)
            return (topic, payload)
        }
        return (topic, Data())
    }

    private func decodeRemainingLength(_ data: Data, index: inout Int) -> Int? {
        var multiplier = 1
        var value = 0
        var digit: UInt8 = 0
        repeat {
            guard index < data.count else { return nil }
            digit = data[index]
            index += 1
            value += Int(digit & 127) * multiplier
            multiplier *= 128
            if multiplier > 128*128*128*128 { return nil }
        } while (digit & 128) != 0
        return value
    }

    private func log(_ message: String) {
        onLog?(message)
    }

    // Allow runtime broker reconfiguration
    func updateConfig(wsURL: URL, username: String?, password: String?, topicPrefix: String) {
        log("Updating broker config")
        self.disconnect()
        self.task = nil
        self.isMQTTConnected = false
        self.wsURL = wsURL
        self.username = username
        self.password = password
        self.topicPrefix = topicPrefix
        connect()
    }
}

/// Helper to build JSON status payloads consistently.
struct DeviceStatusBuilder {
    static func makeJSON(deviceName: String, batteryLevel: Int, batteryState: String, wifiIP: String?, online: Bool, topicBase: String, fragment: String, dimBrightness: Int, activeBrightness: Int, motionThreshold: Int, idleSeconds: Int, timestamp: Date = Date()) -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let dict: [String: Any] = [
            "deviceName": deviceName,
            "batteryLevel": batteryLevel,
            "batteryState": batteryState,
            "wifiIP": wifiIP ?? "N/A",
            "online": online,
            "topicBase": topicBase,
            "fragment": fragment,
            "settings": [
                "dimBrightness": dimBrightness,
                "activeBrightness": activeBrightness,
                "motionThreshold": motionThreshold,
                "idleSeconds": idleSeconds
            ],
            "timestamp": iso.string(from: timestamp)
        ]
        return (try? JSONSerialization.data(withJSONObject: dict, options: [])) ?? Data("{}".utf8)
    }
}
