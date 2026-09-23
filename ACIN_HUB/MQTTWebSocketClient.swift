import Foundation
import CocoaMQTT
import CocoaMQTTWebSocket

/// Lightweight wrapper around CocoaMQTT that keeps the previous app-facing API.
final class MQTTWebSocketClient: NSObject {
    // Public configuration
    var wsURL: URL
    var username: String?
    var password: String?
    var topicPrefix: String
    let deviceId: String

    // Callbacks
    public var onMessage: ((String, Data) -> Void)?
    public var onLog: ((String) -> Void)?
    public var onConnectionChange: ((Bool) -> Void)?

    // Internal state
    private var mqtt: CocoaMQTT?
    private var isMQTTConnected = false
    private var isConnecting = false
    private var pendingPublishes: [(topic: String, payload: Data, retain: Bool)] = []
    private var lastAvailabilitySent: (online: Bool, at: Date)?

    private let availabilityOnlineThrottle: TimeInterval = 5
    private let availabilityOfflineCooldown: TimeInterval = 5 * 60
    private let keepAliveSeconds: UInt16 = 60
    private let maxPendingPublishes = 50

    private lazy var clientIdentifier: String = {
        let cleaned = deviceId.replacingOccurrences(of: "-", with: "").lowercased()
        let suffix = cleaned.isEmpty ? UUID().uuidString.replacingOccurrences(of: "-", with: "") : cleaned
        let short = String(suffix.prefix(16))
        return "ios-\(short)"
    }()

    init(wsURL: URL, username: String?, password: String?, topicPrefix: String, deviceId: String) {
        self.wsURL = MQTTWebSocketClient.sanitizedWSURL(wsURL)
        self.username = username
        self.password = password
        self.topicPrefix = MQTTWebSocketClient.normalizeTopicPath(topicPrefix)
        self.deviceId = MQTTWebSocketClient.normalizeTopicComponent(deviceId)
        super.init()
    }

    deinit {
        disconnect(publishOffline: false)
    }

    func connect() {
        log("Connecting to \(wsURL.absoluteString)")
        if isMQTTConnected {
            log("Skipping connect: already connected")
            onConnectionChange?(true)
            return
        }
        if isConnecting {
            log("Skipping connect: connection already in progress")
            return
        }
        tearDownCurrentClient(publishOffline: false)
        let sanitizedURL = MQTTWebSocketClient.sanitizedWSURL(wsURL)
        guard let host = sanitizedURL.host else {
            log("WS ERROR: missing host in URL \(sanitizedURL.absoluteString)")
            return
        }
        let port = UInt16(sanitizedURL.port ?? (sanitizedURL.scheme == "wss" ? 443 : 80))
        var uri = sanitizedURL.path
        if uri.isEmpty { uri = "/" }
        if let query = sanitizedURL.query, !query.isEmpty {
            uri += "?\(query)"
        }

        let websocket = CocoaMQTTWebSocket(uri: uri)
        websocket.headers["Sec-WebSocket-Protocol"] = "mqtt"
        let originScheme = sanitizedURL.scheme == "wss" ? "https" : "http"
        let originPort = sanitizedURL.port ?? (sanitizedURL.scheme == "wss" ? 443 : 80)
        let origin = "\(originScheme)://\(host):\(originPort)"
        websocket.headers["Origin"] = origin
        if sanitizedURL.scheme == "wss" {
            websocket.enableSSL = true
        }
        let client = CocoaMQTT(clientID: clientIdentifier, host: host, port: port, socket: websocket)
        if sanitizedURL.scheme == "wss" {
            client.sslSettings = [kCFStreamSSLPeerName as String: host as NSString]
        }
        client.logLevel = .warning
        client.username = username
        client.password = password
        client.keepAlive = keepAliveSeconds
        client.cleanSession = true
        client.autoReconnect = false
        client.delegate = self
        client.enableSSL = sanitizedURL.scheme == "wss"

        let availabilityTopic = topicPath([deviceId, "availability"])
        client.willMessage = CocoaMQTTMessage(topic: availabilityTopic, string: "offline", qos: .qos0, retained: true)

        // Set isConnecting before invoking connect() so that any synchronous delegate
        // callback (didConnectAck/didDisconnect) fired from within connect() observes
        // the in-progress state correctly.
        isConnecting = true
        mqtt = client
        let started = client.connect(timeout: 30)
        log("connect() started=\(started)")
        if !started {
            isConnecting = false
        }
    }

    func disconnect(suppressReconnect: Bool = true, publishOffline: Bool = true) {
        log("WS disconnect (manual)")
        if publishOffline && isMQTTConnected {
            publishAvailability(online: false)
        }
        tearDownCurrentClient(publishOffline: false)
        onConnectionChange?(false)
    }

    /// Publish JSON status to topic `topicPrefix/deviceId/status`.
    func publishStatus(json: Data) {
        let topic = topicPath([deviceId, "status"])
        publish(topic: topic, payload: json)
    }

    func publishAvailability(online: Bool) {
        let topic = topicPath([deviceId, "availability"])
        guard let data = (online ? "online" : "offline").data(using: .utf8) else { return }
        let now = Date()
        if let last = lastAvailabilitySent, last.online == online {
            let minimum = online ? availabilityOnlineThrottle : availabilityOfflineCooldown
            if now.timeIntervalSince(last.at) < minimum {
                let remaining = minimum - now.timeIntervalSince(last.at)
                let seconds = max(1, Int(remaining.rounded()))
                log("Skipping availability \(online ? "online" : "offline") publish (throttled ~\(seconds)s)")
                return
            }
        }
        if !online && !isMQTTConnected {
            log("Skipping availability offline publish (not connected)")
            return
        }
        lastAvailabilitySent = (online, now)
        publish(topic: topic, payload: data, retain: true, queueIfDisconnected: online)
    }

