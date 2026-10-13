import AudioToolbox
import CoreAudio
import Foundation

/// Turns the system output volume down while dictating and eases it back up
/// afterward, so music keeps playing underneath. Works on the system volume
/// rather than any one player, so it covers Music, Spotify, browser tabs, etc.
final class MusicDucker {
    enum Timing {
        /// Fraction of the current volume to duck to.
        static let duckFactor: Float = 0.12
        /// Quick, so the first words aren't spoken over full-volume music.
        static let fadeDown: TimeInterval = 0.25
        /// Slow, so music swells back in instead of jumping.
        static let fadeUp: TimeInterval = 2.0
    }

    /// Survives a crash or SIGTERM mid-duck, so volume can't be stranded low.
    private static let pendingRestoreKey = "duckPendingRestoreVolume"

    /// Output volume before ducking; non-nil for as long as we own the volume.
    private var originalVolume: Float?
    private var device: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    /// Volume the device reported after our last write, used to notice the user
    /// touching the volume keys.
    private var lastWritten: Float = 0
    private var fadeTimer: Timer?

    init() {
        // A previous run died while ducked: put the volume back before anything else.
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.pendingRestoreKey) != nil else { return }
        let pending = defaults.float(forKey: Self.pendingRestoreKey)
        defaults.removeObject(forKey: Self.pendingRestoreKey)
        if let id = Self.defaultOutputDevice() {
            Self.setVolume(pending, on: id)
            print("Scribey: restored output volume to \(pending) after an interrupted duck")
        }
    }

    func duck() {
        if originalVolume == nil {
            guard let id = Self.defaultOutputDevice(), let current = Self.volume(of: id) else {
                print("Scribey: output device has no software volume, not ducking")
                return
            }
            device = id
            originalVolume = current
            lastWritten = current
            UserDefaults.standard.set(current, forKey: Self.pendingRestoreKey)
        }
        guard let original = originalVolume else { return }
        fade(to: original * Timing.duckFactor, over: Timing.fadeDown, then: nil)
    }

    func restore() {
        guard let original = originalVolume else { return }
        // If the volume moved from what we set, the user changed it by hand.
        // Their choice wins; don't fade back over it.
        if userChangedVolume() {
            release()
            return
        }
        fade(to: original, over: Timing.fadeUp) { [weak self] in self?.release() }
    }

    /// For quitting: no time for a fade, just put the volume back.
    func restoreImmediately() {
        guard let original = originalVolume else { return }
        fadeTimer?.invalidate()
        fadeTimer = nil
        if !userChangedVolume() { Self.setVolume(original, on: device) }
        release()
    }

    private func release() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        originalVolume = nil
        UserDefaults.standard.removeObject(forKey: Self.pendingRestoreKey)
    }

    private func userChangedVolume() -> Bool {
        guard let now = Self.volume(of: device) else { return false }
        return abs(now - lastWritten) > 0.02
    }

    /// Linear ramp from wherever the volume is right now, so reversing midway
    /// (tap, then a real hold) doesn't jump.
    private func fade(to target: Float, over duration: TimeInterval, then completion: (() -> Void)?) {
        fadeTimer?.invalidate()
        let start = lastWritten
        let began = Date()
        let id = device
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = Float(min(1, Date().timeIntervalSince(began) / duration))
            let value = start + (target - start) * t
            Self.setVolume(value, on: id)
            // Read back rather than trusting `value`: devices with coarse
            // volume steps round it, which would look like a manual change.
            self.lastWritten = Self.volume(of: id) ?? value
            if t >= 1 {
                timer.invalidate()
                self.fadeTimer = nil
                completion?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    // MARK: - CoreAudio

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// The same volume the menu-bar slider and volume keys control. Absent on
    /// devices with fixed volume (some HDMI/USB outputs), which we leave alone.
    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func volume(of id: AudioObjectID) -> Float? {
        var address = volumeAddress()
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func setVolume(_ value: Float, on id: AudioObjectID) {
        var address = volumeAddress()
        var clamped = Float32(max(0, min(1, value)))
        AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &clamped)
    }
}
