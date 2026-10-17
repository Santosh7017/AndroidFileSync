//
//  EmptyStateView.swift
//  AndroidFileSync
//

import SwiftUI

/// The connection dashboard stays usable during discovery and background retries.
struct EmptyStateView: View {
    var isDetecting = false
    var isCheckingDevices = false
    var isSearchingWireless = false
    var scanStartedAt: Date? = nil
    var scanTimeout: TimeInterval = 20
    var scanTimedOut = false
    var lastCheckedAt: Date? = nil
    var recognizedWirelessDevices: [RecognizedWirelessDevice] = []
    var isRefreshingRecognizedDevices = false
    var lastRecognizedRefreshDate: Date? = nil
    var recognizedRefreshError: String? = nil
    var userDisconnected = false
    var unavailableDevice: ADBManager.ConnectedDevice? = nil
    var onRetry: (() -> Void)? = nil
    var onConnectWiFi: ((WirelessConnectView.PairingTab) -> Void)? = nil
    var onRefreshRecognizedDevices: (() -> Void)? = nil
    var isUSBOccupied = false
    var isClaimingUSB = false
    var onClaimUSB: (() -> Void)? = nil
    var diagnosticsControl: DiagnosticsControl? = nil

    @State private var showSetupHelp = false

    private var needsAuthorization: Bool { unavailableDevice?.status == "unauthorized" }
    private var needsAttention: Bool { unavailableDevice != nil || isUSBOccupied }
    private var scanInProgress: Bool { isDetecting }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    introduction
                    discoveryStatus

