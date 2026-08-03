import Foundation
import os

/// Logging façade. Nothing in this app calls `print` — add a category here
/// instead, so output is filterable in Console and stripped from release builds
/// by the unified logging system rather than by hand.
enum Log {
    private static let subsystem = "com.stevemurr.screenwriter"

    static let document = Logger(subsystem: subsystem, category: "document")
    static let editor = Logger(subsystem: subsystem, category: "editor")
    static let parse = Logger(subsystem: subsystem, category: "parse")
    static let render = Logger(subsystem: subsystem, category: "render")
    static let migrate = Logger(subsystem: subsystem, category: "migrate")
}
