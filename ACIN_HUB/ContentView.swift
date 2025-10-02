import SwiftUI
import WebKit
import SystemConfiguration
import Darwin
import Network
import AVFoundation
import CoreMotion
import Foundation

func getWiFiAddress() -> String? {
    var address: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    if getifaddrs(&ifaddr) == 0 {
        var ptr = ifaddr
        while ptr != nil {
            let flags = Int32(ptr!.pointee.ifa_flags)
            let addr = ptr!.pointee.ifa_addr.pointee
            if (flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING) {
                if addr.sa_family == UInt8(AF_INET) || addr.sa_family == UInt8(AF_INET6) {
                    let name = String(cString: ptr!.pointee.ifa_name)
                    if name == "en0" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(ptr!.pointee.ifa_addr,
                                    socklen_t((addr.sa_family == UInt8(AF_INET)) ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size),
                                    &hostname,
                                    socklen_t(hostname.count),
                                    nil,
                                    socklen_t(0),
                                    NI_NUMERICHOST)
                        address = String(cString: hostname)
                    }
                }
            }
            ptr = ptr!.pointee.ifa_next
        }
        freeifaddrs(ifaddr)
    }
    return address
}

func makeMQTTDeviceSlug(from name: String) -> String {
    let folded = name.folding(options: [.diacriticInsensitive], locale: .current)
    let lowered = folded.lowercased()
    let filtered = lowered.filter { $0.isLetter || $0.isNumber }
    return filtered.isEmpty ? "device" : filtered
}

func normalizedTopicPrefix(_ prefix: String) -> String {
    prefix
        .split(separator: "/")
        .map { String($0) }
        .filter { !$0.isEmpty }
        .joined(separator: "/")
}

struct WebView: UIViewRepresentable {
    @Binding var urlString: String
    @Binding var reloadTrigger: Int      // just a counter; its value isn’t used
    
    func makeUIView(context: Context) -> WKWebView {
        WKWebView(frame: .zero)          // one instance for life of the SwiftUI view
    }
    
    func updateUIView(_ uiView: WKWebView, context: Context) {
        if let url = URL(string: urlString) {
            if uiView.url != url {
                uiView.load(URLRequest(url: url))
            } else if reloadTrigger != 0 {
                uiView.reload()
                DispatchQueue.main.async {   // bounce back onto SwiftUI thread
                    reloadTrigger = 0        // one-shot
                }
            }
        }
    }
}

// Publishes Wi‑Fi connectivity changes.
final class NetworkMonitor: ObservableObject {
    @Published var isConnected: Bool = false

