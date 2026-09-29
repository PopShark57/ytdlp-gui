import SwiftUI

/// Content stays on quiet, opaque surfaces. Glass is reserved for interactive controls.
enum MobileTheme {
    static let onAccent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.025, green: 0.035, blue: 0.055, alpha: 1)
            : .white
    })
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.45, green: 0.73, blue: 1, alpha: 1)
            : UIColor(red: 0.12, green: 0.35, blue: 0.77, alpha: 1)
    })
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.025, green: 0.035, blue: 0.055, alpha: 1)
            : UIColor(red: 0.94, green: 0.96, blue: 0.99, alpha: 1)
    })
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.075, green: 0.09, blue: 0.12, alpha: 1)
            : .secondarySystemGroupedBackground
    })
}

struct MobileBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        MobileTheme.canvas
            .overlay(alignment: .topTrailing) {
                if !reduceTransparency {
                    RadialGradient(
                        colors: [MobileTheme.accent.opacity(0.12), .clear],
                        center: .topTrailing, startRadius: 0, endRadius: 520
                    )
                }
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

extension View {
    func mobileScreen() -> some View {
        scrollContentBackground(.hidden)
            .background { MobileBackdrop() }
    }

    func mobileCardRow() -> some View {
        listRowBackground(MobileTheme.surface)
            .listRowSeparator(.hidden)
    }

    func mobileGlassButton(prominent: Bool = false) -> some View {
        modifier(MobileGlassButton(prominent: prominent))
    }

    @ViewBuilder
    func mobileGlassGroup() -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { self }
        } else {
            self
        }
    }
}

private struct MobileGlassButton: ViewModifier {
    var prominent: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            if prominent {
                content.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
            } else {
                content.buttonStyle(.glass).buttonBorderShape(.capsule)
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.capsule)
        }
    }
}

/// A short introduction, reused across the main screens without adding another toolbar.
struct ScreenIntroduction: View {
    var eyebrow: String
    var title: String
    var detail: String
    var symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(eyebrow, systemImage: symbol)
                .font(.caption.weight(.bold))
                .tracking(1.5)
                .foregroundStyle(MobileTheme.accent)
            Text(title)
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
    }
}

struct LibraryEmptyState: View {
    var title: String
    var detail: String
    var symbol: String
    var action: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: symbol)
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(MobileTheme.accent)
                    .frame(width: 112, height: 112)
                    .background(MobileTheme.surface, in: .rect(cornerRadius: 32))
                    .overlay {
                        RoundedRectangle(cornerRadius: 32)
                            .strokeBorder(MobileTheme.accent.opacity(0.2))
                    }
                    .accessibilityHidden(true)
                VStack(spacing: 10) {
                    Text(title)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    Text(detail)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button(action: action) {
                    Label("Go to Download", systemImage: "plus")
                        .font(.headline)
                        .foregroundStyle(MobileTheme.onAccent)
                        .padding(.horizontal, 12)
                }
                .mobileGlassButton(prominent: true)
                .controlSize(.large)
            }
            .frame(maxWidth: 420)
            .padding(32)
            .frame(maxWidth: .infinity)
            .padding(.top, 64)
        }
    }
}
