import SwiftUI

extension DownloadState {
    /// The colour that marks this state wherever a download appears, so a failure reads the same
    /// in a row, a header and a badge.
    var tint: Color {
        switch self {
        case .active: .accentColor
        case .completed: .green
        case .failed: .red
        case .queued, .cancelled: .secondary
        }
    }
}

/// What a download is doing right now, as a symbol and a few words.
struct PhaseLabel: View {
    var phase: DownloadPhase
    var state: DownloadState

    var body: some View {
        Label {
            Text(phase.displayName)
        } icon: {
            Image(systemName: phase.symbolName)
                .contentTransition(.symbolEffect(.replace))
        }
        .foregroundStyle(state.tint)
    }
}

/// A small tinted capsule for a status or a count, e.g. "Live" or "12 items".
struct StatusBadge: View {
    var text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

/// A toggle whose label explains what the option does, for options whose names alone don't.
struct ExplainedToggle: View {
    var title: String
    var explanation: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let explanation {
                    Text(explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A row that says something needs attention, with the reason beneath it.
struct WarningRow: View {
    var message: String
    var systemImage: String = "exclamationmark.triangle.fill"
    var tint: Color = .orange

    var body: some View {
        Label {
            Text(message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }
}

/// Lays its children out in rows, starting a new row when one is full.
///
/// Used for badges, which must stay readable at the largest text sizes rather than being
/// squeezed or truncated on a single line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(of: subviews, within: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let origins = arrangement(of: subviews, within: bounds.width).origins
        for (subview, origin) in zip(subviews, origins) {
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func arrangement(of subviews: Subviews, within maximumWidth: CGFloat) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var cursor = CGPoint.zero
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursor.x > 0, cursor.x + size.width > maximumWidth {
                cursor.x = 0
                cursor.y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(cursor)
            widest = max(widest, cursor.x + size.width)
            cursor.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, CGSize(width: widest, height: cursor.y + rowHeight))
    }
}

#Preview {
    List {
        PhaseLabel(phase: .downloading, state: .active)
        PhaseLabel(phase: .completed, state: .completed)
        PhaseLabel(phase: .failed, state: .failed)
        FlowLayout {
            StatusBadge(text: "Live", systemImage: "dot.radiowaves.left.and.right", tint: .red)
            StatusBadge(text: "12 items", systemImage: "list.number", tint: .accentColor)
            StatusBadge(text: "18+", systemImage: "exclamationmark.shield", tint: .orange)
        }
        WarningRow(message: "Subtitles are saved next to the video on iPhone and iPad.")
    }
}
