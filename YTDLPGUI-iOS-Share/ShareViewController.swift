import SwiftUI
import UIKit

/// The Share extension's principal class. It hosts the SwiftUI sheet and ends the extension
/// request once the sheet is done.
///
/// The extension never starts a download itself: it has neither the engine nor the time (iOS
/// ends an extension soon after its sheet closes). It leaves the links in the App Group inbox,
/// and the app acts on them the next time it becomes active.
final class ShareViewController: UIViewController {

    private let model = ShareSheetModel(services: .live)

    override func viewDidLoad() {
        super.viewDidLoad()
        // Honoured by the form sheet the extension appears in on iPad; ignored on iPhone.
        preferredContentSize = CGSize(width: 540, height: 620)

        model.onFinish = { [weak self] outcome in
            self?.endRequest(outcome)
        }
        embed(UIHostingController(rootView: ShareSheetView(model: model)))

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { await model.load(from: items) }
    }

    private func embed(_ child: UIViewController) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        child.didMove(toParent: self)
    }

    private func endRequest(_ outcome: ShareSheetModel.Outcome) {
        switch outcome {
        case .completed:
            extensionContext?.completeRequest(returningItems: nil)
        case .cancelled:
            extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
    }
}

extension ShareSheetModel.Services {
    /// The real App Group inbox and the general pasteboard.
    static var live: Self {
        Self(
            isInboxAvailable: { InboxWriter.inboxDirectory != nil },
            writeEntry: { urls, kind throws(InboxWriter.Failure) in
                try InboxWriter.write(urls: urls, kind: kind)
            },
            copyText: { text in
                UIPasteboard.general.string = text
            },
            confirmationDuration: {
                // Long enough for VoiceOver to finish reading the confirmation before the sheet
                // goes; a glance is enough otherwise.
                UIAccessibility.isVoiceOverRunning ? .seconds(5) : .milliseconds(1500)
            }
        )
    }
}
