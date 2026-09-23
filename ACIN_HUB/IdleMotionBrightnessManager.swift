import Foundation
import CoreMotion
import UIKit

/// Manages screen brightness based on user inactivity and device motion.
/// - Uses accelerometer to detect motion.
/// - Call `noteUserInteraction()` from touch events to reset idle timer.
final class IdleMotionBrightnessManager: ObservableObject {
    // Publicly adjustable settings (percent 0...100)
    @Published var dimBrightnessPercent: Int {
        didSet {
            let clamped = max(0, min(100, dimBrightnessPercent))
            if dimBrightnessPercent != clamped {
                dimBrightnessPercent = clamped
                return
            }
            persist()
        }
    }
    @Published var activeBrightnessPercent: Int {
        didSet {
            let clamped = max(0, min(100, activeBrightnessPercent))
            if activeBrightnessPercent != clamped {
                activeBrightnessPercent = clamped
                return
            }
            persist()
        }
    }
    /// Motion sensitivity as an integer 1...10 (higher = more sensitive)
    @Published var motionSensitivity: Int {
        didSet {
            let clamped = max(1, min(10, motionSensitivity))
            if motionSensitivity != clamped {
                motionSensitivity = clamped
                return
            }
            // Cache derived threshold so the motion queue does not need to hop on main.
            cachedMotionThreshold = 0.15 / Double(clamped)
            persist()
        }
    }
    /// Seconds of inactivity before dimming
    @Published var idleSeconds: Int {
        didSet {
        let clamped = max(20, min(3600, idleSeconds))
            if idleSeconds != clamped {
                idleSeconds = clamped
                return
            }
            persist()
        }
    }

    private let motion = CMMotionManager()
    private var timer: Timer?
    private var lastInteraction: Date = Date()
    private var lastMagnitude: Double?
    private var forcedBrightnessPercent: Int?
    /// Pre-computed motion threshold, written from main on `motionSensitivity` change,
    /// read from the motion background queue. Double reads are atomic on 64-bit ARM.
    private var cachedMotionThreshold: Double = 0.15 / 5.0

    init() {
        let defaults = UserDefaults.standard
        self.dimBrightnessPercent = defaults.integer(forKey: "dimBrightnessPercent")
        if defaults.object(forKey: "dimBrightnessPercent") == nil { self.dimBrightnessPercent = 10 }
        self.activeBrightnessPercent = defaults.integer(forKey: "activeBrightnessPercent")
        if defaults.object(forKey: "activeBrightnessPercent") == nil { self.activeBrightnessPercent = 70 }
        self.motionSensitivity = defaults.integer(forKey: "motionSensitivity")
        if defaults.object(forKey: "motionSensitivity") == nil { self.motionSensitivity = 5 }
        self.idleSeconds = defaults.integer(forKey: "idleSeconds")
        if defaults.object(forKey: "idleSeconds") == nil { self.idleSeconds = 90 }
        if self.idleSeconds < 20 { self.idleSeconds = 20 }

        // Initialize cached threshold from the loaded sensitivity value.
        self.cachedMotionThreshold = 0.15 / Double(max(1, self.motionSensitivity))

        start()
    }

    deinit { stop() }

    func start() {
        stop()
        // Start device motion updates
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 0.2
            let queue = OperationQueue()
            motion.startDeviceMotionUpdates(to: queue) { [weak self] data, _ in
                guard let self = self, let data = data else { return }
                // Use userAcceleration to remove gravity component
                let a = data.userAcceleration
                self.processVector(x: a.x, y: a.y, z: a.z)
            }
        }
        // Start idle check timer
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // Set initial brightness to active
        let initial = forcedBrightnessPercent ?? activeBrightnessPercent
        applyBrightness(percent: initial)
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
    }

    /// Call this from any touch/gesture to reset idle timer and ensure active brightness.
    func noteUserInteraction() {
        lastInteraction = Date()
        let target = forcedBrightnessPercent ?? activeBrightnessPercent
        applyBrightness(percent: target)
    }

    func setForcedBrightnessPercent(_ percent: Int?) {
        let work = {
            let clamped = percent.map { max(0, min(100, $0)) }
            self.forcedBrightnessPercent = clamped
            if let forced = clamped {
                self.lastInteraction = Date()
                self.applyBrightness(percent: forced)
            } else {
                self.noteUserInteraction()
            }
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func processVector(x: Double, y: Double, z: Double) {
        // Compute magnitude change since last sample
        let magnitude = sqrt(x * x + y * y + z * z)
        var moved = false
        if let last = lastMagnitude {
            let delta = fabs(magnitude - last)
            // Read pre-computed threshold (refreshed on main when sensitivity changes).
            if delta > cachedMotionThreshold { moved = true }
        }
        lastMagnitude = magnitude
        if moved {
            DispatchQueue.main.async { [weak self] in
                self?.noteUserInteraction()
            }
        }
    }

    private func tick() {
        if forcedBrightnessPercent != nil {
            return
        }
        let elapsed = Date().timeIntervalSince(lastInteraction)
        if elapsed >= TimeInterval(idleSeconds) {
            applyBrightness(percent: dimBrightnessPercent)
        }
    }

    private func applyBrightness(percent: Int) {
        let target = forcedBrightnessPercent ?? percent
        let clamped = max(0, min(100, target))
        let value = CGFloat(clamped) / 100.0
        if Thread.isMainThread {
            UIScreen.main.brightness = value
        } else {
            DispatchQueue.main.async {
                UIScreen.main.brightness = value
            }
        }
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(dimBrightnessPercent, forKey: "dimBrightnessPercent")
        d.set(activeBrightnessPercent, forKey: "activeBrightnessPercent")
        d.set(motionSensitivity, forKey: "motionSensitivity")
        d.set(idleSeconds, forKey: "idleSeconds")
    }
}
