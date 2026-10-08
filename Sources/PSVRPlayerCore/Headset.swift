import Foundation
import os
import QuartzCore
import PSVRKit

/// The PSVR on USB, serviced on its own high-priority thread: head tracking and the inline
/// remote's buttons. Lives as long as the program; playback sessions come and go.
public final class Headset {
    public let psvr = PSVR()
    public let tracker = OrientationTracker()
    private var runLoop: CFRunLoop?
    private var gestures = ButtonGestures()

    /// Runs on the main thread after the headset screen has been switched off.
    public var onQuickExit: (() -> Void)?
    /// Playback gestures (seek, play/pause), delivered on the main thread.
    public var onPlaybackGesture: ((ButtonGestures.Gesture) -> Void)?
    /// Status lines ("tracking: …", disconnects).
    public var onMessage: ((String) -> Void)? = { print($0) }
    /// USB connection to the processor unit lost (main thread).
    public var onUSBDisconnected: (() -> Void)?
    /// Put on (true) or taken off (false), from the face sensor (main thread).
    public var onWornChange: ((Bool) -> Void)?

    /// Whether someone is wearing the headset; nil until known (shortly after connecting).
    public var isWorn: Bool? { worn.withLock { $0 } }
    private let worn = OSAllocatedUnfairLock<Bool?>(initialState: nil)
    private var wornRaw = false
    private var wornRawSince: CFTimeInterval = 0

    /// Host time of the last head-tracking packet (~1000 per second while the headset is connected).
    private let lastSensor = OSAllocatedUnfairLock<CFTimeInterval>(initialState: 0)
    public var lastSensorTime: CFTimeInterval { lastSensor.withLock { $0 } }

    public init() {}

    /// Connects and powers the headset on. Returns false if no PSVR is on USB.
    public func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        var connected = false
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            tracker.onStateChange = { [weak self] _, message in self?.message("tracking: \(message)") }
            psvr.onSensor = { [self] packet in
                let now = CACurrentMediaTime()
                lastSensor.withLock { $0 = now }
                tracker.update(packet)
                updateWorn(packet.worn, now: now)
                switch gestures.update(buttons: packet.buttons, time: ProcessInfo.processInfo.systemUptime) {
                case .recenter:
                    tracker.recenterYaw()
                case .quickExit:
                    // Blank the headset right here on the USB thread, before anything else.
                    try? psvr.send(.headsetPower(false))
                    try? psvr.send(.vrMode(false))
                    DispatchQueue.main.async { self.onQuickExit?() }
                case let gesture?:
                    DispatchQueue.main.async { self.onPlaybackGesture?(gesture) }
                case nil:
                    break
                }
            }
            psvr.onConnectionChange = { [weak self] up in
                guard !up else { return }
                self?.message("PSVR disconnected from USB")
                DispatchQueue.main.async { self?.onUSBDisconnected?() }
            }
            do {
                try psvr.open(on: CFRunLoopGetCurrent())
                connected = psvr.waitForConnection(timeout: 3)
                if connected { try psvr.send(.headsetPower(true)) }
            } catch {
                message("PSVR: \(error)")
            }
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "psvr-usb"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return connected
    }

    public var isConnected: Bool { psvr.isConnected }

    public func send(_ command: PSVRCommand) {
        perform { [weak self] psvr in
            do { try psvr.send(command) } catch { self?.message("PSVR: \(error)") }
        }
    }

    /// Sends without waiting (for the quick exit: never blocks, even if USB is gone).
    public func sendNow(_ command: PSVRCommand) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [psvr] in try? psvr.send(command) }
        CFRunLoopWakeUp(runLoop)
    }

    /// Runs `body` on the USB thread and waits (up to 1 s) for it.
    public func perform(_ body: @escaping (PSVR) -> Void) {
        guard let runLoop else { return }
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [psvr] in
            body(psvr)
            done.signal()
        }
        CFRunLoopWakeUp(runLoop)
        _ = done.wait(timeout: .now() + 1)
    }

    /// Taking it off counts after 0.1 s; putting it on after 0.5 s (so it has settled on the face).
    private func updateWorn(_ raw: Bool, now: CFTimeInterval) {
        if raw != wornRaw {
            wornRaw = raw
            wornRawSince = now
        }
        guard now - wornRawSince >= (raw ? 0.5 : 0.1) else { return }
        let changed = worn.withLock { state -> Bool in
            guard state != raw else { return false }
            state = raw
            return true
        }
        if changed { DispatchQueue.main.async { self.onWornChange?(raw) } }
    }

    private func message(_ text: String) {
        DispatchQueue.main.async { self.onMessage?(text) }
    }
}