    private let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private let queue = DispatchQueue(label: "NetworkMonitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = (path.status == .satisfied)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var showPopover = false
    @State private var inputText = ""
    @State private var fragment = UserDefaults.standard.string(forKey: "fragment") ?? ""
    @State private var url = ""
    @State private var reloadTrigger = 0
    @StateObject private var networkMonitor = NetworkMonitor()
    
    @State private var showPowerAlert = false
    @State private var isCharging = true
    @State private var alarmVisible = false
    @State private var alarmOpacity: Double = 1.0
    @State private var isPlayingAlarm = false
    @State private var deviceName: String = UIDevice.current.name
    @State private var deviceSlug: String = makeMQTTDeviceSlug(from: UIDevice.current.name)

    @StateObject private var brightnessManager = IdleMotionBrightnessManager()

    // MQTT
    @State private var mqttClient: MQTTWebSocketClient? = nil
    @State private var mqttTimer: Timer? = nil
    @State private var mqttReconnectTimer: Timer? = nil
    @State private var mqttAvailabilityTimer: Timer? = nil

    @State private var showBanner = false
    @State private var bannerText = ""
    @State private var showAdvanced = false
    @State private var mqttLogs: [String] = []
    @State private var mqttConnected: Bool = false

    @State private var brokerUsername: String = UserDefaults.standard.string(forKey: "mqtt_ws_user") ?? "user"
    @State private var brokerPassword: String = UserDefaults.standard.string(forKey: "mqtt_ws_pass") ?? "user"
    @State private var brokerTopicPrefix: String = {
        let stored = UserDefaults.standard.string(forKey: "mqtt_topic_prefix") ?? "office/ipads"
        return normalizedTopicPrefix(stored)
    }()

    @State private var statusIntervalMinutes: Int = 60
    @State private var lastMQTTStatusSentAt: Date = .distantPast
    @State private var lastMQTTConnectAttempt: Date = .distantPast
    @State private var lastAvailabilitySentAt: Date = .distantPast
    @State private var lastWebReloadAt: Date = .distantPast

    private let alarmPlayer = AlarmPlayer()
    private let videoUploader = VideoCaptureUploader(uploadURL: URL(string: "http://10.107.188.153:3006/upload")!)

    private let baseServerURL = "http://10.107.188.153"

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            WebView(urlString: $url, reloadTrigger: $reloadTrigger)
                .contentShape(Rectangle())
                .onTapGesture { brightnessManager.noteUserInteraction() }
            Button(action: { showPopover = true }) {
                Image(systemName: "gear")
                    .frame(width: 50, height: 50)
                    .opacity(0.01)
            }
            .popover(isPresented: $showPopover) {
                ScrollView {
                    VStack(spacing: 10) {
                        Text(UIDevice.current.name)
                            .font(.system(.body, design: .monospaced))
                        if let ip = getWiFiAddress() {
                            Text(ip)
                                .font(.system(.body, design: .monospaced))
                        } else {
                            Text("N/A")
                                .font(.system(.body, design: .monospaced))
                        }
                        TextField("Nome Stanza", text: $inputText)
                            .textInputAutocapitalization(.never)
                            .textFieldStyle(RoundedBorderTextFieldStyle())
                            .padding(.top, 10)
                        HStack(spacing: 12) {
                            // Save (OK)
                            Button(action: {
                                fragment = inputText
                                UserDefaults.standard.set(fragment, forKey: "fragment")
                                url = baseServerURL + (fragment.isEmpty ? "" : "#\(fragment)")
                                showPopover = false
                            }) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title2)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .tint(.green)
                            .accessibilityLabel("Salva")

                            // Refresh
                            Button(action: {
                                triggerWebReload(force: true)
                            }) {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                    .font(.title2)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .tint(.orange)
                            .accessibilityLabel("Ricarica")

                            // Advanced settings
                            Button(action: {
                                // Dismiss popover first then present sheet
                                showPopover = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    showAdvanced = true
                                }
                            }) {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.title2)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .tint(.blue)
                            .accessibilityLabel("Impostazioni avanzate")
                        }
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Battery: \(Int(UIDevice.current.batteryLevel * 100))% - \(batteryStateString())")
                                .font(.footnote)
                            Button("Invia stato MQTT ora") {
                                publishMQTTStatus(force: true)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .tint(.purple)
                        }
                    }
                    .padding()
                }
                .frame(width: 360, height: 300)
            }
            .padding()
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
                brightnessManager.noteUserInteraction()
            })
            if showPowerAlert {
                ZStack {
                    Color.red.edgesIgnoringSafeArea(.all)
                        .allowsHitTesting(false)
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 120, height: 120)
                            .foregroundColor(.white)
                        Text("CONNECT THE POWER ADAPTER")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .allowsHitTesting(false)

                    VStack {
                        Spacer()
                        Button(action: {
                            stopAlarm()
                        }) {
                            Text("OK")
                                .font(.title2.bold())
                                .padding(.horizontal, 32)
                                .padding(.vertical, 12)
                                .background(Color.white)
                                .foregroundColor(.red)
                                .cornerRadius(10)
                        }
                        .padding(.bottom, 40)
                    }
                }
                .transition(.opacity)
            }
            if showBanner {
                VStack {
                    HStack {
                        Image(systemName: "bell.fill").foregroundColor(.white)
                        Text(bannerText)
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding()
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(12)
                    .padding(.horizontal)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            url = baseServerURL + (fragment.isEmpty ? "" : "#\(fragment)")
            inputText = fragment
            let currentName = UIDevice.current.name
            deviceName = currentName
            deviceSlug = makeMQTTDeviceSlug(from: currentName)
            brokerTopicPrefix = normalizedTopicPrefix(brokerTopicPrefix)
            statusIntervalMinutes = 60
            UserDefaults.standard.set(statusIntervalMinutes, forKey: "mqtt_status_minutes")
            
            UIDevice.current.isBatteryMonitoringEnabled = true
            isCharging = (UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full)
            NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { _ in
                handleBatteryChange()
            }
            // MQTT setup
            setupMQTT()
            // Add videoUploader log callback to MQTT log view
            videoUploader.onLog = { msg in appendMQTTLog("Video: \(msg)") }
            // Periodic MQTT status every X minutes
            mqttTimer?.invalidate()
            mqttTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(60 * 60), repeats: true) { _ in
                publishMQTTStatus()
            }
            mqttReconnectTimer?.invalidate()
            mqttReconnectTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                ensureMQTTConnection()
            }
            ensureMQTTConnection(force: true)
            mqttAvailabilityTimer?.invalidate()
            mqttAvailabilityTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(30 * 60), repeats: true) { _ in
                sendAvailabilityHeartbeat()
            }
            sendAvailabilityHeartbeat(force: true)
        }
        .statusBar(hidden: true)
        .onReceive(networkMonitor.$isConnected.removeDuplicates()) { connected in
            if connected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { // wait a bit
                    triggerWebReload()
                    ensureMQTTConnection(force: true)
                    sendAvailabilityHeartbeat(force: true)
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                ensureMQTTConnection(force: true)
                sendAvailabilityHeartbeat(force: true)
            }
        }
        .onDisappear {
            NotificationCenter.default.removeObserver(self, name: UIDevice.batteryStateDidChangeNotification, object: nil)
            mqttTimer?.invalidate(); mqttTimer = nil
            mqttReconnectTimer?.invalidate(); mqttReconnectTimer = nil
            mqttAvailabilityTimer?.invalidate(); mqttAvailabilityTimer = nil
        }
        .sheet(isPresented: $showAdvanced) {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Impostazioni avanzate").font(.title2.bold())
                    Spacer()
                    Button(action: { showAdvanced = false }) {
                        Image(systemName: "xmark.circle.fill").font(.title2)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
                .padding(.top)

                // Body
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Circle().fill(mqttConnected ? Color.green : Color.red).frame(width: 10, height: 10)
                            Text(mqttConnected ? "Connesso" : "Disconnesso").font(.subheadline)
                        }
                        Group {
                            Text("Topic Prefix")
                            TextField("office/ipads", text: $brokerTopicPrefix)
                                .textInputAutocapitalization(.never)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            Text("Invio stato ogni 60 minuti (fisso)")
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Luminosità & Movimento").font(.headline)
                            HStack {
                                Label("Dim", systemImage: "sun.min.fill")
                                Spacer()
                                Stepper("\(brightnessManager.dimBrightnessPercent)%", value: Binding(
                                    get: { brightnessManager.dimBrightnessPercent },
                                    set: { brightnessManager.dimBrightnessPercent = $0 }
                                ), in: 0...100, step: 1)
                            }
                            HStack {
                                Label("Active", systemImage: "sun.max.fill")
                                Spacer()
                                Stepper("\(brightnessManager.activeBrightnessPercent)%", value: Binding(
                                    get: { brightnessManager.activeBrightnessPercent },
                                    set: { brightnessManager.activeBrightnessPercent = $0 }
                                ), in: 0...100, step: 1)
                            }
                            HStack {
                                Label("Motion", systemImage: "figure.walk")
                                Spacer()
                                Stepper("\(brightnessManager.motionSensitivity)", value: Binding(
                                    get: { brightnessManager.motionSensitivity },
                                    set: { brightnessManager.motionSensitivity = $0 }
                                ), in: 1...10, step: 1)
                            }
                            HStack {
                                Label("Idle s", systemImage: "clock")
                                Spacer()
                                Stepper("\(brightnessManager.idleSeconds)s", value: Binding(
                                    get: { brightnessManager.idleSeconds },
                                    set: { brightnessManager.idleSeconds = $0 }
                                ), in: 20...600, step: 10)
                            }
                        }

                        Divider()
                        Text("Riepilogo impostazioni").font(.headline)
                        Text("Fragment: \(fragment.isEmpty ? "(vuoto)" : fragment)")
                        Text("Luminosità: dim=\(brightnessManager.dimBrightnessPercent)% active=\(brightnessManager.activeBrightnessPercent)%")
                        Text("Motion sensitivity: \(brightnessManager.motionSensitivity)  Idle: \(brightnessManager.idleSeconds)s")
                        if let ip = getWiFiAddress() { Text("WiFi IP: \(ip)") }
                        Text("Batteria: \(Int(UIDevice.current.batteryLevel * 100))% - \(batteryStateString())")
                        Divider()
                        Text("Log MQTT").font(.headline)
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(mqttLogs.enumerated()), id: \.offset) { _, line in
                                    Text(line).font(.system(.footnote, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(minHeight: 200, maxHeight: 300)
                    }
                    .padding()
                }

                // Footer
                HStack {
                    Button(action: { mqttLogs.removeAll() }) {
                        Label("Pulisci log", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button(action: { showAdvanced = false }) {
                        Label("Chiudi", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    Button(action: {
                        let prefix = normalizedTopicPrefix(brokerTopicPrefix)
                        brokerTopicPrefix = prefix
                        UserDefaults.standard.set(prefix, forKey: "mqtt_topic_prefix")
                        statusIntervalMinutes = 60
                        UserDefaults.standard.set(statusIntervalMinutes, forKey: "mqtt_status_minutes")
                        mqttTimer?.invalidate()
                        mqttTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(60 * 60), repeats: true) { _ in
                            publishMQTTStatus()
                        }
                        mqttReconnectTimer?.invalidate()
                        mqttReconnectTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                            ensureMQTTConnection()
                        }
                        ensureMQTTConnection(force: true)
                        mqttAvailabilityTimer?.invalidate()
                        mqttAvailabilityTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(30 * 60), repeats: true) { _ in
                            sendAvailabilityHeartbeat()
                        }
                        sendAvailabilityHeartbeat(force: true)
                        if let url = URL(string: "ws://10.107.188.153:8888"), let client = mqttClient {
                            client.updateConfig(wsURL: url, username: "user", password: "user", topicPrefix: prefix)
                        } else {
                            setupMQTT()
                        }
                        showAdvanced = false
                    }) {
                        Label("Salva & Applica", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
            .frame(minWidth: 500, minHeight: 600)
        }
    }

    private func handleBatteryChange() {
        let charging = (UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full)
        if isCharging && !charging {
            // Just unplugged
            showPowerAlert = true
            brightnessManager.setForcedBrightnessPercent(100)
            let ts = Date()
            videoUploader.captureAndUpload(deviceName: deviceName, timestamp: ts)
            startAlarm()
            publishMQTTStatus(force: true)
        }
        if !isCharging && charging {
            brightnessManager.setForcedBrightnessPercent(nil)
        }
        isCharging = charging
        if charging {
            stopAlarm()
        }
    }

    private func startAlarm() {
        if !isPlayingAlarm {
            isPlayingAlarm = true
            alarmPlayer.start(volumeRampDuration: 10)
        }
    }

    private func stopAlarm() {
        isPlayingAlarm = false
        showPowerAlert = false
        alarmPlayer.stop()
    }

    private func batteryStateString() -> String {
        switch UIDevice.current.batteryState {
        case .unknown: return "unknown"
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        @unknown default: return "unknown"
        }
    }

    private func setupMQTT() {
        guard let url = URL(string: "ws://10.107.188.153:8888") else { return }
        let slug = deviceSlug.isEmpty ? makeMQTTDeviceSlug(from: deviceName) : deviceSlug
        deviceSlug = slug
        let prefix = normalizedTopicPrefix(brokerTopicPrefix)
        brokerTopicPrefix = prefix
        let client = MQTTWebSocketClient(wsURL: url, username: "user", password: "user", topicPrefix: prefix, deviceId: slug)
        self.mqttClient = client

        client.onLog = { message in
            DispatchQueue.main.async { appendMQTTLog(message) }
        }
        client.onConnectionChange = { connected in
            DispatchQueue.main.async {
                mqttConnected = connected
                appendMQTTLog("Connection: \(connected ? "online" : "offline")")
                if connected {
                    publishMQTTStatus()
                    sendAvailabilityHeartbeat(force: true)
                } else {
                    lastAvailabilitySentAt = .distantPast
                }
            }
        }
        client.onMessage = { topic, payload in
            let text = String(data: payload, encoding: .utf8) ?? "(binary \(payload.count) bytes)"
            DispatchQueue.main.async {
                appendMQTTLog("RX \(topic): \(text)")
                handleMQTTCommand(text)
            }
        }

        client.connect()
    }

    private func ensureMQTTConnection(force: Bool = false) {
        let now = Date()
        let minInterval: TimeInterval = 10
        if !force, now.timeIntervalSince(lastMQTTConnectAttempt) < minInterval {
            return
        }
        if mqttClient == nil {
            setupMQTT()
            lastMQTTConnectAttempt = now
            return
        }
        if mqttConnected {
            return
        }
        lastMQTTConnectAttempt = now
        mqttClient?.connect()
    }

    private func sendAvailabilityHeartbeat(force: Bool = false) {
        guard mqttConnected, let client = mqttClient else { return }
        let now = Date()
        let minInterval: TimeInterval = force ? 5 : 60
        if now.timeIntervalSince(lastAvailabilitySentAt) < minInterval {
            return
        }
        lastAvailabilitySentAt = now
        client.publishAvailability(online: true)
    }

    private func publishMQTTStatus(force: Bool = false) {
        guard let client = mqttClient else { return }
        let now = Date()
        if !force {
            let minInterval: TimeInterval = 10
            if now.timeIntervalSince(lastMQTTStatusSentAt) < minInterval {
                appendMQTTLog("Status publish skipped (throttled)")
                return
            }
        }
        lastMQTTStatusSentAt = now
        let name = deviceName
        let slug = deviceSlug.isEmpty ? makeMQTTDeviceSlug(from: name) : deviceSlug
        deviceSlug = slug
        let prefix = normalizedTopicPrefix(brokerTopicPrefix)
        let topicBaseSegments = [prefix, slug].filter { !$0.isEmpty }
        let topicBase = topicBaseSegments.joined(separator: "/")
        let rawBattery = UIDevice.current.batteryLevel
        let batteryLevel: Int
        if rawBattery < 0 {
            batteryLevel = -1
        } else {
            batteryLevel = Int(round(rawBattery * 100))
        }
        let ip = getWiFiAddress()
        let dimBrightness = Double(brightnessManager.dimBrightnessPercent) / 100.0
        let activeBrightness = Double(brightnessManager.activeBrightnessPercent) / 100.0
        let motionThreshold = 0.15 / Double(max(1, brightnessManager.motionSensitivity))
        let appVersion: String = {
            let info = Bundle.main.infoDictionary
            let short = info?["CFBundleShortVersionString"] as? String
            let build = info?["CFBundleVersion"] as? String
            switch (short, build) {
            case let (s?, b?) where s != b:
                return "\(s) (\(b))"
            case let (s?, _):
                return s
            case let (_, b?):
                return b
            default:
                return "unknown"
            }
        }()
        let json = DeviceStatusBuilder.makeJSON(
            deviceName: name,
            batteryLevel: batteryLevel,
            batteryState: batteryStateString(),
            wifiIP: ip,
            online: true,
            topicBase: topicBase,
            fragment: fragment.isEmpty ? "insight" : fragment,
            dimBrightness: dimBrightness,
            activeBrightness: activeBrightness,
            motionThreshold: motionThreshold,
            idleSeconds: brightnessManager.idleSeconds,
            appVersion: appVersion
        )
        client.publishStatus(json: json)
    }

    private func triggerWebReload(force: Bool = false) {
        let now = Date()
        let minInterval: TimeInterval = force ? 0 : 60
        if !force && now.timeIntervalSince(lastWebReloadAt) < minInterval {
            return
        }
        lastWebReloadAt = now
        reloadTrigger &+= 1
    }

    private func appendMQTTLog(_ message: String) {
        struct StaticDF { static let df: DateFormatter = { let d = DateFormatter(); d.dateFormat = "HH:mm:ss"; return d }() }
        let line = "[\(StaticDF.df.string(from: Date()))] \(message)"
        mqttLogs.append(line)
        if mqttLogs.count > 500 { mqttLogs.removeFirst(mqttLogs.count - 500) }
    }

    private func handleMQTTCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if handleStructuredMQTTCommand(trimmed) { return }
        if handleSimpleMQTTCommand(trimmed) { return }
        appendMQTTLog("Ignored MQTT command: \(trimmed)")
    }

    private func handleStructuredMQTTCommand(_ command: String) -> Bool {
        guard command.first == "{" else { return false }
        guard let data = command.data(using: .utf8) else { return false }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            appendMQTTLog("Failed to parse JSON command: \(command)")
            return false
        }

        if let raw = (json["command"] as? String) ?? (json["action"] as? String) ?? (json["cmd"] as? String) {
            return handleSimpleMQTTCommand(raw)
        }
        if let closeRequested = json["close_app"] as? Bool, closeRequested {
            return handleSimpleMQTTCommand("close_app")
        }
        return false
    }

    private func handleSimpleMQTTCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        appendMQTTLog("Command received: \(command)")
        if lower == "get_status" {
            publishMQTTStatus(force: true)
            return true
        }
        if lower.hasPrefix("alert:") {
            let msg = String(command.dropFirst("alert:".count)).trimmingCharacters(in: .whitespaces)
            showBannerMessage(msg)
            return true
        }
        if lower.hasPrefix("set_fragment:") {
            let value = String(command.dropFirst("set_fragment:".count)).trimmingCharacters(in: .whitespaces)
            fragment = value
            inputText = value
            UserDefaults.standard.set(fragment, forKey: "fragment")
            url = baseServerURL + (fragment.isEmpty ? "" : "#\(fragment)")
            triggerWebReload(force: true)
            return true
        }
        if lower == "close_app" {
            appendMQTTLog("Closing app on command")
            mqttClient?.disconnect()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                exit(0)
            }
            return true
        }
        return false
    }

    private func showBannerMessage(_ text: String) {
        bannerText = text
        withAnimation(.spring()) { showBanner = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            withAnimation(.easeInOut) { showBanner = false }
        }
    }
}
