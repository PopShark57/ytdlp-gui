import SwiftUI

/// Floats the composer's transient status message over the top of whatever tab is showing.
///
/// The message often follows an action that also switches tabs (queueing several links, or a
/// replayed download whose unsafe options were removed), so it lives above the tabs rather than
/// on the Download screen, where it would go unseen.
struct StatusToastHost: View {
    var message: String?
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            if let message {
                StatusToast(message: message, onDismiss: onDismiss)
                    .id(message)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .animation(.spring(duration: 0.35), value: message)
    }
}

/// A capsule that shows one short message and goes away when tapped or swiped up.
struct StatusToast: View {
    var message: String
    var onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            Label {
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: 560)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .modifier(ToastBackground())
        .gesture(
            DragGesture(minimumDistance: 8).onEnded { value in
                if value.translation.height < 0 { onDismiss() }
            }
        )
        .accessibilityHint("Dismisses the message")
        .onAppear {
            AccessibilityNotification.Announcement(message).post()
        }
    }
}

/// Liquid Glass where the system has it, a material capsule before that.
private struct ToastBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: .capsule)
                .shadow(radius: 10, y: 3)
        }
    }
}

#Preview {
    Color.clear
        .overlay(alignment: .top) {
            StatusToastHost(message: "Queued 3 links.") {}
        }
}
