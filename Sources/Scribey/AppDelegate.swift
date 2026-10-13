import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkeys = HotkeyManager()
    private let daemon = DaemonProcess()
    private let client = TranscriptionClient()
    private let recordingState = RecordingState()
    private var overlay: OverlayPanel?
    private var statusItem: NSStatusItem?
    private let customWords = CustomWordsMenu()
    private var connectRetryTimer: Timer?
    private var currentRecordingPath: URL?
    private var daemonReady = false
    private var hasPastedBefore = false
    private var soundsMuted = UserDefaults.standard.bool(forKey: "soundsMuted")
    private let ducker = MusicDucker()
    private var duckingEnabled = UserDefaults.standard.object(forKey: "duckMusic") as? Bool ?? true

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestAccessibilityPermissionIfNeeded()
        requestMicrophonePermissionIfNeeded()
        setupStatusItem()
        overlay = OverlayPanel(state: recordingState)
        setupHotkeys()

        daemon.onExitUnexpectedly = { [weak self] in
            print("Scribey: daemon exited unexpectedly, daemonReady=false, will retry connect/respawn")
            self?.daemonReady = false
            self?.client.disconnect()
        }
        daemon.start()
        startConnectRetryLoop()
        print("Scribey: launched, daemon starting, waiting for socket connect...")
    }

    func applicationWillTerminate(_ notification: Notification) {
        ducker.restoreImmediately()
        hotkeys.stop()
        client.disconnect()
        daemon.stop()
    }

    private func requestAccessibilityPermissionIfNeeded() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options)
    }

    private func requestMicrophonePermissionIfNeeded() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Scribey")

        // Escape hatch reachable with the mouse, for when the overlay is stuck
        // and the keyboard isn't cooperating.
        let menu = NSMenu()
        let stopItem = NSMenuItem(
            title: "Stop Recording",
            action: #selector(stopRecordingFromMenu),
            keyEquivalent: ""
        )
        stopItem.target = self
        menu.addItem(stopItem)
        let muteItem = NSMenuItem(
            title: "Mute Sound Effects",
            action: #selector(toggleSoundsMuted(_:)),
            keyEquivalent: ""
        )
        muteItem.target = self
        muteItem.state = soundsMuted ? .on : .off
        menu.addItem(muteItem)
        let duckItem = NSMenuItem(
            title: "Lower Music While Dictating",
            action: #selector(toggleDucking(_:)),
            keyEquivalent: ""
        )
        duckItem.target = self
        duckItem.state = duckingEnabled ? .on : .off
        menu.addItem(duckItem)
        let wordsItem = NSMenuItem(title: "Custom Words", action: nil, keyEquivalent: "")
        wordsItem.submenu = customWords.menu
        menu.addItem(wordsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit Scribey",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)
        item.menu = menu

        statusItem = item
    }

    private func setupHotkeys() {
        hotkeys.onRecordStart = { [weak self] in self?.handleRecordStart() }
        hotkeys.onRecordStop = { [weak self] shouldTranscribe in self?.handleRecordStop(shouldTranscribe: shouldTranscribe) }
        hotkeys.onLockEngaged = { [weak self] in self?.handleLockEngaged() }
        hotkeys.onCancel = { [weak self] in self?.handleCancel() }
        hotkeys.start()
    }

    /// Esc pressed mid-recording, or "Stop Recording" chosen from the menu bar.
    private func handleCancel() {
        print("Scribey: recording cancelled by user")
        ducker.restore()
        AudioRecorder.discardCurrentRecording()
        currentRecordingPath = nil
        recordingState.phase = .idle
        overlay?.hide()
    }

    @objc private func toggleSoundsMuted(_ sender: NSMenuItem) {
        soundsMuted.toggle()
        UserDefaults.standard.set(soundsMuted, forKey: "soundsMuted")
        sender.state = soundsMuted ? .on : .off
    }

    @objc private func toggleDucking(_ sender: NSMenuItem) {
        duckingEnabled.toggle()
        UserDefaults.standard.set(duckingEnabled, forKey: "duckMusic")
        sender.state = duckingEnabled ? .on : .off
        if !duckingEnabled { ducker.restore() }
    }

    private func playSound(_ name: String) {
        guard !soundsMuted else { return }
        NSSound(named: name)?.play()
    }

    @objc private func stopRecordingFromMenu() {
        hotkeys.forceCancel()
        handleCancel()
    }

    private func startConnectRetryLoop() {
        connectRetryTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self, !self.daemonReady else { return }
            if self.client.connect() {
                self.daemonReady = true
                print("Scribey: connected to daemon socket, daemonReady=true")
            }
        }
    }

    private func handleRecordStart() {
        guard daemonReady else {
            print("Scribey: right-Option pressed but daemon not ready yet, ignoring")
            recordingState.phase = .notReady
            overlay?.show()
            return
        }
        print("Scribey: recording started")
        recordingState.resetWaveform()
        currentRecordingPath = AudioRecorder.start { [weak self] level in
            self?.recordingState.pushAmplitude(level)
        }
        recordingState.phase = .recording
        overlay?.show()
        playSound("Purr")
        if duckingEnabled { ducker.duck() }
    }

    private func handleLockEngaged() {
        print("Scribey: LOCKED — continuous recording, tap right-Option again to stop")
        recordingState.phase = .locked
    }

    private func handleRecordStop(shouldTranscribe: Bool) {
        guard currentRecordingPath != nil || recordingState.phase != .idle else {
            print("Scribey: recordStop called but nothing was recording, ignoring")
            return
        }
        ducker.restore()
        // Nothing was recorded; just take down the "Starting up…" pill.
        guard recordingState.phase != .notReady else {
            recordingState.phase = .idle
            overlay?.hide()
            return
        }
        playSound("Pop")

        guard shouldTranscribe else {
            print("Scribey: recording discarded (below debounce threshold)")
            AudioRecorder.discardCurrentRecording()
            currentRecordingPath = nil
            recordingState.phase = .idle
            overlay?.hide()
            return
        }

        AudioRecorder.stop()

        guard let path = currentRecordingPath else {
            print("Scribey: recordStop with shouldTranscribe=true but currentRecordingPath was nil")
            recordingState.phase = .idle
            overlay?.hide()
            return
        }
        currentRecordingPath = nil

        // The engine can stop before it ever delivered audio, leaving a
        // header-only file. Don't round-trip that to the daemon just to get "".
        let frames = AudioRecorder.capturedFrameCount
        guard frames > 0 else {
            print("Scribey: recording captured no audio (engine never delivered a buffer), discarding")
            try? FileManager.default.removeItem(at: path)
            recordingState.phase = .idle
            overlay?.hide()
            return
        }

        recordingState.phase = .transcribing
        print("Scribey: recording stopped, sending \(path.lastPathComponent) to daemon (connected=\(client.isConnected))")

        client.transcribe(path: path) { [weak self] result in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: path)
            }

            switch result {
            case .success(let text):
                print("Scribey: transcription succeeded: \"\(text)\"")
                if !text.isEmpty {
                    let prefix = self.hasPastedBefore ? " " : ""
                    PasteboardBridge.pasteText(prefix + text)
                    self.hasPastedBefore = true
                    print("Scribey: pasted text")
                } else {
                    print("Scribey: transcription was empty, nothing to paste")
                }
            case .failure(let error):
                print("Scribey: transcription failed: \(error)")
                if case .notConnected = error {
                    // TranscriptionClient already disconnected internally;
                    // the retry loop will reconnect.
                    self.daemonReady = false
                }
            }

            self.recordingState.phase = .idle
            self.overlay?.hide()
        }
    }
}
