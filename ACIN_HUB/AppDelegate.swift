import UIKit

// Handles background URLSession events and calls completion handler when finished.
final class BackgroundSessionHandler: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    static let shared = BackgroundSessionHandler()
    var onAllEventsComplete: (() -> Void)?

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // All background events for this session have been delivered.
        DispatchQueue.main.async { [weak self] in
            self?.onAllEventsComplete?()
            self?.onAllEventsComplete = nil
        }
    }
}

class AppDelegate: UIResponder, UIApplicationDelegate {
    private var bgCompletionHandler: (() -> Void)?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        return true
    }

    // Called when background URLSession events are ready to be delivered.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        // Store completion handler to call when the session finishes delivering events.
        bgCompletionHandler = completionHandler
        // Recreate the background session with the same identifier so delegates receive callbacks.
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        let _ = URLSession(configuration: config, delegate: BackgroundSessionHandler.shared, delegateQueue: nil)
        BackgroundSessionHandler.shared.onAllEventsComplete = { [weak self] in
            self?.bgCompletionHandler?()
            self?.bgCompletionHandler = nil
        }
    }
}
