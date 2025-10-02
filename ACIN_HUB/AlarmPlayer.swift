import Foundation
import AVFoundation
import AudioToolbox

final class AlarmPlayer {
    private var player: AVAudioPlayer?
    private var rampTimer: Timer?

    func start(volumeRampDuration: TimeInterval = 8.0) {
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // ignore
        }

        if let url = Bundle.main.url(forResource: "Alarm_Haptic", withExtension: "caf") {
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.numberOfLoops = -1
                p.volume = 0.05
                p.prepareToPlay()
                p.play()
                self.player = p
                startRamp(to: 1.0, duration: volumeRampDuration)
                return
            } catch {
                // fall through to system sound
            }
        }
        // Fallback: play a short system sound (no ramp possible)
        AudioServicesPlaySystemSound(1005)
    }

    func stop() {
        rampTimer?.invalidate(); rampTimer = nil
        player?.stop(); player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startRamp(to target: Float, duration: TimeInterval) {
        rampTimer?.invalidate()
        guard let player = player, duration > 0 else { return }
        let steps = 40
        let stepDuration = duration / Double(steps)
        var currentStep = 0
        rampTimer = Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { [weak self] t in
            guard let self = self, let p = self.player else { t.invalidate(); return }
            currentStep += 1
            let progress = min(1.0, Float(currentStep) / Float(steps))
            p.volume = 0.05 + (target - 0.05) * progress
            if currentStep >= steps { t.invalidate() }
        }
    }
}
