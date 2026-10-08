import AppKit
import CoreAudio
import CoreGraphics
import QuartzCore

/// Watches, during a session, for anything that could put the picture on another screen or the sound
/// on a speaker: the headset display going away (HDMI pulled, processor unit off), USB lost, the
/// head-tracking stream stopping (headset cable pulled), or the sound output changing (Bluetooth
/// headphones dropping, wired headphones unplugged). Reports the first one, once, on the main thread.
final class DisconnectWatch {
    private let displayID: CGDirectDisplayID?
    private weak var window: NSWindow?
    private let headset: Headset?
    private let onTrigger: (String) -> Void
    private var triggered = false
    private var stopped = false

    private var timer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var sensorSeen = false
    private var audioListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    /// Gives CoreGraphics' C callback a way back to the watcher.
    private static var current: DisconnectWatch?

    /// The device the sound is locked to (nil: muted or no sound).
    private let soundDeviceUID: String?
    /// Following the Mac's output: any output switch stops playback (the user changed where sound goes).
    private let stopOnOutputSwitch: Bool
    private var deviceToken: AnyObject?

    init(displayID: CGDirectDisplayID?, window: NSWindow, headset: Headset?,
         soundDeviceUID: String?, stopOnOutputSwitch: Bool, onTrigger: @escaping (String) -> Void) {
        self.displayID = displayID
        self.window = window
        self.headset = headset
        self.soundDeviceUID = soundDeviceUID
        self.stopOnOutputSwitch = stopOnOutputSwitch
        self.onTrigger = onTrigger
    }

    func start() {
        Self.current = self

        if displayID != nil {
            // Fires *before* a reconfiguration takes effect, so the picture is gone before macOS can
            // move the window to another screen.
            CGDisplayRegisterReconfigurationCallback(Self.displayChanged, nil)
            // Last resort: the window ended up on another screen anyway.
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification, object: window, queue: .main
            ) { [weak self] _ in
                trace("window moved to screen \(self?.window?.screen.map(displayIDOf) ?? 0)")
            guard let self, let window = self.window, let id = self.displayID,
                      let screen = window.screen, displayIDOf(screen) != id else { return }
                window.orderOut(nil)
                self.fire("the headset display went away")
            }
        }

        headset?.onUSBDisconnected = { [weak self] in self?.fire("the headset's USB cable was disconnected") }

        // Polled checks: display still online, head tracking still streaming.
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }

        watchAudioOutput()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if displayID != nil { CGDisplayRemoveReconfigurationCallback(Self.displayChanged, nil) }
        if Self.current === self { Self.current = nil }
        timer?.invalidate()
        timer = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        headset?.onUSBDisconnected = nil
        for (object, address, block) in audioListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
        }
        audioListeners = []
        deviceToken = nil
    }

    // MARK: Checks

    private func poll() {
        if let id = displayID, CGDisplayIsOnline(id) == 0 || CGDisplayIsActive(id) == 0 {
            fire("the headset display went away")
            return
        }
        // Head tracking normally arrives ~1000 times a second; a gap means the headset cable is out or
        // the processor unit lost power. Only armed once data has been seen in this session.
        guard let headset, headset.isConnected else { return }
        let age = CACurrentMediaTime() - headset.lastSensorTime
        if age < 0.5 { sensorSeen = true }
        if sensorSeen && age > 1.5 { fire("head tracking stopped (headset cable or processor unit power)") }
    }

    private static let displayChanged: CGDisplayReconfigurationCallBack = { display, flags, _ in
        trace("display \(display) reconfiguration, flags 0x\(String(flags.rawValue, radix: 16)), main thread: \(Thread.isMainThread)")
        guard let watch = DisconnectWatch.current, let id = watch.displayID, display == id else { return }
        // Any change to the headset display mid-session (removal, sleep, mode change) is treated as a
        // disconnect: hide first, then stop.
        let hide = {
            watch.window?.alphaValue = 0
            watch.window?.orderOut(nil)
            watch.fire(flags.contains(.removeFlag) ? "the headset display was disconnected"
                                                   : "the headset display changed unexpectedly")
        }
        if Thread.isMainThread { hide() } else { DispatchQueue.main.sync(execute: hide) }
    }

    private func watchAudioOutput() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var defaultAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                        mScope: kAudioObjectPropertyScopeGlobal,
                                                        mElement: kAudioObjectPropertyElementMain)
        if stopOnOutputSwitch {
            let onDefaultChange: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.fire("the sound output changed (headphones disconnected?)")
            }
            if AudioObjectAddPropertyListenerBlock(system, &defaultAddress, .main, onDefaultChange) == noErr {
                audioListeners.append((system, defaultAddress, onDefaultChange))
            }
        }

        // The device the sound is locked to disappearing (AirPods into their case, unplugged).
        guard let uid = soundDeviceUID else { return }
        deviceToken = AudioOutput.observeDevices { [weak self] in
            if !AudioOutput.isConnected(uid) { self?.fire("the sound device was disconnected") }
        }

        // Wired headphones in the Mac's jack: same device, its data source flips to the speakers.
        var device = AudioObjectID(0)
        var cfUID = uid as CFString
        var translate = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                   mScope: kAudioObjectPropertyScopeGlobal,
                                                   mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let found = withUnsafeMutablePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(system, &translate, UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device)
        }
        guard found == noErr, device != 0 else { return }
        var sourceAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                                       mScope: kAudioDevicePropertyScopeOutput,
                                                       mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &sourceAddress) else { return }
        let onSourceChange: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.fire("headphones were unplugged")
        }
        if AudioObjectAddPropertyListenerBlock(device, &sourceAddress, .main, onSourceChange) == noErr {
            audioListeners.append((device, sourceAddress, onSourceChange))
        }
    }

    private func fire(_ reason: String) {
        guard !triggered, !stopped else { return }
        triggered = true
        onTrigger(reason)
    }
}

func displayIDOf(_ screen: NSScreen) -> CGDirectDisplayID {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
}

/// Sound output devices.
public enum AudioOutput {
    public struct Device: Hashable, Identifiable {
        public let uid: String
        public let name: String
        public var id: String { uid }
    }

    /// Devices that can play sound right now (connected), by name.
    public static func devices() -> [Device] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return Device(uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func isConnected(_ uid: String) -> Bool { devices().contains { $0.uid == uid } }

    /// Calls `onChange` (main thread) whenever devices are connected or disconnected. Returns a
    /// token for `stopObserving`.
    public static func observeDevices(_ onChange: @escaping () -> Void) -> AnyObject {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        return ListenerToken(address: address, block: block)
    }

    private final class ListenerToken {
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
        init(address: AudioObjectPropertyAddress, block: @escaping AudioObjectPropertyListenerBlock) {
            self.address = address
            self.block = block
        }
        deinit { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) }
    }

    private static func string(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &a, 0, nil, &s, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func currentDefault() -> (uid: String, name: String)? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        func string(_ selector: AudioObjectPropertySelector) -> String? {
            var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?
            var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(device, &a, 0, nil, &s, &value) == noErr else { return nil }
            return value?.takeRetainedValue() as String?
        }
        guard let uid = string(kAudioDevicePropertyDeviceUID) else { return nil }
        return (uid, string(kAudioObjectPropertyName) ?? uid)
    }
}
