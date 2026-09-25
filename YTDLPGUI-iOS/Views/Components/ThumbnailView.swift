import SwiftUI

/// Artwork for a video, a playlist or a history entry, with a placeholder while it loads or when
/// there is none.
///
/// The frame is always 16:9, so a row keeps its height whether or not the image ever arrives.
/// Nearly every site serves 16:9 artwork, and a layout that doesn't jump matters more than
/// showing the occasional square thumbnail uncropped. Callers set only the width.
struct ThumbnailView: View {
    var url: URL?
    var placeholderSymbol: String = "photo"
    var cornerRadius: CGFloat = 8

    var body: some View {
        Rectangle()
            .fill(.fill.tertiary)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { artwork }
            .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var artwork: some View {
        if let url {
            AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.2))) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .empty:
                    ProgressView()
                        .controlSize(.small)
                case .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Image(systemName: placeholderSymbol)
            .font(.title3)
            .foregroundStyle(.secondary)
    }
}

#Preview {
    VStack(spacing: 16) {
        ThumbnailView(url: nil, placeholderSymbol: "film")
            .frame(width: 160)
        ThumbnailView(url: nil, placeholderSymbol: "music.note", cornerRadius: 6)
            .frame(width: 88)
    }
    .padding()
}
