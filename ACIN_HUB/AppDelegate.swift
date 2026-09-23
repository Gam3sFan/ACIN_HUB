import UIKit

// Handles background URLSession events and calls completion handler when finished.
final class BackgroundSessionHandler: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    static let shared = BackgroundSessionHandler()
    var onAllEventsComplete: (() -> Void)?

    private var tempFilesByTask: [Int: URL] = [:]
    private let lock = NSLock()

    func registerTempFile(_ url: URL, for task: URLSessionTask) {
        lock.lock()
        tempFilesByTask[task.taskIdentifier] = url
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let url = tempFilesByTask.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        if let url = url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // All background events for this session have been delivered.
        DispatchQueue.main.async { [weak self] in
            self?.onAllEventsComplete?()
            self?.onAllEventsComplete = nil
        }
    }
}

// Single shared background session for all video uploads.
// Recreating URLSession with the same identifier raises an exception, so we keep one instance.
extension URLSession {
    static let backgroundUpload: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.acin-hub.upload")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: config, delegate: BackgroundSessionHandler.shared, delegateQueue: nil)
    }()
}

class AppDelegate: UIResponder, UIApplicationDelegate {
    private var bgCompletionHandler: (() -> Void)?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Touch the shared session early so that any pending background events
        // reconnect to the delegate as soon as possible.
        _ = URLSession.backgroundUpload
        // Cleanup any orphaned multipart temp files from previous runs.
        cleanupOrphanedUploadFiles()
        return true
    }

    // Called when background URLSession events are ready to be delivered.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        // Store completion handler to call when the session finishes delivering events.
        bgCompletionHandler = completionHandler
        // Ensure the shared session exists so events can be routed to its delegate.
        _ = URLSession.backgroundUpload
        BackgroundSessionHandler.shared.onAllEventsComplete = { [weak self] in
            self?.bgCompletionHandler?()
            self?.bgCompletionHandler = nil
        }
    }

    private func cleanupOrphanedUploadFiles() {
        let tmp = NSTemporaryDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: tmp) else { return }
        for f in files where f.hasSuffix(".upload") {
            try? FileManager.default.removeItem(atPath: tmp + f)
        }
    }
}
