import Foundation

/// Menu commands that a SwiftUI document view has to answer.
///
/// The menu bar is AppKit and lives outside any document window, so its actions
/// reach the frontmost document's model through `AppDelegate`. Where the command
/// needs view-local state instead — presenting a sheet, say — the delegate posts
/// one of these and the view responds.
extension Notification.Name {
    static let showTitlePageInspector = Notification.Name("screenwriter.showTitlePageInspector")
}
