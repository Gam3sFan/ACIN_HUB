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
    private var incomingBuffer = Data()

    // Packet identifier for SUBSCRIBE (incremental)
    private var packetIdentifier: UInt16 = 1

    // Callbacks
    public var onMessage: ((String, Data) -> Void)?
    public var onLog: ((String) -> Void)?
    public var onConnectionChange: ((Bool) -> Void)?

    // Reconnect strategy (simple)
    private var reconnectWorkItem: DispatchWorkItem?

    // Publish queue when not connected
    private var pendingPublishes: [(topic: String, payload: Data, retain: Bool)] = []

    private let mqttSubprotocols = ["mqtt", "mqttv3.1", "mqttv3.1.1"]
    private var hasOpenedWebSocket = false
    private lazy var clientIdentifier: String = {
        let cleaned = deviceId.replacingOccurrences(of: "-", with: "").lowercased()
        let suffix = cleaned.isEmpty ? UUID().uuidString.replacingOccurrences(of: "-", with: "") : cleaned
        let short = String(suffix.prefix(16))
        return "ios-\(short)"
    }()

    private static func normalizeTopicPath(_ value: String) -> String {
        value
            .split(separator: "/")
            .map { String($0) }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }

    private static func normalizeTopicComponent(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive], locale: .current)
        let lowered = folded.lowercased()
        let filtered = lowered.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return filtered.isEmpty ? "device" : filtered
    }

    init(wsURL: URL, username: String?, password: String?, topicPrefix: String, deviceId: String) {
        self.wsURL = wsURL
        self.username = username
        self.password = password
        self.topicPrefix = MQTTWebSocketClient.normalizeTopicPath(topicPrefix)
        self.deviceId = MQTTWebSocketClient.normalizeTopicComponent(deviceId)
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
        hasOpenedWebSocket = false

        // Sanitize and enforce proper WS scheme; many brokers require the MQTT subprotocol header
        // and will drop the socket during the handshake when it is missing.
        var url = sanitizedWSURL(wsURL)
        log("WS connecting to: \(url.absoluteString) (scheme=\(url.scheme ?? "nil"))")
        guard let scheme = url.scheme, scheme == "ws" || scheme == "wss" else {
            log("WS ERROR: URL scheme must be ws or wss (got: \(url.scheme ?? "nil"))")
            return
        }

        disconnect()
        // Request the MQTT subprotocol so brokers that require it accept the handshake.
        // URLSession will silently refuse the connection when the server rejects our subprotocol set,
        // so if a broker does not support this header we can reconsider making it configurable.
        let task = session.webSocketTask(with: url, protocols: mqttSubprotocols)
        self.task = task
        task.resume()

        // Start receiving to capture CONNACK and any control frames
        receiveNext()
    }

    func disconnect() {
        log("WS disconnect")
        onConnectionChange?(false)
        if isMQTTConnected {
            publishAvailability(online: false)
        }
        pingTimer?.invalidate(); pingTimer = nil
        isMQTTConnected = false
        hasOpenedWebSocket = false
        incomingBuffer.removeAll()
        if let task = task {
            task.cancel(with: .goingAway, reason: nil)
        }
        task = nil
    }

    /// Publish JSON status to topic `topicPrefix/deviceId/status`.
    func publishStatus(json: Data) {
        let topic = topicPath([deviceId, "status"])
        log("Status update prepared for \(topic) bytes=\(json.count)")
        publish(topic: topic, payload: json)
    }

    func publishAvailability(online: Bool) {
        let topic = topicPath([deviceId, "availability"])
        guard let data = "\(online ? "online" : "offline")".data(using: .utf8) else { return }
        log("Publishing availability \(online ? "online" : "offline")")
        publish(topic: topic, payload: data, retain: true)
    }

    func publish(topic: String, payload: Data, retain: Bool = false) {
        guard isMQTTConnected else {
            pendingPublishes.append((topic, payload, retain))
            log("Queued publish for \(topic) bytes=\(payload.count)")
            return
        }
        log("Publishing \(topic) bytes=\(payload.count) retain=\(retain)")
        let frame = mqttPublishFrame(topic: topic, payload: payload, retain: retain)
        sendBinary(frame)
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        hasOpenedWebSocket = true
        let proto = `protocol` ?? "nil"
        log("WS opened; negotiatedSubprotocol=\(proto); sending MQTT CONNECT as \(clientIdentifier)")
        sendConnect()
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isMQTTConnected = false
        hasOpenedWebSocket = false
        incomingBuffer.removeAll()
        log("WS closed: code=\(closeCode.rawValue)")
        if let reason = reason, let text = String(data: reason, encoding: .utf8) {
            log("WS close reason: \(text)")
        }
        onConnectionChange?(false)
        scheduleReconnect()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        log("WS task completed with error: \(error.localizedDescription)")
        isMQTTConnected = false
        hasOpenedWebSocket = false
        incomingBuffer.removeAll()
        onConnectionChange?(false)
        scheduleReconnect()
    }

    // MARK: - Internal

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                self.log("WS receive error: \(error.localizedDescription)")
                self.isMQTTConnected = false
                self.scheduleReconnect()
            case .success(let message):
                switch message {
                case .data(let data):
                    if data.count <= 32 {
                        self.log("WS RX bytes=\(data.count) hex=\(data.hexString)")
                    } else {
                        let prefix = data.prefix(32).hexString
                        self.log("WS RX bytes=\(data.count) prefix=\(prefix) ...")
                    }
                    self.incomingBuffer.append(data)
                    self.processIncomingBuffer()
                case .string(let text):
                    self.log("WS RX text=\(text)")
                @unknown default:
                    break
                }
                // Continue receiving
                self.receiveNext()
            }
        }
    }

    private func processIncomingBuffer() {
        while incomingBuffer.count >= 2 {
            var index = 1
            guard let remaining = decodeRemainingLength(incomingBuffer, index: &index) else {
                return // waiting for more bytes
            }
            let packetLength = index + remaining
            if incomingBuffer.count < packetLength {
                return // not enough data yet
            }
            let packet = incomingBuffer.subdata(in: 0..<packetLength)
            incomingBuffer.removeSubrange(0..<packetLength)
            handlePacket(packet)
        }
    }

    private func handlePacket(_ data: Data) {
        guard let first = data.first else { return }
        let packetType = first >> 4
        switch packetType {
        case 2: // CONNACK
            // Minimal parse: expect [0x20, remLen, ackFlags, returnCode]
            let ackFlags = data.count >= 3 ? data[2] : 0xFF
            let returnCode = data.count >= 4 ? data[3] : 0xFF
            if data.count < 4 {
                log("MQTT CONNACK malformed length=\(data.count) raw=\(data.hexString)")
            }
            if ackFlags == 0x00, returnCode == 0x00 {
                isMQTTConnected = true
                log("MQTT CONNACK success")
                onConnectionChange?(true)
                // Auto-subscribe to cmd topic
                let cmdTopic = topicPath([deviceId, "cmd"])
                subscribe(topic: cmdTopic)
                flushPendingPublishes()
                publishAvailability(online: true)
                startPing()
            } else {
                // Not authorized or error, try reconnect later
                log("MQTT CONNACK failure ackFlags=\(ackFlags) returnCode=\(returnCode) reason=\(connackReason(for: returnCode))")
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
        for item in queued { publish(topic: item.topic, payload: item.payload, retain: item.retain) }
    }

    private func scheduleReconnect() {
        pingTimer?.invalidate(); pingTimer = nil
        reconnectWorkItem?.cancel()
        log("Scheduling reconnect (opened=\(hasOpenedWebSocket))")
        let item = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: item)
    }

    private func sanitizedWSURL(_ input: URL) -> URL {
        guard var comps = URLComponents(url: input, resolvingAgainstBaseURL: false) else { return input }
        // Map http->ws and https->wss if the caller passed the wrong scheme
        if comps.scheme == "http" { comps.scheme = "ws" }
        if comps.scheme == "https" { comps.scheme = "wss" }
        // Remove a lone trailing slash path
        if comps.path == "/" { comps.path = "" }
        return comps.url ?? input
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
        // Will flag + retain for availability
        connectFlags |= 0x04 // Will flag
        connectFlags |= 0x20 // Will retain
        variableHeader.append(connectFlags)
        // Keep Alive
        variableHeader.append(contentsOf: [UInt8(keepAliveSeconds >> 8), UInt8(keepAliveSeconds & 0xFF)])

        // Payload: Client ID, Will Topic, Will Message, Username, Password
        var payload = Data()
        payload.append(mqttString(clientIdentifier))
        let willTopic = topicPath([deviceId, "availability"])
        let willMessage = "availability=offline"
        payload.append(mqttString(willTopic))
        payload.append(mqttString(willMessage))
        if let username = username { payload.append(mqttString(username)) }
        if let password = password { payload.append(mqttString(password)) }

        var remaining = Data()
        remaining.append(variableHeader)
        remaining.append(payload)

        var packet = Data([0x10])
        packet.append(encodeRemainingLength(remaining.count))
        packet.append(remaining)

        log("Sent CONNECT user=\(username ?? "(none)") keepAlive=\(keepAliveSeconds)")
        task.send(.data(packet)) { [weak self] error in
            if let error = error {
                self?.log("CONNECT send error: \(error.localizedDescription)")
            }
        }
    }

    private func sendPing() {
        let ping = Data([0xC0, 0x00]) // PINGREQ
        sendBinary(ping)
    }

    private func sendBinary(_ data: Data) {
        task?.send(.data(data)) { [weak self] error in
            if let error = error {
                self?.log("WS send error: \(error.localizedDescription)")
                self?.isMQTTConnected = false
                self?.scheduleReconnect()
            }
        }
    }

    private func mqttPublishFrame(topic: String, payload: Data, retain: Bool) -> Data {
        var variable = Data()
        variable.append(mqttString(topic))
        // QoS 0: no packet identifier
        var header = Data()
        var firstByte: UInt8 = 0x30 // PUBLISH, QoS 0
        if retain { firstByte |= 0x01 }
        header.append(firstByte)
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
        guard index <= data.count else { return (topic, Data()) }
        let payload = data.subdata(in: index..<data.count)
        return (topic, payload)
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
        print("[MQTT] \(message)")
    }

    private func topicPath(_ components: [String]) -> String {
        let prefixParts = topicPrefix.isEmpty ? [] : topicPrefix.split(separator: "/").map { String($0) }
        let componentParts = components.flatMap { component -> [String] in
            component
                .split(separator: "/")
                .map { String($0) }
                .filter { !$0.isEmpty }
        }
        return (prefixParts + componentParts).joined(separator: "/")
    }

    private func connackReason(for code: UInt8) -> String {
        switch code {
        case 0x00: return "Accepted"
        case 0x01: return "Unacceptable protocol version"
        case 0x02: return "Identifier rejected"
        case 0x03: return "Server unavailable"
        case 0x04: return "Bad username or password"
        case 0x05: return "Not authorized"
        default: return "Unknown (\(code))"
        }
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
        self.topicPrefix = MQTTWebSocketClient.normalizeTopicPath(topicPrefix)
        connect()
    }
}

/// Helper to build JSON status payloads consistently.
struct DeviceStatusBuilder {
    static func makeJSON(deviceName: String, batteryLevel: Int, batteryState: String, wifiIP: String?, online: Bool, topicBase: String, fragment: String, dimBrightness: Double, activeBrightness: Double, motionThreshold: Double, idleSeconds: Int, timestamp: Date = Date()) -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let dict: [String: Any] = [
            "topicBase": topicBase,
            "timestamp": iso.string(from: timestamp),
            "batteryLevel": batteryLevel,
            "online": online,
            "batteryState": batteryState,
            "deviceName": deviceName,
            "fragment": fragment,
            "wifiIP": wifiIP ?? "N/A",
            "settings": [
                "motionThreshold": motionThreshold,
                "activeBrightness": activeBrightness,
                "idleSeconds": idleSeconds,
                "dimBrightness": dimBrightness
            ]
        ]
        return (try? JSONSerialization.data(withJSONObject: dict, options: [])) ?? Data("{}".utf8)
    }
}

private extension Data {
    var hexString: String {
        self.map { String(format: "%02X", $0) }.joined()
    }
}
