import SwiftUI

extension View {
    /// Keeps a form or list at a comfortable reading width on iPad and in landscape, while its
    /// grouped background still fills the screen edge to edge.
    func readableContentWidth(_ maximumWidth: CGFloat = 720) -> some View {
        modifier(ReadableContentMargins(maximumWidth: maximumWidth))
    }

    /// Pins a bar to the bottom of a scrolling screen, above the tab bar and the keyboard.
    ///
    /// From iOS 26 the bar sits on the scroll edge effect like the system's own bars; before
    /// that it gets the standard bar material so content doesn't show through it.
    func bottomBar(@ViewBuilder _ bar: () -> some View) -> some View {
        modifier(BottomBar(bar: bar()))
    }
}

private struct ReadableContentMargins: ViewModifier {
    var maximumWidth: CGFloat
    @State private var containerWidth: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                containerWidth = width
            }
    }

    /// `nil` keeps the system margins, which are right until the container is noticeably wider
    /// than the readable width.
    private var horizontalMargin: CGFloat? {
        let margin = (containerWidth - maximumWidth) / 2
        return margin > 24 ? margin : nil
    }
}

private struct BottomBar<Bar: View>: ViewModifier {
    var bar: Bar

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: .bottom) { bar }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    bar
                }
                .background(.bar)
            }
        }
    }
}

/// Lays out a thumbnail beside its text, or above it at accessibility text sizes, where a
/// side-by-side row would leave only a sliver for the words.
struct ThumbnailRowLayout<Thumbnail: View, Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric private var thumbnailWidth: CGFloat

    private let thumbnail: Thumbnail
    private let content: Content

    init(
        thumbnailWidth: CGFloat,
        @ViewBuilder thumbnail: () -> Thumbnail,
        @ViewBuilder content: () -> Content
    ) {
        _thumbnailWidth = ScaledMetric(wrappedValue: thumbnailWidth, relativeTo: .body)
        self.thumbnail = thumbnail()
        self.content = content()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                thumbnail
                    .frame(maxWidth: 240)
                content
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                thumbnail
                    .frame(width: min(thumbnailWidth, 160))
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
