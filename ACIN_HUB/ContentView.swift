import SwiftUI
import WebKit
import SystemConfiguration
import Darwin
import Network

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
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            WebView(urlString: $url, reloadTrigger: $reloadTrigger)
            Button(action: { showPopover = true }) {
                Image(systemName: "gear")
                    .frame(width: 50, height: 50)
                    .opacity(0.01)
            }
            .popover(isPresented: $showPopover) {
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
                    Button("OK") {
                        fragment = inputText
                        UserDefaults.standard.set(fragment, forKey: "fragment")
                        url = "http://10.107.188.153" + (fragment.isEmpty ? "" : "#\(fragment)")
                        showPopover = false
                    }
                    Button("↻") {
                        reloadTrigger += 1
                    }
                }
                .frame(width: 300, height: 200)
                .padding()
            }
            .padding()
        }
        .onAppear {
            url = "http://10.107.188.153" + (fragment.isEmpty ? "" : "#\(fragment)")
            inputText = fragment
        }
        .statusBar(hidden: true)
        .onReceive(networkMonitor.$isConnected.removeDuplicates()) { connected in
            if connected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { // wait a bit
                    reloadTrigger += 1
                }
            }
        }
    }
}
