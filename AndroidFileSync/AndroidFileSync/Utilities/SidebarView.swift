import SwiftUI

struct SidebarView: View {
    @ObservedObject var sidebarManager: SidebarManager
    let currentPath: String
    let onNavigate: (String) -> Void
    var trashCount: Int = 0
    var onOpenTrash: (() -> Void)? = nil
    var activeAppFilter: AppFilter? = nil
    var onSelectAppFilter: ((AppFilter) -> Void)? = nil
    var storageStats: [String: DeviceManager.StorageInfo] = [:]

    @State private var showRestoreAlert = false
    
    enum SidebarItem: Hashable {
        case folder(String)
        case apps
    }
    
    // Derived binding to map external state to List selection
    private var selectionBinding: Binding<SidebarItem?> {
        Binding {
            if onSelectAppFilter != nil && activeAppFilter != nil { return .apps }
            return .folder(currentPath)
        } set: { newValue in
            guard let val = newValue else { return }
            switch val {
            case .folder(let path):
                onNavigate(path)
            case .apps:
                onSelectAppFilter?(.user)
            }
        }
    }

    var body: some View {
        List(selection: selectionBinding) {

            // ── Quick Access ────────────────────────────────────────────────
            Section {
                ForEach(sidebarManager.visibleItems.filter { item in
                    !sidebarManager.checkedPaths.contains(item.path)
                        || sidebarManager.existingPaths.contains(item.path)
                }) { item in
                    QuickAccessRow(
                        item: item,
                        isChecking: !sidebarManager.checkedPaths.contains(item.path),
                        storageInfo: storageStats[item.path],
                        onRemove: { sidebarManager.removeItem(item) }
                    )
                    .tag(SidebarItem.folder(item.path))
                }
            } header: {
                HStack {
                    Text("Quick Access")
                    Spacer()
                    if sidebarManager.hasHiddenBuiltIns {
                        Button {
                            showRestoreAlert = true
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .foregroundColor(.orange)
                        }
                        .buttonStyle(.plain)
                        .help("Restore hidden default folders")
                    }
                }
            }
            
            // ── Apps Section ─────────────────────────────────────────────────
            if onSelectAppFilter != nil {
                Section("Apps") {
                    Label("Apps", systemImage: "square.grid.2x2.fill")
                        .tag(SidebarItem.apps)
                }
            }
            
            if let openTrash = onOpenTrash {
                Section("Trash") {
                    Button(action: openTrash) {
                        HStack {
                            Label("Trash", systemImage: trashCount > 0 ? "trash.fill" : "trash")
                                .foregroundColor(trashCount > 0 ? .red : .primary)
                            Spacer()
                            if trashCount > 0 {
                                Text("\(trashCount)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.red)
                                    .cornerRadius(8)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
        .alert("Restore Default Folders?", isPresented: $showRestoreAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Restore") { sidebarManager.restoreBuiltIns() }
        } message: {
            Text("All hidden default folders will reappear in the sidebar.")
        }
        .onAppear {
            Task { await sidebarManager.checkExistence() }
        }
        .onChange(of: sidebarManager.visibleItems.count) { _ in
            Task { await sidebarManager.checkExistence() }
        }
    }

    // appsSection removed because it's inline in the List
} // end SidebarView

// MARK: - Row

struct QuickAccessRow: View {
    let item: QuickAccessItem
    /// True while the ADB existence check is still in flight for this item
    let isChecking: Bool
    var storageInfo: DeviceManager.StorageInfo? = nil
    var onRemove: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                    .foregroundColor(Color(item.color.color))

                Text(item.name)
                    .lineLimit(1)

                Spacer()

                if isChecking {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                }
            }

                // Storage gauge — only shown when stats are available
                if let storage = storageInfo {
                    VStack(alignment: .leading, spacing: 2) {
                        // Progress bar
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(height: 3)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(storageBarColor(fraction: storage.usedFraction))
                                    .frame(width: geo.size.width * storage.usedFraction, height: 3)
                            }
                        }
                        .frame(height: 3)
                        .padding(.leading, 30)

                        Text(storage.usedText)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.leading, 30)
                    }
                }
            }
        .contextMenu {
            if item.isBuiltIn {
                Button(role: .destructive) {
                    onRemove?()
                } label: {
                    Label("Hide from Sidebar", systemImage: "eye.slash")
                }
            } else {
                Button(role: .destructive) {
                    onRemove?()
                } label: {
                    Label("Remove from Sidebar", systemImage: "minus.circle")
                }
            }
        }
    }

    private func storageBarColor(fraction: Double) -> Color {
        if fraction > 0.9 { return .red }
        if fraction > 0.8 { return .orange }
        return .blue
    }
}