    func publish(topic: String, payload: Data, retain: Bool = false) {
        publish(topic: topic, payload: payload, retain: retain, queueIfDisconnected: true)
    }

    // Allow runtime broker reconfiguration
    func updateConfig(wsURL: URL, username: String?, password: String?, topicPrefix: String) {
        log("Updating broker config")
        tearDownCurrentClient(publishOffline: false)
        self.wsURL = MQTTWebSocketClient.sanitizedWSURL(wsURL)
        self.username = username
        self.password = password
        self.topicPrefix = MQTTWebSocketClient.normalizeTopicPath(topicPrefix)
        connect()
    }

    private func publish(topic: String, payload: Data, retain: Bool, queueIfDisconnected: Bool) {
        guard isMQTTConnected, let mqtt = mqtt else {
            if queueIfDisconnected {
                if pendingPublishes.count >= maxPendingPublishes {
                    pendingPublishes.removeFirst(pendingPublishes.count - (maxPendingPublishes - 1))
                }
                pendingPublishes.append((topic, payload, retain))
                log("Queued publish for \(topic) bytes=\(payload.count)")
            } else {
                log("Dropped publish for \(topic) (disconnected)")
            }
            return
        }
        log("Publishing \(topic) bytes=\(payload.count) retain=\(retain)")
        let message = CocoaMQTTMessage(topic: topic, payload: [UInt8](payload), qos: .qos0, retained: retain)
        mqtt.publish(message)
    }

    private func flushPendingPublishes() {
        guard isMQTTConnected else { return }
        let queued = pendingPublishes
        pendingPublishes.removeAll()
        for item in queued {
            publish(topic: item.topic, payload: item.payload, retain: item.retain, queueIfDisconnected: false)
        }
    }

    private func tearDownCurrentClient(publishOffline: Bool) {
        if publishOffline && isMQTTConnected {
            publishAvailability(online: false)
        }
        mqtt?.delegate = nil
        mqtt?.disconnect()
        mqtt = nil
        isMQTTConnected = false
        isConnecting = false
        lastAvailabilitySent = nil
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

    private func log(_ message: String) {
        onLog?(message)
        print("[MQTT] \(message)")
    }

    private static func sanitizedWSURL(_ input: URL) -> URL {
        guard var comps = URLComponents(url: input, resolvingAgainstBaseURL: false) else { return input }
        if comps.scheme == "http" { comps.scheme = "ws" }
        if comps.scheme == "https" { comps.scheme = "wss" }
        if comps.path.isEmpty { comps.path = "" }
        return comps.url ?? input
    }

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
}

extension MQTTWebSocketClient: CocoaMQTTDelegate {
    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        log("MQTT didConnectAck: \(ack.rawValue) \(ack)")
        guard ack == .accept else {
            isMQTTConnected = false
            isConnecting = false
            onConnectionChange?(false)
            mqtt.disconnect()
            return
        }
        isMQTTConnected = true
        isConnecting = false
        onConnectionChange?(true)
        let cmdTopic = topicPath([deviceId, "cmd"])
        mqtt.subscribe(cmdTopic, qos: .qos0)
        flushPendingPublishes()
        publishAvailability(online: true)
    }

    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {
        log("MQTT didPublishMessage topic=\(message.topic) id=\(id)")
    }

    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {
        log("MQTT didPublishAck id=\(id)")
    }

    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        let payload = Data(message.payload)
        log("MQTT didReceiveMessage topic=\(message.topic) bytes=\(payload.count) id=\(id)")
        onMessage?(message.topic, payload)
    }

    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {
        let successTopics = (success.allKeys as? [String])?.joined(separator: ",") ?? "-"
        log("MQTT didSubscribe success=\(successTopics) failed=\(failed)")
    }

    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {
        log("MQTT didUnsubscribeTopics: \(topics)")
    }

    func mqttDidPing(_ mqtt: CocoaMQTT) {
        log("MQTT didPing")
    }

    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {
        log("MQTT didReceivePong")
    }

    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        isMQTTConnected = false
        isConnecting = false
        if let error = err as NSError? {
            log("MQTT didDisconnect error=\(error.domain) code=\(error.code) desc=\(error.localizedDescription)")
        } else {
            log("MQTT didDisconnect error=nil")
        }
        onConnectionChange?(false)
    }

    func mqtt(_ mqtt: CocoaMQTT, didStateChangeTo state: CocoaMQTTConnState) {
        log("MQTT state -> \(state)")
    }

    func mqtt(_ mqtt: CocoaMQTT, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
        log("MQTT didReceive trust: accepting server certificate")
        completionHandler(true)
    }

}

/// Helper to build JSON status payloads consistently.
struct DeviceStatusBuilder {
    static func makeJSON(deviceName: String, batteryLevel: Int, batteryState: String, wifiIP: String?, online: Bool, topicBase: String, fragment: String, dimBrightness: Double, activeBrightness: Double, motionThreshold: Double, idleSeconds: Int, appVersion: String, timestamp: Date = Date()) -> Data {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let dict: [String: Any] = [
            "topicBase": topicBase,
            "timestamp": iso.string(from: timestamp),
            "batteryLevel": batteryLevel,
            "online": online,
            "batteryState": batteryState,
            "deviceName": deviceName,
            "appVersion": appVersion,
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
