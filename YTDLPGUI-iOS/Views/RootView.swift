import SwiftUI

/// The app's frame: a tab bar on iPhone that becomes a sidebar on iPad.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        TabView(selection: $model.selectedTab) {
            Tab(AppTab.download.title, systemImage: AppTab.download.symbolName, value: AppTab.download) {
                DownloadTab()
            }

            Tab(AppTab.queue.title, systemImage: AppTab.queue.symbolName, value: AppTab.queue) {
                QueueView()
            }
            .badge(model.queue.activeCount + model.queue.queuedCount)

            Tab(AppTab.history.title, systemImage: AppTab.history.symbolName, value: AppTab.history) {
                HistoryView()
            }

            Tab(AppTab.settings.title, systemImage: AppTab.settings.symbolName, value: AppTab.settings) {
                SettingsView()
            }
        }
        .alert("Append shared links to your draft?", isPresented: Binding(
            get: { !model.sharesAwaitingAppend.isEmpty },
            set: { if !$0 { model.sharesAwaitingAppend = [] } }
        ), presenting: model.sharesAwaitingAppend) { links in
            Button("Append Links") { model.appendSharedDrafts(links) }
            Button("Later", role: .cancel) {}
        }
        .modifier(QueueAccessory(model: model))
        .tabViewStyle(.sidebarAdaptable)
        .tint(MobileTheme.accent)
        .overlay(alignment: .top) {
            StatusToastHost(message: model.status.message) {
                model.status.dismiss()
            }
        }
    }
}

private struct QueueAccessory: ViewModifier {
    let model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.1, *), UIDevice.current.userInterfaceIdiom == .phone, sizeClass == .compact {
            content.tabViewBottomAccessory(isEnabled: model.queue.isBusy && model.selectedTab != .queue) {
                if let item = model.queue.activeItems.first ?? model.queue.queuedItems.first {
                    Button {
                        model.selectedTab = .queue
                    } label: {
                        Label {
                            let percent = item.phase.isIndeterminate ? nil : item.progress.percentLabel
                            Text([item.phase.displayName, percent, item.displayTitle].compactMap { $0 }.joined(separator: " · "))
                                .lineLimit(1)
                        } icon: { Image(systemName: "arrow.down.circle") }
                    }
                    .accessibilityHint("Opens the download queue")
                }
            }
        } else {
            content
        }
    }
}

/// The Download screen, or an explanation in its place when the engine couldn't start.
///
/// Only this tab depends on the engine being up: the queue, the history (with every file already
/// downloaded) and Settings, where an update can be undone, all keep working.
private struct DownloadTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if case .failed(let message) = model.engine.state {
            EngineProblemView(message: message)
        } else {
            DownloadView()
        }
    }
}

#Preview {
    RootView()
        .environment(AppModel())
}
