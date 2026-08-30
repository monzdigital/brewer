import SwiftUI
import AppKit

// MARK: - Package icon

struct PackageIconView: View {
    let package: BrewPackage
    var size: CGFloat = 30

    var body: some View {
        if let appPath = package.appPath {
            Image(nsImage: AppIconCache.shared.icon(forPath: appPath))
                .resizable()
                .frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(package.kind == .formula
                      ? AnyShapeStyle(Color.green.gradient.opacity(0.85))
                      : AnyShapeStyle(Color.blue.gradient.opacity(0.85)))
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: package.kind == .formula ? "shippingbox.fill" : "macwindow")
                        .font(.system(size: size * 0.5, weight: .medium))
                        .foregroundStyle(.white)
                }
        }
    }
}

// MARK: - Small chips & badges

struct KindChip: View {
    let kind: PackageKind

    var body: some View {
        Text(kind.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((kind == .formula ? Color.green : Color.blue).opacity(0.16), in: Capsule())
            .foregroundStyle(kind == .formula ? Color.green : Color.blue)
    }
}

struct TinyBadge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Cards

struct CardBackground: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill((tint ?? Color.primary).opacity(tint == nil ? 0.045 : 0.08))
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder((tint ?? Color.primary).opacity(0.12), lineWidth: 1)
            }
    }
}

extension View {
    func cardStyle(tint: Color? = nil) -> some View {
        modifier(CardBackground(tint: tint))
    }
}

struct StatTile: View {
    let value: String
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(title)
                    .font(.callout.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(tint: color)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Section header

struct PaneHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title.bold())
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Monospaced output console (doctor, diagnostics, …)

struct OutputTextView: View {
    let text: String
    var highlightWarnings = true

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(String(line))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(for: String(line)))
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    private func color(for line: String) -> Color {
        guard highlightWarnings else { return .primary }
        if line.hasPrefix("Warning:") { return .yellow }
        if line.hasPrefix("Error:") { return .red }
        if line.hasPrefix("==>") { return .cyan }
        return .primary.opacity(0.85)
    }
}

// MARK: - Flow layout for tag chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Busy overlay shown while a command runs and the console is closed

struct RunningOperationPill: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let operation = app.console.runningOperation, !app.console.isPresented {
            Button {
                app.console.isPresented = true
            } label: {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(operation.title)
                        .font(.callout)
                        .lineLimit(1)
                    Image(systemName: "chevron.up")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
