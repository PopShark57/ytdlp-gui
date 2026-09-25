import UIKit

/// "iPhone" or "iPad", for sentences about where things are in the Files app, which names the
/// device: Files › On My iPhone › YTDLP GUI.
enum DeviceName {
    @MainActor
    static var current: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }
}
