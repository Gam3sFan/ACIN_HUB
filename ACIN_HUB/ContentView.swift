import SwiftUI
import WebKit
import SystemConfiguration
import Darwin
import Network
import AVFoundation
import CoreMotion

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

    @StateObject private var brightnessManager = IdleMotionBrightnessManager()

    // MQTT
    @State private var mqttClient: MQTTWebSocketClient? = nil
    @State private var mqttTimer: Timer? = nil

    @State private var showBanner = false
    @State private var bannerText = ""
    @State private var showAdvanced = false
    @State private var mqttLogs: [String] = []
    @State private var mqttConnected: Bool = false

    @State private var brokerURLString: String = UserDefaults.standard.string(forKey: "mqtt_ws_url") ?? "ws://10.107.188.153:8888"
    @State private var brokerUsername: String = UserDefaults.standard.string(forKey: "mqtt_ws_user") ?? "user"
    @State private var brokerPassword: String = UserDefaults.standard.string(forKey: "mqtt_ws_pass") ?? "user"
    @State private var brokerTopicPrefix: String = UserDefaults.standard.string(forKey: "mqtt_topic_prefix") ?? "office/ipads"

    @State private var statusIntervalMinutes: Int = {
        let v = UserDefaults.standard.integer(forKey: "mqtt_status_minutes")
        return v == 0 ? 60 : v
    }()

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
                                reloadTrigger += 1
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
                                publishMQTTStatusNow()
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
            mqttTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(statusIntervalMinutes * 60), repeats: true) { _ in
                publishMQTTStatusNow()
            }
        }
        .statusBar(hidden: true)
        .onReceive(networkMonitor.$isConnected.removeDuplicates()) { connected in
            if connected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { // wait a bit
                    reloadTrigger += 1
                }
            }
        }
        .onDisappear {
            NotificationCenter.default.removeObserver(self, name: UIDevice.batteryStateDidChangeNotification, object: nil)
            mqttTimer?.invalidate(); mqttTimer = nil
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
                            Text("Broker WebSocket URL")
                            TextField("ws://host:port", text: $brokerURLString)
                                .textInputAutocapitalization(.never)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            Text("Username")
                            TextField("username", text: $brokerUsername)
                                .textInputAutocapitalization(.never)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            Text("Password")
                            SecureField("password", text: $brokerPassword)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            Text("Topic Prefix")
                            TextField("office/ipads", text: $brokerTopicPrefix)
                                .textInputAutocapitalization(.never)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            Text("Invio stato ogni (min)")
                            HStack {
                                Slider(value: Binding(get: { Double(statusIntervalMinutes) }, set: { statusIntervalMinutes = Int($0) }), in: 1...240)
                                Text("\(statusIntervalMinutes)")
                                    .frame(width: 40, alignment: .trailing)
                            }
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
                                ), in: 10...600, step: 10)
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
                        UserDefaults.standard.set(brokerURLString, forKey: "mqtt_ws_url")
                        UserDefaults.standard.set(brokerUsername, forKey: "mqtt_ws_user")
                        UserDefaults.standard.set(brokerPassword, forKey: "mqtt_ws_pass")
                        UserDefaults.standard.set(brokerTopicPrefix, forKey: "mqtt_topic_prefix")
                        UserDefaults.standard.set(statusIntervalMinutes, forKey: "mqtt_status_minutes")
                        mqttTimer?.invalidate()
                        mqttTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(statusIntervalMinutes * 60), repeats: true) { _ in
                            publishMQTTStatusNow()
                        }
                        if let url = URL(string: brokerURLString), let client = mqttClient {
                            client.updateConfig(wsURL: url, username: brokerUsername, password: brokerPassword, topicPrefix: brokerTopicPrefix)
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
            UIScreen.main.brightness = 1.0
            let ts = Date()
            videoUploader.captureAndUpload(deviceName: deviceName, timestamp: ts)
            startAlarm()
            publishMQTTStatusNow()
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
        guard let url = URL(string: brokerURLString) else { return }
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "device"
        let client = MQTTWebSocketClient(wsURL: url, username: brokerUsername, password: brokerPassword, topicPrefix: brokerTopicPrefix, deviceId: deviceId)
        self.mqttClient = client

        client.onLog = { message in
            DispatchQueue.main.async { appendMQTTLog(message) }
        }
        client.onConnectionChange = { connected in
            DispatchQueue.main.async {
                mqttConnected = connected
                appendMQTTLog("Connection: \(connected ? "online" : "offline")")
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

    private func publishMQTTStatusNow() {
        guard let client = mqttClient else { return }
        let name = deviceName
        let batteryLevel = max(0, Int(UIDevice.current.batteryLevel * 100))
        let ip = getWiFiAddress()
        let topicBase = "office/ipads/\(UIDevice.current.identifierForVendor?.uuidString ?? "device")"
        let json = DeviceStatusBuilder.makeJSON(
            deviceName: name,
            batteryLevel: batteryLevel,
            batteryState: batteryStateString(),
            wifiIP: ip,
            online: true,
            topicBase: topicBase,
            fragment: fragment.isEmpty ? "kiosk/home" : fragment,
            dimBrightness: brightnessManager.dimBrightnessPercent,
            activeBrightness: brightnessManager.activeBrightnessPercent,
            motionThreshold: brightnessManager.motionSensitivity,
            idleSeconds: brightnessManager.idleSeconds
        )
        client.publishStatus(json: json)
    }

    private func appendMQTTLog(_ message: String) {
        struct StaticDF { static let df: DateFormatter = { let d = DateFormatter(); d.dateFormat = "HH:mm:ss"; return d }() }
        let line = "[\(StaticDF.df.string(from: Date()))] \(message)"
        mqttLogs.append(line)
        if mqttLogs.count > 500 { mqttLogs.removeFirst(mqttLogs.count - 500) }
    }

    private func handleMQTTCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "get_status" {
            publishMQTTStatusNow()
            return
        }
        if trimmed.lowercased().hasPrefix("alert:") {
            let msg = String(trimmed.dropFirst("alert:".count)).trimmingCharacters(in: .whitespaces)
            showBannerMessage(msg)
            return
        }
        if trimmed.lowercased().hasPrefix("set_fragment:") {
            let value = String(trimmed.dropFirst("set_fragment:".count)).trimmingCharacters(in: .whitespaces)
            fragment = value
            inputText = value
            UserDefaults.standard.set(fragment, forKey: "fragment")
            url = baseServerURL + (fragment.isEmpty ? "" : "#\(fragment)")
            reloadTrigger += 1
            return
        }
        if trimmed.lowercased() == "close_app" {
            appendMQTTLog("Closing app on command")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                exit(0)
            }
            return
        }
    }

    private func showBannerMessage(_ text: String) {
        bannerText = text
        withAnimation(.spring()) { showBanner = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            withAnimation(.easeInOut) { showBanner = false }
        }
    }
}
