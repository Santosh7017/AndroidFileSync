import SwiftUI

struct SidebarView: View {
    let quickAccessItems: [QuickAccessItem]
    let currentPath: String
    let onNavigate: (String) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Quick Access")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
            
            Divider()
            
            // Quick Access List
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(quickAccessItems) { item in
                        QuickAccessRow(
                            item: item,
                            isSelected: currentPath == item.path,
                            onTap: { onNavigate(item.path) }
                        )
                    }
                }
                .padding(.vertical, 8)
            }
            
            Spacer()
            
            // Footer info
            VStack(spacing: 4) {
                Divider()
                HStack {
                    Image(systemName: "info.circle")
                        .font(.caption)
                    Text("Click to navigate")
                        .font(.caption2)
                    Spacer()
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 200)
        .background(Color(NSColor.controlBackgroundColor))
    }
}

struct QuickAccessRow: View {
    let item: QuickAccessItem
    let isSelected: Bool
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .foregroundColor(Color(item.color.color))
                    .frame(width: 20)
                
                Text(item.name)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.blue.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
