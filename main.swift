import AppKit
import CoreAudio
import Carbon

private let system = AudioObjectID(kAudioObjectSystemObject)
private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    .init(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
private func defaultOutput() -> AudioDeviceID {
    var a = address(kAudioHardwarePropertyDefaultOutputDevice), id: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    return AudioObjectGetPropertyData(system, &a, 0, nil, &size, &id) == noErr ? id : 0
}
private func stringProperty(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var a = address(selector), value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}
private func isTascam(_ device: AudioDeviceID) -> Bool {
    guard let name = stringProperty(device, kAudioObjectPropertyName),
          let maker = stringProperty(device, kAudioObjectPropertyManufacturer) else { return false }
    return name.uppercased().replacingOccurrences(of: " ", with: "") == "US-1X2HR" && maker.uppercased().contains("TASCAM")
}

private struct AudioFailure: LocalizedError {
    var detail: String
    var errorDescription: String? { detail }
}
private func check(_ status: OSStatus, _ step: String) throws {
    if status != noErr { throw AudioFailure(detail: "\(step) failed (\(status)).") }
}

final class Router {
    private(set) var device: AudioDeviceID = 0
    private var tap: AudioObjectID = 0, aggregate: AudioDeviceID = 0
    private var captureID: AudioDeviceIOProcID?, playID: AudioDeviceIOProcID?
    private var bridge: OpaquePointer?
    private var captureStarted = false, playStarted = false
    var frames: UInt32 { bridge.map { bridge_frames($0) } ?? 0 }

    func setGain(_ percent: Int) {
        if let bridge { bridge_gain(bridge, UInt32(max(0, min(100, percent)))) }
    }
    func start(gain: Int, probeOnly: Bool = false) throws {
        guard device == 0 else { return }
        let target = defaultOutput()
        guard target != 0, isTascam(target),
              let uid = stringProperty(target, kAudioDevicePropertyDeviceUID) else {
            throw AudioFailure(detail: "Select US-1x2HR as the Mac’s sound output first.")
        }
        var outputRate = 0.0
        guard bridge_layout(target, false, &outputRate) else {
            throw AudioFailure(detail: "Unsupported TASCAM playback format. Nothing was changed.")
        }
        do {
            device = target
            var pid = getpid(), process: AudioObjectID = 0, pSize = UInt32(MemoryLayout<AudioObjectID>.size)
            var a = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            try check(AudioObjectGetPropertyData(system, &a, UInt32(MemoryLayout<pid_t>.size), &pid, &pSize, &process), "Find this audio process")
            guard process != 0 else { throw AudioFailure(detail: "Could not exclude this utility from its own audio tap.") }
            let desc = CATapDescription(excludingProcesses: [process], deviceUID: uid, stream: 0)
            desc.name = "TASCAM Wheel Volume playback"
            desc.isPrivate = true
            desc.muteBehavior = probeOnly ? .unmuted : .mutedWhenTapped
            try check(AudioHardwareCreateProcessTap(desc, &tap), "Create playback tap")
            guard let tapUID = stringProperty(tap, kAudioTapPropertyUID) else {
                throw AudioFailure(detail: "Could not identify the private playback tap.")
            }
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "TASCAM Wheel Volume (private tap)",
                kAudioAggregateDeviceUIDKey: "org.tascamwheelvolume.tap." + UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: 1,
                kAudioAggregateDeviceTapAutoStartKey: 0,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]],
            ]
            try check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregate), "Create private playback input")
            var inputRate = 0.0
            guard bridge_layout(aggregate, true, &inputRate), abs(inputRate - outputRate) < 0.01 else {
                throw AudioFailure(detail: "The private playback tap format does not match the TASCAM (tap: \(inputRate), output: \(outputRate) Hz). No sample rate was changed.")
            }
            if probeOnly {
                print("PASS: private tap and output both use Float32 stereo at \(outputRate) Hz; no capture started")
                stop()
                return
            }
            guard let b = bridge_create() else { throw AudioFailure(detail: "Could not allocate the in-memory playback buffer.") }
            bridge = b
            setGain(gain)
            try check(bridge_prepare_capture(aggregate, b, &captureID), "Prepare audio capture")
            try check(bridge_prepare_play(target, b, &playID), "Prepare TASCAM playback")
            guard let captureID, let playID else { throw AudioFailure(detail: "Core Audio did not create both audio callbacks.") }
            try check(AudioDeviceStart(target, playID), "Start TASCAM playback")
            playStarted = true
            try check(AudioDeviceStart(aggregate, captureID), "Start audio capture (check System Audio Recording permission)")
            captureStarted = true
        } catch {
            stop()
            throw error
        }
    }
    func stop() {
        var safeToFree = true
        if let captureID {
            if captureStarted { AudioDeviceStop(aggregate, captureID) }
            safeToFree = AudioDeviceDestroyIOProcID(aggregate, captureID) == noErr && safeToFree
        }
        if let playID {
            if playStarted { AudioDeviceStop(device, playID) }
            safeToFree = AudioDeviceDestroyIOProcID(device, playID) == noErr && safeToFree
        }
        if aggregate != 0 { AudioHardwareDestroyAggregateDevice(aggregate) }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap) }
        if safeToFree, let bridge { bridge_free(bridge) }
        captureID = nil; playID = nil; bridge = nil
        aggregate = 0; tap = 0; device = 0
        captureStarted = false; playStarted = false
    }
}

