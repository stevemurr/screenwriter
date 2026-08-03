import Foundation

/// Menu commands that a SwiftUI document view has to answer.
///
/// The menu bar is AppKit and lives outside any document window, so its actions
/// reach the frontmost document's model through `AppDelegate`. Where the command
/// needs view-local state instead — presenting a sheet, say — the delegate posts
/// one of these and the view responds.
/// Posted with the `ScreenplayModel` it is aimed at as the object. A view must
/// check that before acting: several documents can be open, and a broadcast
/// would open a sheet on every one of them.
extension Notification.Name {
    static let showTitlePageInspector = Notification.Name("screenwriter.showTitlePageInspector")
}
