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
        .tabViewStyle(.sidebarAdaptable)
        .overlay(alignment: .top) {
            StatusToastHost(message: model.composer.statusMessage) {
                model.composer.dismissStatus()
            }
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