private func hotkeyHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var key = EventHotKeyID()
    let rc = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
    guard rc == noErr, key.signature == 0x5457564C, key.id == 1 || key.id == 2 else { return OSStatus(eventNotHandledErr) }
    let app = Unmanaged<VolumeApp>.fromOpaque(context).takeUnretainedValue()
    app.adjust(key.id == 1 ? -5 : 5)
    return noErr
}

final class VolumeApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let router = Router()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var handler: EventHandlerRef?
    private var bindings = [EventHotKeyRef]()
    private var timer: Timer?
    private var secondsWaiting = 0
    private var secondsActive = 0
    private var testWindow: NSWindow?
    private var testLabel: NSTextField?
    private var testButton: NSButton?
    private var gain = 35
    private var status = "Ready; not controlling audio"

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.menu = menu
        update()
        if CommandLine.arguments.contains("--test-window") { showTestWindow() }
        if CommandLine.arguments.contains("--start-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.router.device == 0, self.testWindow?.isVisible == true else { return }
                self.toggle()
            }
        }
    }
    @objc private func showTestWindow() {
        if testWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 240),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Tascam Wheel Volume Test"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.level = .floating
            let title = NSTextField(labelWithString: "Test TASCAM software volume")
            title.font = .boldSystemFont(ofSize: 19)
            let instructions = NSTextField(wrappingLabelWithString: "Keep the TASCAM’s physical volume low and play something quietly. Start the test, then allow System Audio Recording if macOS asks. Use Quieter to check whether playback changes.")
            let label = NSTextField(wrappingLabelWithString: status)
            let start = NSButton(title: "Start Test", target: self, action: #selector(toggle))
            let down = NSButton(title: "Quieter", target: self, action: #selector(down))
            let up = NSButton(title: "Louder", target: self, action: #selector(up))
            let buttons = NSStackView(views: [start, down, up])
            buttons.spacing = 10
            let ui = NSStackView(views: [title, instructions, label, buttons])
            ui.orientation = .vertical
            ui.alignment = .leading
            ui.spacing = 14
            ui.translatesAutoresizingMaskIntoConstraints = false
            let content = NSView()
            content.addSubview(ui)
            NSLayoutConstraint.activate([
                ui.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                ui.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                ui.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                instructions.widthAnchor.constraint(equalTo: ui.widthAnchor),
                label.widthAnchor.constraint(equalTo: ui.widthAnchor),
            ])
            w.contentView = content
            w.center()
            testWindow = w
            testLabel = label
            testButton = start
        }
        update()
        NSApplication.shared.activate(ignoringOtherApps: true)
        testWindow?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        if router.device != 0 { stop("Test window closed; direct audio restored") }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showTestWindow()
        return true
    }
    private func row(_ title: String, _ action: Selector?, key: String = "") {
        let m = NSMenuItem(title: title, action: action, keyEquivalent: key)
        m.target = self
        menu.addItem(m)
    }
    private func update() {
        item.button?.title = router.device == 0 ? "TASCAM" : "TASCAM \(gain)%"
        testLabel?.stringValue = status + "  •  Volume \(gain)%"
        if CommandLine.arguments.contains("--test-window") {
            let file = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("test-status.txt")
            try? "\(status) | gain \(gain)% | \(Date())\n".write(to: file, atomically: true, encoding: .utf8)
        }
        testButton?.title = router.device == 0 ? "Start Test" : "Stop Test"
        menu.removeAllItems()
        row(status, nil)
        row("Open test window", #selector(showTestWindow))
        row(router.device == 0 ? "Start volume control" : "Stop and restore direct audio", #selector(toggle))
        row("Volume down 5%  (⌃⌥⇧↓)", #selector(down))
        row("Volume up 5%  (⌃⌥⇧↑)", #selector(up))
        menu.addItem(.separator())
        row("Quit", #selector(quitApp), key: "q")
    }
    func adjust(_ delta: Int) { gain = max(0, min(100, gain + delta)); router.setGain(gain); update() }
    @objc private func down() { adjust(-5) }
    @objc private func up() { adjust(5) }
    @objc private func quitApp() { NSApplication.shared.terminate(nil) }
    @objc private func toggle() {
        if router.device != 0 { stop("Direct audio restored"); return }
        do {
            try bindShortcuts()
            try router.start(gain: gain)
            secondsWaiting = 0
            secondsActive = 0
            status = "Waiting for playback; start audio to verify"
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.watch() }
            update()
        } catch {
            stop(error.localizedDescription)
        }
    }
    private func bindShortcuts() throws {
        var s = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        try check(InstallEventHandler(GetApplicationEventTarget(), hotkeyHandler, 1, &s, Unmanaged.passUnretained(self).toOpaque(), &handler), "Register keyboard handler")
        for (code, id) in [(kVK_DownArrow, 1), (kVK_UpArrow, 2)] {
            var key: EventHotKeyRef?
            try check(RegisterEventHotKey(UInt32(code), UInt32(controlKey | optionKey | shiftKey), EventHotKeyID(signature: 0x5457564C, id: UInt32(id)), GetApplicationEventTarget(), 0, &key), "Register volume shortcut")
            if let key { bindings.append(key) }
        }
    }
    private func watch() {
        if defaultOutput() != router.device { stop("Output changed; direct audio restored"); return }
        secondsActive += 1
        if testWindow?.isVisible == true && secondsActive >= 60 { stop("Test finished; direct audio restored"); return }
        if router.frames > 0 {
            if status != "Software volume active" { status = "Software volume active"; update() }
        } else {
            secondsWaiting += 1
            if secondsWaiting >= 12 { stop("No playback captured; check permission and retry with audio playing") }
        }
    }
    private func stop(_ message: String) {
        timer?.invalidate(); timer = nil
        router.stop()
        bindings.forEach { UnregisterEventHotKey($0) }; bindings.removeAll()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        status = message; update()
    }
    func applicationWillTerminate(_ notification: Notification) { stop("Stopped") }
}

if CommandLine.arguments.contains("--self-test") {
    let ok = bridge_self_test()
    print(ok ? "PASS: stereo gain, silence, clamping and underrun" : "FAIL: audio bridge")
    exit(ok ? 0 : 1)
}
if CommandLine.arguments.contains("--probe-output") {
    let id = defaultOutput()
    var rate = 0.0
    let layout = bridge_layout(id, false, &rate)
    print("TASCAM default: \(isTascam(id)); float stereo output: \(layout); rate: \(rate) Hz")
    exit(isTascam(id) && layout ? 0 : 2)
}
if CommandLine.arguments.contains("--probe-route") {
    do { try Router().start(gain: 0, probeOnly: true); exit(0) }
    catch { print(error.localizedDescription); exit(3) }
}
let app = NSApplication.shared
let delegate = VolumeApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
