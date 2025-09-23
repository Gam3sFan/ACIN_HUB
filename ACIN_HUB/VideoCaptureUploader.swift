import Foundation
import AVFoundation
import UIKit

final class VideoCaptureUploader: NSObject, AVCaptureFileOutputRecordingDelegate {
    private let uploadURL: URL
    private let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "VideoCaptureUploader.session")
    private var isConfigured = false
    private var isRecording = false
    private var currentOutputURL: URL?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    private var pendingDeviceName: String?
    private var pendingTimestamp: Date?

    // Optional log callback
    var onLog: ((String) -> Void)?
    var onRecordingChange: ((Bool) -> Void)?

    init(uploadURL: URL) {
        self.uploadURL = uploadURL
        super.init()
    }

    func captureAndUpload(deviceName: String, timestamp: Date) {
        // Avoid re-entrancy
        if isRecording { log("Capture already in progress; skipping"); return }
        // Check permission
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async { [weak self] in
                self?.pendingDeviceName = deviceName
                self?.pendingTimestamp = timestamp
                self?.startCapture(deviceName: deviceName, timestamp: timestamp)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self = self else { return }
                if granted {
                    DispatchQueue.main.async {
                        self.pendingDeviceName = deviceName
                        self.pendingTimestamp = timestamp
                        self.startCapture(deviceName: deviceName, timestamp: timestamp)
                    }
                } else {
                    self.log("Camera access denied")
                }
            }
        default:
            log("Camera access not authorized")
        }
    }

    private func startCapture(deviceName: String, timestamp: Date) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                // Begin background task to allow short work if app goes to background
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if self.bgTask == .invalid {
                        self.bgTask = UIApplication.shared.beginBackgroundTask(withName: "VideoCaptureUploader") {
                            // Expiration handler: try to stop recording
                            self.stopRecording()
                            if self.bgTask != .invalid { UIApplication.shared.endBackgroundTask(self.bgTask); self.bgTask = .invalid }
                        }
                    }
                }
                if !self.isConfigured {
                    try self.configureSession()
                }
                if !self.session.isRunning { self.session.startRunning() }
                self.isRecording = true
                DispatchQueue.main.async { [weak self] in self?.onRecordingChange?(true) }
                let tempURL = self.makeTempURL()
                self.currentOutputURL = tempURL
                self.movieOutput.startRecording(to: tempURL, recordingDelegate: self)
                self.log("Recording started to \(tempURL.lastPathComponent)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                    self?.stopRecording()
                }
            } catch {
                self.log("Failed to configure session: \(error.localizedDescription)")
            }
        }
    }

    private func stopRecording() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
                self.log("Recording stop requested")
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        // Low resolution to keep file small
        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
        } else if session.canSetSessionPreset(.cif352x288) {
            session.sessionPreset = .cif352x288
        }
        // Input: front camera
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw NSError(domain: "VideoCaptureUploader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Front camera not available"])
        }
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) { session.addInput(input) }
        // Output: movie file
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        // Note: No audio input added -> resulting movie has no audio track
        session.commitConfiguration()
        isConfigured = true
    }

    private func makeTempURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
    }

    // MARK: - AVCaptureFileOutputRecordingDelegate

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        let url = outputFileURL
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        log("Recording finished: \(url.lastPathComponent) (\(size) bytes)")
        // End background task for capture phase (upload still has its own background session)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if self.bgTask != .invalid { UIApplication.shared.endBackgroundTask(self.bgTask); self.bgTask = .invalid }
        }
        // Stop session to free camera
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.isRecording = false
            DispatchQueue.main.async { [weak self] in self?.onRecordingChange?(false) }
        }
        // Upload
        uploadFile(url)
        // Cleanup
        try? FileManager.default.removeItem(at: url)
    }

    private func uploadFile(_ fileURL: URL) {
        // Build multipart body into a temp file (required for background upload)
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let multipartURL = tmp.appendingPathComponent(UUID().uuidString).appendingPathExtension("upload")
        FileManager.default.createFile(atPath: multipartURL.path, contents: nil, attributes: nil)
        guard let handle = try? FileHandle(forWritingTo: multipartURL) else {
            log("Failed to create multipart file")
            return
        }

        func write(_ string: String) { if let data = string.data(using: .utf8) { try? handle.write(contentsOf: data) } }

        // Fields
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        let dn = pendingDeviceName ?? UIDevice.current.name
        let ts = iso.string(from: pendingTimestamp ?? Date())

        write("--\(boundary)\r\n")
        write("Content-Disposition: form-data; name=\"deviceName\"\r\n\r\n")
        write("\(dn)\r\n")

        write("--\(boundary)\r\n")
        write("Content-Disposition: form-data; name=\"timestamp\"\r\n\r\n")
        write("\(ts)\r\n")

        // File part
        let filename = fileURL.lastPathComponent
        write("--\(boundary)\r\n")
        write("Content-Disposition: form-data; name=\"video\"; filename=\"\(filename)\"\r\n")
        write("Content-Type: video/quicktime\r\n\r\n")
        if let fileData = try? Data(contentsOf: fileURL) { try? handle.write(contentsOf: fileData) }
        write("\r\n")
        write("--\(boundary)--\r\n")

        try? handle.close()

        // Background session
        let config = URLSessionConfiguration.background(withIdentifier: "com.acin-hub.upload")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        let session = URLSession(configuration: config, delegate: BackgroundSessionHandler.shared, delegateQueue: nil)

        let task = session.uploadTask(with: request, fromFile: multipartURL)
        task.resume()
    }

    public func previewSession() -> AVCaptureSession { session }

    private func log(_ message: String) { onLog?(message) }
}
