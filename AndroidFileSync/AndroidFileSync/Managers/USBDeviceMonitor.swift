// USBDeviceMonitor.swift
// AndroidFileSync
//
// Event-driven USB attach/detach detection using IOKit.
// Zero CPU overhead when idle — callbacks fire only when hardware changes.

import Foundation
import IOKit
import IOKit.usb

/// ADB reports authorization, transport loss, and reconnection even when the USB
/// cable never moves. Keep one subscription per running daemon; IOKit remains the
/// signal that starts detection when no daemon exists yet.
@MainActor
final class ADBDeviceMonitor {
    var onChange: (() -> Void)?
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var generation = UUID()

    func start() {
        guard tasks.isEmpty, !AppProcessLifecycle.isTerminating else { return }
        let id = generation
        for port in [Shell.appADBServerPort, 5037] {
            tasks[port] = Task { [weak self] in
                var failures = 0
                while !Task.isCancelled, !AppProcessLifecycle.isTerminating {
                    // Merely watching must never launch an unused competing daemon.
                    guard Shell.isADBServerRunning(port: port) else {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        continue
                    }
                    let path = ADBManager.getADBPath()
                    guard !path.isEmpty else { return }
                    let started = Date()
                    _ = await Shell.stream(path, args: ["-P", String(port), "track-devices", "-l"],
                                           environment: Shell.serverEnvironment(port: port)) { [weak self] _ in
                        // The payload may arrive in chunks. DeviceManager coalesces
                        // these notifications and reads an authoritative snapshot.
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == id else { return }
                            self.onChange?()
                        }
                    }
                    guard !Task.isCancelled, let self, self.generation == id else { return }
                    self.onChange?()
                    failures = Date().timeIntervalSince(started) > 5 ? 0 : min(failures + 1, 4)
                    // An unsupported command or a restarting daemon must not spin.
                    try? await Task.sleep(nanoseconds: UInt64(min(5, 0.5 * pow(2, Double(failures))) * 1_000_000_000))
                }
            }
        }
    }

    func stop() {
        generation = UUID()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }
}

final class USBDeviceMonitor {

    /// Called on the main thread when a USB device is attached.
    var onDeviceAdded: (() -> Void)?
    /// Called on the main thread when a USB device is removed.
    var onDeviceRemoved: (() -> Void)?
    /// Legacy: called for both add and remove if the specific callbacks aren't set.
    var onChange: (() -> Void)?

    private var notifyPort: IONotificationPortRef?
    private var addedIterator:   io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    // MARK: - Lifecycle

    func start() {
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let port = notifyPort else {
            print("❌ USBMonitor: Failed to create IONotificationPort")
            return
        }

        // Add the notification source to the main run loop so callbacks arrive on the main thread
        let source = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        // Matching dict for any USB device
        guard let matching = IOServiceMatching(kIOUSBDeviceClassName) else {
            print("❌ USBMonitor: Failed to create matching dict")
            return
        }

        // We need two separate retained copies of the matching dict (IOKit consumes them)
        let matchingAdded   = matching
        let matchingRemoved = IOServiceMatching(kIOUSBDeviceClassName)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // ── Device ADDED ────────────────────────────────────────────────────
        let addedCB: IOServiceMatchingCallback = { ctx, iterator in
            var service = IOIteratorNext(iterator)
            while service != 0 { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard let ctx else { return }
            let monitor = Unmanaged<USBDeviceMonitor>.fromOpaque(ctx).takeUnretainedValue()
            print("🔌 USBMonitor: Device attached")
            DispatchQueue.main.async { (monitor.onDeviceAdded ?? monitor.onChange)?() }
        }

        IOServiceAddMatchingNotification(
            port, kIOMatchedNotification,
            matchingAdded, addedCB, selfPtr,
            &addedIterator
        )
        // Drain existing services (devices already connected at startup)
        var svc = IOIteratorNext(addedIterator)
        while svc != 0 { IOObjectRelease(svc); svc = IOIteratorNext(addedIterator) }

        // ── Device REMOVED ──────────────────────────────────────────────────
        let removedCB: IOServiceMatchingCallback = { ctx, iterator in
            var service = IOIteratorNext(iterator)
            while service != 0 { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard let ctx else { return }
            let monitor = Unmanaged<USBDeviceMonitor>.fromOpaque(ctx).takeUnretainedValue()
            print("🔌 USBMonitor: Device removed")
            DispatchQueue.main.async { (monitor.onDeviceRemoved ?? monitor.onChange)?() }
        }

        if let matchingRemoved {
            IOServiceAddMatchingNotification(
                port, kIOTerminatedNotification,
                matchingRemoved, removedCB, selfPtr,
                &removedIterator
            )
            svc = IOIteratorNext(removedIterator)
            while svc != 0 { IOObjectRelease(svc); svc = IOIteratorNext(removedIterator) }
        }

        print("📡 USBMonitor: Listening for USB events")
    }

    func stop() {
        if addedIterator   != 0 { IOObjectRelease(addedIterator);   addedIterator   = 0 }
        if removedIterator != 0 { IOObjectRelease(removedIterator); removedIterator = 0 }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
        print("📡 USBMonitor: Stopped")
    }

    deinit { stop() }
}
