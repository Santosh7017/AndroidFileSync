// Views/AppBrowserView.swift
// Main app management interface shown when an Apps sidebar entry is selected

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppBrowserView: View {
    @ObservedObject var appManager: AppManager
    let initialFilter: AppFilter

    @State private var selectedFilter: AppFilter
    @State private var searchQuery = ""
    @State private var selectedPackages: Set<String> = []
    @State private var sortOption: AppSortOption = .name
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var showBatchConfirm = false

    // Confirmation state for single-app destructive actions
    @State private var pendingAction: AppAction? = nil
    @State private var pendingApp: AppInfo? = nil
    @State private var showActionConfirm = false

    enum AppSortOption: String, CaseIterable {
        case name    = "Name"
        case package = "Package"
    }

    init(appManager: AppManager, initialFilter: AppFilter) {
        self.appManager = appManager
        self.initialFilter = initialFilter
        _selectedFilter = State(initialValue: initialFilter)
    }

    // MARK: - Filtered + Sorted apps

    private var displayedApps: [AppInfo] {
        var result = appManager.apps

        if !searchQuery.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchQuery) ||
                $0.packageName.localizedCaseInsensitiveContains(searchQuery)
            }
        }

        switch sortOption {
        case .name:    result.sort { $0.displayName.lowercased() < $1.displayName.lowercased() }
        case .package: result.sort { $0.packageName < $1.packageName }
        }

        return result
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .task(id: selectedFilter) {
            await appManager.fetchApps(filter: selectedFilter)
            selectedPackages = []
        }
        .alert("Result", isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .confirmationDialog(
            batchConfirmTitle,
            isPresented: $showBatchConfirm,
            titleVisibility: .visible
        ) {
            Button(batchConfirmActionLabel, role: .destructive) {
                Task { await performBatchAction() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(batchConfirmMessage)
        }
        // Single-app destructive action confirmation
        .confirmationDialog(
            confirmTitle,
            isPresented: $showActionConfirm,
            titleVisibility: .visible
        ) {
            Button(confirmLabel, role: .destructive) {
                if let action = pendingAction, let app = pendingApp {
                    Task { await executeAction(action, app: app) }
                }
                pendingAction = nil; pendingApp = nil
            }
            Button("Cancel", role: .cancel) {
                pendingAction = nil; pendingApp = nil
            }
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            // Filter picker
            Picker("", selection: $selectedFilter) {
                ForEach(AppFilter.allCases) { filter in
                    Label(filter.rawValue, systemImage: filter.icon).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            Spacer()

            // Install APK button
            Button {
                Task { await pickAndInstallAPK() }
            } label: {
                Label("Install APK", systemImage: "plus.app")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .help("Install an APK file from your Mac")

            // Batch action button — label and action depend on current filter
            if !selectedPackages.isEmpty {
                Button {
                    showBatchConfirm = true
                } label: {
                    Label(batchButtonLabel, systemImage: batchButtonIcon)
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderedProminent)
                .tint(batchButtonTint)
            }

            // Sort
            Menu {
                ForEach(AppSortOption.allCases, id: \.self) { opt in
                    Button {
                        sortOption = opt
                    } label: {
                        HStack {
                            Text(opt.rawValue)
                            if sortOption == opt {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .help("Sort apps")

            // Refresh
            Button {
                Task { await appManager.fetchApps(filter: selectedFilter) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh app list")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if appManager.isLoading {
            // ── Loading state — full-page spinner ────────────────────────────
            Spacer()
            VStack(spacing: 12) {
                ProgressView().scaleEffect(1.2)
                Text(appManager.statusMessage)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            Spacer()
        } else if let error = appManager.errorMessage {
            // ── Error state ──────────────────────────────────────────────────
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundColor(.orange)
                Text(error)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }
            .padding()
            Spacer()
        } else {
            // ── Loaded — always show search + status + list ──────────────────
            VStack(spacing: 0) {

                // Search bar — ALWAYS visible once apps are loaded
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search apps...", text: $searchQuery)
                        .textFieldStyle(.plain)
                    if !searchQuery.isEmpty {
                        Button { searchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                // Status bar
                HStack {
                    Text(appManager.statusMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    if !selectedPackages.isEmpty {
                        Text("\(selectedPackages.count) selected")
                            .font(.system(size: 11))
                            .foregroundColor(.blue)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)

                Divider()

                // List area — shows empty state OR app rows
                if displayedApps.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text(searchQuery.isEmpty ? "No apps found." : "No results for \"\(searchQuery)\"")
                            .foregroundColor(.secondary)
                        if !searchQuery.isEmpty {
                            Button("Clear Search") { searchQuery = "" }
                                .buttonStyle(.bordered)
                                .font(.system(size: 12))
                        }
                    }
                    Spacer()
                } else {
                    List(displayedApps, id: \.id, selection: $selectedPackages) { app in
                        AppRowView(app: app, appManager: appManager) { action in
                            Task { await handleAction(action, app: app) }
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
    }

    // MARK: - Actions

    enum AppAction {
        case uninstall
        case disable
        case enable
        case backupAPK
        case clearData
        case clearCache
        case forceStop
    }

    private func handleAction(_ action: AppAction, app: AppInfo) async {
        switch action {
        case .uninstall, .disable, .clearData, .clearCache:
            // These are destructive — ask for confirmation first
            await MainActor.run {
                pendingAction = action
                pendingApp = app
                showActionConfirm = true
            }

        case .enable:
            let (ok, msg) = await appManager.enableApp(package: app.packageName)
            if ok { await appManager.fetchApps(filter: selectedFilter) }
            showResult(msg)

        case .backupAPK:
            let (_, msg) = await appManager.backupAPK(package: app.packageName, displayName: app.displayName)
            showResult(msg)

        case .forceStop:
            let (_, msg) = await appManager.forceStop(package: app.packageName)
            showResult(msg)
        }
    }

    /// Executes the action after user confirms.
    private func executeAction(_ action: AppAction, app: AppInfo) async {
        switch action {
        case .uninstall:
            let (ok, msg) = await appManager.uninstall(package: app.packageName)
            if ok { await appManager.fetchApps(filter: selectedFilter) }
            showResult(msg)

        case .disable:
            let (ok, msg) = await appManager.disableSystemApp(package: app.packageName)
            if ok { await appManager.fetchApps(filter: selectedFilter) }
            showResult(msg)

        case .clearData:
            let (_, msg) = await appManager.clearData(package: app.packageName)
            showResult(msg)

        case .clearCache:
            let (_, msg) = await appManager.clearCache(package: app.packageName)
            showResult(msg)

        default:
            break
        }
    }

    // Helpers for the confirmation dialog text
    private var confirmTitle: String {
        guard let action = pendingAction, let app = pendingApp else { return "Are you sure?" }
        switch action {
        case .uninstall:  return "Uninstall \(app.displayName)?"
        case .disable:    return "Disable \(app.displayName)?"
        case .clearData:  return "Clear data for \(app.displayName)?"
        case .clearCache: return "Clear cache for \(app.displayName)?"
        default:          return "Are you sure?"
        }
    }

    private var confirmLabel: String {
        guard let action = pendingAction else { return "Confirm" }
        switch action {
        case .uninstall:  return "Uninstall"
        case .disable:    return "Disable App"
        case .clearData:  return "Clear Data"
        case .clearCache: return "Clear Cache"
        default:          return "Confirm"
        }
    }

    private var confirmMessage: String {
        guard let action = pendingAction, let app = pendingApp else { return "" }
        switch action {
        case .uninstall:  return "\"\(app.displayName)\" will be permanently removed from the device."
        case .disable:    return "\"\(app.displayName)\" will be hidden and disabled for the current user."
        case .clearData:  return "All data (accounts, settings, files) for \"\(app.displayName)\" will be erased. This cannot be undone."
        case .clearCache: return "The cached data for \"\(app.displayName)\" will be cleared."
        default:          return ""
        }
    }

    // MARK: - Batch confirmation helpers (context-aware by filter & count)

    private var batchButtonLabel: String {
        let n = selectedPackages.count
        switch selectedFilter {
        case .system:   return n == 1 ? "Disable (1)" : "Disable (\(n))"
        case .disabled: return n == 1 ? "Enable (1)"  : "Enable (\(n))"
        default:        return n == 1 ? "Uninstall (1)" : "Uninstall (\(n))"
        }
    }

    private var batchButtonIcon: String {
        switch selectedFilter {
        case .system:   return "nosign"
        case .disabled: return "checkmark.circle"
        default:        return "trash"
        }
    }

    private var batchButtonTint: Color {
        switch selectedFilter {
        case .system:   return .orange
        case .disabled: return .green
        default:        return .red
        }
    }

    private var batchConfirmTitle: String {
        let n = selectedPackages.count
        let item = n == 1 ? "1 app" : "\(n) apps"
        switch selectedFilter {
        case .system:   return "Disable \(item)?"
        case .disabled: return "Enable \(item)?"
        default:        return "Uninstall \(item)?"
        }
    }

    private var batchConfirmActionLabel: String {
        let n = selectedPackages.count
        switch selectedFilter {
        case .system:   return n == 1 ? "Disable"   : "Disable All"
        case .disabled: return n == 1 ? "Enable"    : "Enable All"
        default:        return n == 1 ? "Uninstall" : "Uninstall All"
        }
    }

    private var batchConfirmMessage: String {
        switch selectedFilter {
        case .system:   return "The selected system apps will be disabled for the current user. They can be re-enabled later."
        case .disabled: return "The selected apps will be re-enabled and restored for the current user."
        default:        return "This will permanently remove the selected apps from your device."
        }
    }

    private func performBatchAction() async {
        switch selectedFilter {
        case .system:
            var failed: [String] = []
            for pkg in selectedPackages {
                let (ok, _) = await appManager.disableSystemApp(package: pkg)
                if !ok { failed.append(pkg) }
            }
            selectedPackages = []
            await appManager.fetchApps(filter: selectedFilter)
            showResult(failed.isEmpty
                ? "All selected system apps disabled."
                : "Some apps could not be disabled: \(failed.joined(separator: ", "))")

        case .disabled:
            var failed: [String] = []
            for pkg in selectedPackages {
                let (ok, _) = await appManager.enableApp(package: pkg)
                if !ok { failed.append(pkg) }
            }
            selectedPackages = []
            await appManager.fetchApps(filter: selectedFilter)
            showResult(failed.isEmpty
                ? "All selected apps re-enabled."
                : "Some apps could not be enabled: \(failed.joined(separator: ", "))")

        default:
            let results = await appManager.batchUninstall(packages: Array(selectedPackages))
            let failed = results.filter { !$0.value }.keys
            selectedPackages = []
            await appManager.fetchApps(filter: selectedFilter)
            showResult(failed.isEmpty
                ? "All selected apps uninstalled successfully."
                : "Some apps could not be uninstalled: \(failed.joined(separator: ", "))")
        }
    }

    private func pickAndInstallAPK() async {
        let panel = NSOpenPanel()
        panel.title = "Select APK to Install"
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.allowsMultipleSelection = false

        guard await panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) == .OK,
              let url = panel.url else { return }

        let (ok, msg) = await appManager.installAPK(from: url)
        if ok { await appManager.fetchApps(filter: selectedFilter) }
        showResult(msg)
    }

    private func showResult(_ msg: String) {
        alertMessage = msg
        showAlert = true
    }
}

// MARK: - App Row

struct AppRowView: View {
    let app: AppInfo
    @ObservedObject var appManager: AppManager
    let onAction: (AppBrowserView.AppAction) -> Void

    var body: some View {
        HStack(spacing: 12) {
            // App icon — real if available, placeholder otherwise
            Group {
                if let realIcon = appManager.appIcons[app.packageName] {
                    Image(nsImage: realIcon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    // Letter-avatar placeholder: first letter + unique gradient per package
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                LinearGradient(
                                    colors: [avatarColor, avatarColor.opacity(0.7)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 36, height: 36)
                        Text(String(app.displayName.prefix(1)).uppercased())
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                // Name + status badges
                HStack(spacing: 6) {
                    Text(app.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(app.isEnabled ? .primary : .secondary)

                    if !app.isEnabled {
                        Text("Disabled")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }

                    if app.isSystemApp {
                        Text("System")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.12))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                }

                // Package name
                Text(app.packageName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .contextMenu {
            // ── Primary destructive action depends on app state ───────────────
            if !app.isEnabled {
                // Disabled app → only action is to re-enable
                Button {
                    onAction(.enable)
                } label: {
                    Label("Re-enable App", systemImage: "checkmark.circle")
                }
            } else if app.isSystemApp {
                // Enabled system app → can disable (soft-remove for user)
                Button(role: .destructive) {
                    onAction(.disable)
                } label: {
                    Label("Disable System App", systemImage: "nosign")
                }
            } else {
                // Regular user app → can uninstall
                Button(role: .destructive) {
                    onAction(.uninstall)
                } label: {
                    Label("Uninstall", systemImage: "trash")
                }
            }

            Divider()

            // ── Common actions ─────────────────────────────────────────────────
            Button {
                onAction(.backupAPK)
            } label: {
                Label("Backup APK to Mac", systemImage: "square.and.arrow.down")
            }

            Button {
                onAction(.forceStop)
            } label: {
                Label("Force Stop", systemImage: "stop.circle")
            }

            Divider()

            Button {
                onAction(.clearCache)
            } label: {
                Label("Clear Cache", systemImage: "trash.slash")
            }

            Button(role: .destructive) {
                onAction(.clearData)
            } label: {
                Label("Clear Data & Cache", systemImage: "externaldrive.badge.xmark")
            }
        }
    }

    /// Stable unique color derived from the package name hash.
    /// Gives each app a distinct, visually pleasant avatar background.
    private var avatarColor: Color {
        let palette: [Color] = [
            Color(hue: 0.00, saturation: 0.65, brightness: 0.75),
            Color(hue: 0.05, saturation: 0.70, brightness: 0.80),
            Color(hue: 0.08, saturation: 0.75, brightness: 0.80),
            Color(hue: 0.13, saturation: 0.70, brightness: 0.78),
            Color(hue: 0.28, saturation: 0.60, brightness: 0.60),
            Color(hue: 0.35, saturation: 0.65, brightness: 0.58),
            Color(hue: 0.50, saturation: 0.65, brightness: 0.65),
            Color(hue: 0.55, saturation: 0.60, brightness: 0.75),
            Color(hue: 0.60, saturation: 0.55, brightness: 0.80),
            Color(hue: 0.65, saturation: 0.60, brightness: 0.75),
            Color(hue: 0.72, saturation: 0.58, brightness: 0.72),
            Color(hue: 0.78, saturation: 0.55, brightness: 0.72),
            Color(hue: 0.85, saturation: 0.55, brightness: 0.72),
            Color(hue: 0.92, saturation: 0.60, brightness: 0.75),
        ]
        let hash = abs(app.packageName.hashValue)
        return palette[hash % palette.count]
    }
}
