import AppKit
import FountainKit
import PDFKit

/// PDF export and printing.
///
/// Both go through the same `Paginator` output the preview draws, so ⌘P, Export
/// PDF, and what is on screen are the same layout by construction rather than by
/// three implementations agreeing.
extension ScreenplayDocument {

    /// The fonts the renderer should use, resolved from the app bundle.
    private var fonts: PDFRenderer.FontSet {
        PDFRenderer.FontSet.named(
            ScreenplayFont.isCourierPrimeAvailable ? "CourierPrime" : "Courier New",
            size: model.printSettings.layout.fontSize
        )
    }

    private var documentInfo: PDFRenderer.DocumentInfo {
        PDFRenderer.DocumentInfo(
            title: model.script.titlePage?.title ?? displayName,
            author: model.script.titlePage?.author
        )
    }

    /// Renders the current document to PDF data.
    ///
    /// Re-paginates synchronously first: pagination is debounced, and exporting
    /// a stale layout would produce a PDF that does not match what the writer
    /// was just looking at.
    func renderPDF() -> Data? {
        model.reparseNow()
        guard let paginated = model.paginated else { return nil }
        return PDFRenderer.render(
            paginated,
            fonts: fonts,
            layout: model.printSettings.layout,
            info: documentInfo
        )
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let data = renderPDF() else {
            presentError(ScreenplayExportError.nothingToRender)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (displayName as NSString)
            .deletingPathExtension.appending(".pdf")
        panel.canCreateDirectories = true
        panel.message = "Export a PDF of this screenplay."

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                self.presentError(error)
            }
        }
        if let window = windowControllers.first?.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// ⌘P. Prints the rendered PDF rather than a re-drawn view, so the printed
    /// pages are the exported pages.
    override func printOperation(
        withSettings printSettings: [NSPrintInfo.AttributeKey: Any]
    ) throws -> NSPrintOperation {
        guard let data = renderPDF(), let pdf = PDFDocument(data: data) else {
            throw ScreenplayExportError.nothingToRender
        }
        let info = NSPrintInfo(dictionary: printSettings)
        info.paperSize = NSSize(
            width: model.printSettings.layout.pageWidth,
            height: model.printSettings.layout.pageHeight
        )
        // The page geometry is already baked into the PDF; letting the print
        // system scale or rotate it would undo the fidelity work.
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.leftMargin = 0
        info.rightMargin = 0
        info.topMargin = 0
        info.bottomMargin = 0

        guard let operation = pdf.printOperation(
            for: info,
            scalingMode: .pageScaleNone,
            autoRotate: false
        ) else {
            throw ScreenplayExportError.nothingToRender
        }
        return operation
    }
}

enum ScreenplayExportError: LocalizedError {
    case nothingToRender

    var errorDescription: String? { "There are no pages to export yet." }
    var recoverySuggestion: String? { "Write something first, then try again." }
}
