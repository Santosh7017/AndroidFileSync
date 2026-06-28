// USBDeviceMonitor.swift
// AndroidFileSync
//
// Event-driven USB attach/detach detection using IOKit.
// Zero CPU overhead when idle — callbacks fire only when hardware changes.

import Foundation
import IOKit
import IOKit.usb

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
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)

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
