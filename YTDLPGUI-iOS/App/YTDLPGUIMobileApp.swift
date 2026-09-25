import AppIntents
import SwiftUI

@main
struct YTDLPGUIMobileApp: App {

    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        // The Shortcuts action queues on this same model. It must be registered before the
        // app finishes launching, because a shortcut can be what launched it.
        AppDependencyManager.shared.add(dependency: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
                .onOpenURL { url in
                    model.handleOpenURL(url)
                }
                .task {
                    await model.performLaunchSetup()
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.handleScenePhaseChange(phase)
        }
    }
}
