import SwiftUI
import AppKit

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
        VStack(spacing: 0) {
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
            
            // Subtle native footer
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 12) {
                    // FooterLink(
                    //     icon: Image(systemName: "cup.and.saucer.fill").font(.system(size: 11)),
                    //     title: "Buy me a coffee",
                    //     destination: URL(string: "https://www.buymeacoffee.com/Santosh7017")!
                    // )
                    
                    Spacer()
                    
                    FooterLink(
                        icon: GitHubIcon(size: 11, color: .secondary),
                        title: "GitHub",
                        destination: URL(string: "https://github.com/Santosh7017/AndroidFileSync")!
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.3))
            }
        }
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

// MARK: - GitHub Icon Drawing
struct GitHubIcon: View {
    var size: CGFloat = 16
    var color: Color = .secondary
    
    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 16, y: size.height / 16)
            var path = Path()
            
            path.move(to: CGPoint(x: 8, y: 0))
            path.addCurve(to: CGPoint(x: 16, y: 8), control1: CGPoint(x: 12.42, y: 0), control2: CGPoint(x: 16, y: 3.58))
            path.addCurve(to: CGPoint(x: 10.55, y: 15.59), control1: CGPoint(x: 16, y: 11.54), control2: CGPoint(x: 13.71, y: 14.53))
            path.addCurve(to: CGPoint(x: 10, y: 15.21), control1: CGPoint(x: 10.15, y: 15.67), control2: CGPoint(x: 10, y: 15.42))
            path.addCurve(to: CGPoint(x: 10.01, y: 13.01), control1: CGPoint(x: 10, y: 14.94), control2: CGPoint(x: 10.01, y: 14.08))
            path.addCurve(to: CGPoint(x: 9.47, y: 11.53), control1: CGPoint(x: 10.01, y: 12.26), control2: CGPoint(x: 9.76, y: 11.78))
            path.addCurve(to: CGPoint(x: 13.12, y: 7.58), control1: CGPoint(x: 11.25, y: 11.33), control2: CGPoint(x: 13.12, y: 10.65))
            path.addCurve(to: CGPoint(x: 12.3, y: 5.43), control1: CGPoint(x: 13.12, y: 6.7), control2: CGPoint(x: 12.81, y: 5.99))
            path.addCurve(to: CGPoint(x: 12.38, y: 3.31), control1: CGPoint(x: 12.38, y: 5.23), control2: CGPoint(x: 12.66, y: 4.41))
            path.addCurve(to: CGPoint(x: 10.18, y: 4.13), control1: CGPoint(x: 12.38, y: 3.31), control2: CGPoint(x: 11.71, y: 3.09))
            path.addCurve(to: CGPoint(x: 8.18, y: 3.86), control1: CGPoint(x: 9.54, y: 3.95), control2: CGPoint(x: 8.86, y: 3.86))
            path.addCurve(to: CGPoint(x: 6.18, y: 4.13), control1: CGPoint(x: 7.5, y: 3.86), control2: CGPoint(x: 6.82, y: 3.95))
            path.addCurve(to: CGPoint(x: 3.98, y: 3.31), control1: CGPoint(x: 4.65, y: 3.09), control2: CGPoint(x: 3.98, y: 3.31))
            path.addCurve(to: CGPoint(x: 4.06, y: 5.43), control1: CGPoint(x: 3.82, y: 4.41), control2: CGPoint(x: 4.1, y: 5.23))
            path.addCurve(to: CGPoint(x: 3.24, y: 7.58), control1: CGPoint(x: 3.55, y: 5.99), control2: CGPoint(x: 3.24, y: 6.7))
            path.addCurve(to: CGPoint(x: 6.88, y: 11.53), control1: CGPoint(x: 3.24, y: 10.65), control2: CGPoint(x: 5.1, y: 11.33))
            path.addCurve(to: CGPoint(x: 6.37, y: 12.6), control1: CGPoint(x: 6.65, y: 11.73), control2: CGPoint(x: 6.44, y: 12.08))
            path.addCurve(to: CGPoint(x: 4.04, y: 12.1), control1: CGPoint(x: 5.91, y: 12.81), control2: CGPoint(x: 4.76, y: 12.45))
            path.addCurve(to: CGPoint(x: 2.81, y: 11.28), control1: CGPoint(x: 3.89, y: 11.86), control2: CGPoint(x: 3.44, y: 11.27))
            path.addCurve(to: CGPoint(x: 1.58, y: 10.46), control1: CGPoint(x: 2.21, y: 11.04), control2: CGPoint(x: 1.76, y: 10.47))
            path.addCurve(to: CGPoint(x: 1.59, y: 10.99), control1: CGPoint(x: 0.91, y: 10.47), control2: CGPoint(x: 1.31, y: 10.84))
            path.addCurve(to: CGPoint(x: 2.41, y: 12.12), control1: CGPoint(x: 1.93, y: 11.18), control2: CGPoint(x: 2.32, y: 11.89))
            path.addCurve(to: CGPoint(x: 5.1, y: 12.62), control1: CGPoint(x: 2.57, y: 12.57), control2: CGPoint(x: 3.09, y: 12.97))
            path.addCurve(to: CGPoint(x: 5.11, y: 14.11), control1: CGPoint(x: 5.1, y: 13.28), control2: CGPoint(x: 5.11, y: 13.92))
            path.addCurve(to: CGPoint(x: 4.56, y: 14.49), control1: CGPoint(x: 5.11, y: 14.3), control2: CGPoint(x: 4.96, y: 14.55))
            path.addCurve(to: CGPoint(x: 0, y: 8), control1: CGPoint(x: 1.91, y: 13.74), control2: CGPoint(x: 0, y: 11.54))
            path.addCurve(to: CGPoint(x: 8, y: 0), control1: CGPoint(x: 0, y: 3.58), control2: CGPoint(x: 3.58, y: 0))
            path.closeSubpath()
            
            context.fill(path, with: .color(color))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Footer Link View
struct FooterLink<Icon: View>: View {
    let icon: Icon
    let title: String
    let destination: URL
    @State private var isHovered = false
    
    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 4) {
                icon
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(isHovered ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .onHover { hover in
            isHovered = hover
            if hover {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