                    HStack(alignment: .top, spacing: 18) {
                        usbCard
                        wirelessCard
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    setupHelp
                    footer
                }
                .frame(maxWidth: 880)
                .frame(maxWidth: .infinity)
                .frame(minHeight: max(0, geometry.size.height - 40))
                .padding(20)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var introduction: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: [.blue.opacity(0.15), .cyan.opacity(0.06)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 33, weight: .light))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Connect your Android")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                Text("Your files, right here on your Mac. Choose how to connect.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var statusTitle: String {
        if needsAuthorization {
            return unavailableDevice?.isWireless == true ? "Pair your phone again" : "Allow access on your phone"
        }
        if unavailableDevice != nil { return "Your device needs attention" }
        if isUSBOccupied { return "USB is being used by another app" }
        if userDisconnected { return "Wireless reconnect is paused" }
        if isSearchingWireless && scanInProgress { return "Looking for your paired device" }
        if isDetecting { return "Checking for connected devices" }
        if recognizedWirelessDevices.contains(where: \.isNearby) { return "A recognized device is nearby" }
        if scanTimedOut { return "No device found" }
        return "Ready when you are"
    }

    private var statusDetail: String {
        if needsAuthorization {
            if unavailableDevice?.isWireless == true {
                return "Wireless access needs authorization. Open Wireless debugging on your phone and pair again below."
            }
            return "Unlock \(unavailableDevice?.displayName ?? "your phone") and accept the debugging prompt to continue."
        }
        if let device = unavailableDevice {
            return "\(device.displayName) is offline. \(device.isWireless ? "Enable Wireless debugging and check that both devices are on the same Wi-Fi." : "Reconnect the USB cable and keep your phone unlocked.")"
        }
        if isUSBOccupied { return "Use Claim USB below to release the connection and try again." }
        if userDisconnected { return "Scan USB & Wi-Fi to resume, or open Nearby devices to connect to a phone." }
        if isSearchingWireless && scanInProgress { return "Checking the local network for a previously paired phone. You can also connect below." }
        if isDetecting { return "Checking USB and existing wireless connections. Setup options are ready to use." }
        if recognizedWirelessDevices.contains(where: \.isNearby) { return "Open Nearby devices to connect, or pair a new phone with a QR code." }
        if scanTimedOut { return "Enable Wireless debugging on the same Wi-Fi, or connect a USB cable. We’ll keep checking in the background." }
        return "No device connected yet. Plug in a USB cable or pair your phone over Wi-Fi."
    }

    private var discoveryStatus: some View {
        HStack(alignment: .center, spacing: 14) {
            Group {
                if scanInProgress && !needsAttention && !userDisconnected {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: needsAttention ? "exclamationmark.circle.fill" : "dot.radiowaves.left.and.right")
                        .font(.system(size: 21))
                        .foregroundStyle(needsAttention ? Color.orange : Color.accentColor)
                }
            }
            .frame(width: 28)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(statusDetail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 7) {
                if let onRetry {
                    Button(action: onRetry) {
                        Label(scanInProgress ? "Scanning…" : "Scan USB & Wi-Fi", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(scanInProgress || isClaimingUSB || isRefreshingRecognizedDevices)
                    .help("Check USB connections and refresh wireless discovery")
                }
                if isDetecting && !needsAttention && !userDisconnected, let scanStartedAt {
                    TimelineView(.periodic(from: scanStartedAt, by: 1)) { context in
                        Text("\(min(Int(scanTimeout), max(0, Int(context.date.timeIntervalSince(scanStartedAt)))))s / \(Int(scanTimeout))s")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Checks both connection methods")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize()
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background((needsAttention ? Color.orange : Color.accentColor).opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder((needsAttention ? Color.orange : Color.accentColor).opacity(0.14)))
        .accessibilityElement(children: .contain)
    }

    private var usbCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            cardHeader(title: "USB cable", subtitle: "Plug in and get started", icon: "cable.connector", tint: .blue, badge: "DIRECT")

            VStack(alignment: .leading, spacing: 12) {
                step(1, "Connect your phone to this Mac", detail: "Use a cable that supports data transfer.")
                step(2, "Enable USB debugging", detail: "Settings → Developer options.")
                step(3, "Allow access on your phone", detail: "Unlock your phone and accept the prompt.")
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)

            Divider()
            connectionLabel(usbStatus, icon: usbNeedsAttention ? "exclamationmark.circle" : "cable.connector",
                            tint: usbNeedsAttention ? .orange : .secondary)

            if isUSBOccupied, let onClaimUSB {
                Button(action: onClaimUSB) {
                    Label(isClaimingUSB ? "Claiming USB…" : "Claim USB", systemImage: "cable.connector")
                        .frame(maxWidth: .infinity, minHeight: 22)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isClaimingUSB || isCheckingDevices)
                .help("Release USB from the other app and retry the connection")
            }
            Text("Connects automatically once access is allowed")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cardBackground)
    }

    private var usbNeedsAttention: Bool {
        isUSBOccupied || unavailableDevice.map { !$0.isWireless } == true
    }

    private var usbStatus: String {
        if isClaimingUSB { return "Releasing USB connection…" }
        if isUSBOccupied { return "Connection occupied by another app" }
        if let device = unavailableDevice, !device.isWireless {
            return needsAuthorization ? "Waiting for approval on your phone" : "USB device is offline"
        }
        if isCheckingDevices { return "Checking USB connections…" }
        return "Waiting for a USB device"
    }

    private var wirelessCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader(title: "Wi-Fi", subtitle: "Your files, without a cable", icon: "wifi", tint: .teal, badge: "ANDROID 11+")

            VStack(alignment: .leading, spacing: 12) {
                step(1, "Join the same Wi-Fi network", detail: "Connect your phone and Mac to one network.")
                step(2, "Enable Wireless debugging", detail: "Settings → Developer options.")
                step(3, "Pair once, reconnect automatically", detail: "Scan a QR code or enter a pairing code.")
            }
            .frame(maxWidth: .infinity, minHeight: 116, alignment: .topLeading)

            if let onConnectWiFi {
                Button { onConnectWiFi(.qrCode) } label: {
                    Label("QR Code", systemImage: "qrcode")
                        .frame(maxWidth: .infinity, minHeight: 22)
                }
                .buttonStyle(.borderedProminent)

                HStack {
                    Button("Nearby devices") { onConnectWiFi(.autoDiscovery) }
                    Spacer(minLength: 8)
                    Button("Connect manually") { onConnectWiFi(.manual) }
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.link)
            }

            Divider()
            recognizedDevicesSection
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cardBackground)
    }

    private var recognizedDevicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Previously recognized")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                if let lastRecognizedRefreshDate, !isRefreshingRecognizedDevices {
                    Text(lastRecognizedRefreshDate, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help("Last completed availability check")
                }
                if let onRefreshRecognizedDevices {
                    Button(action: onRefreshRecognizedDevices) {
                        HStack(spacing: 4) {
                            if isRefreshingRecognizedDevices {
                                ProgressView().controlSize(.mini)
                                    .accessibilityHidden(true)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(isRefreshingRecognizedDevices ? "Checking…" : "Refresh")
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .disabled(isRefreshingRecognizedDevices || scanInProgress || recognizedWirelessDevices.isEmpty)
                    .accessibilityLabel("Refresh previously recognized devices")
                    .help("Check which recognized Wi-Fi devices are currently available")
                }
            }
            if let recognizedRefreshError {
                Text(recognizedRefreshError)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if recognizedWirelessDevices.isEmpty {
                Text("Your phones will appear here after you pair them. Availability updates automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(recognizedWirelessDevices) { device in
                            recognizedDeviceRow(device)
                        }
                    }
                }
                .frame(height: CGFloat(min(recognizedWirelessDevices.count, 2)) * 44 - 8)
                if recognizedWirelessDevices.count > 2 {
                    Text("\(recognizedWirelessDevices.count) recognized devices · Scroll to see all")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func recognizedDeviceRow(_ device: RecognizedWirelessDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.system(size: 16))
                .foregroundStyle(device.isNearby ? Color.teal : .secondary)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .help(device.displayName)
                Text(isRefreshingRecognizedDevices ? "Checking availability…" :
                        (device.address.map { "Available now · \($0)" } ?? "Not currently found"))
                    .font(.system(size: 10))
                    .foregroundStyle(device.isNearby ? Color.teal : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 36)
        .accessibilityElement(children: .combine)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
            .shadow(color: .black.opacity(0.025), radius: 10, y: 3)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08)))
    }

    private func cardHeader(title: String, subtitle: String, icon: String, tint: Color, badge: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.system(size: 18, weight: .semibold))
                    Spacer(minLength: 4)
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func step(_ number: Int, _ title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Color.primary.opacity(0.045), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connectionLabel(_ text: String, icon: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 16, alignment: .leading)
    }

    private var setupHelp: some View {
        DisclosureGroup(isExpanded: $showSetupHelp) {
            HStack(alignment: .top, spacing: 24) {
                helpColumn("Find Developer options", text: "Open Settings → About phone and tap Build number seven times. On some phones, Build number is inside Software information. Return to Settings → System → Developer options.")
                helpColumn("Still unable to connect?", text: "USB: try another data cable or port, then toggle USB debugging. Wi-Fi: keep Wireless debugging open and check the network. If discovery is unavailable on your network, use Connect manually.")
            }
            .padding(.top, 12)
        } label: {
            Label("Need help getting connected?", systemImage: "questionmark.circle")
                .font(.system(size: 12, weight: .medium))
        }
        .tint(.secondary)
    }

    private func helpColumn(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: userDisconnected ? "pause.circle" : "arrow.triangle.2.circlepath")
                .accessibilityHidden(true)
            Text(userDisconnected ? "USB detection stays active" : "Connections are checked automatically")
            if let lastCheckedAt, !isDetecting {
                Text("·")
                Text(lastCheckedAt, style: .time)
                    .help("Last completed connection check")
                    .accessibilityLabel("Last checked at \(lastCheckedAt.formatted(date: .omitted, time: .shortened))")
            }
            Spacer(minLength: 12)
            if let diagnosticsControl {
                ReportIssueInlineView(diagnosticsControl: diagnosticsControl)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Inline Report Issue View for Empty State

private struct ReportIssueInlineView: View {
    @ObservedObject var diagnosticsControl: DiagnosticsControl
    @State private var showPopover = false

    private let githubIssueURL = URL(string: "https://github.com/Santosh7017/AndroidFileSync/issues/new")!

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.subheadline)
                Text("Report an Issue")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help("Report an issue or enable diagnostic logs")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            ReportIssuePopoverView(diagnosticsControl: diagnosticsControl)
        }
    }
}
