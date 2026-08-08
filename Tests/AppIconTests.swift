import AppKit
import XCTest

@testable import Screenwriter

/// The app icon is a single explicit path in `project.yml`'s resources phase —
/// the enclosing group cannot be used, because `Resources/AppIcon/` also holds
/// the generator script. If that one entry is ever dropped, or the
/// `CFBundleIconFile` key drifts from the file's name, nothing fails: the build
/// succeeds, no warning is emitted, and the app just shows the generic
/// application icon in the Dock and in Finder.
///
/// The artwork itself comes from `Resources/AppIcon/make-icon.swift`.
final class AppIconTests: XCTestCase {

    /// `Bundle(for:)` on an app class rather than `Bundle.main`: the unit-test
    /// bundle is injected into the app, and this resolves the app bundle either
    /// way rather than depending on which one is "main".
    private var app: Bundle {
        Bundle(for: ScreenplayDocument.self)
    }

    func testInfoPlistDeclaresAnIconFile() {
        let declared = app.infoDictionary?["CFBundleIconFile"] as? String
        XCTAssertEqual(declared, "Screenwriter")
    }

    /// Reads the name out of the plist rather than hard-coding it, so renaming
    /// the file without updating the key — or the reverse — fails here.
    func testTheDeclaredIconIsActuallyInTheBundle() throws {
        let declared = try XCTUnwrap(app.infoDictionary?["CFBundleIconFile"] as? String)
        let url = app.url(
            forResource: (declared as NSString).deletingPathExtension,
            withExtension: "icns"
        )
        XCTAssertNotNil(url, "CFBundleIconFile names \(declared) but no such .icns is bundled")
    }

    /// A present-but-unreadable `.icns` looks identical to a correct one until
    /// the Dock draws it, so decode it and check the sizes the Dock will ask
    /// for. 1024 is the one Finder's largest icon view uses.
    func testTheIconDecodesAtEverySizeTheSystemAsksFor() throws {
        let url = try XCTUnwrap(app.url(forResource: "Screenwriter", withExtension: "icns"))
        let image = try XCTUnwrap(NSImage(contentsOf: url), "the .icns did not decode")

        let widths = Set(image.representations.map { Int($0.pixelsWide) })
        for expected in [16, 32, 64, 128, 256, 512, 1024] {
            XCTAssertTrue(widths.contains(expected), "no \(expected)px representation")
        }
    }

    /// The small sizes are drawn from a separate, chunkier mark set, because a
    /// 16pt mark is *half a pixel* at 32×32: it renders at half contrast and
    /// neighbouring lines blur into one another.
    ///
    /// So this reads the sheet's centre column and counts distinct bands of ink.
    /// The compact set puts four there — slugline, action, dialogue, slugline —
    /// each with a clear row of paper either side. Measured against the detailed
    /// artwork at this size, the same column gives *three* merged bands, so this
    /// fails if the compact variant is ever dropped. A colour-only check does
    /// not: enough indigo survives the merge to pass one.
    func testTheThirtyTwoPointVariantResolvesIntoSeparateLines() throws {
        let url = try XCTUnwrap(app.url(forResource: "Screenwriter", withExtension: "icns"))
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        let rep = try XCTUnwrap(
            image.representations.compactMap { $0 as? NSBitmapImageRep }.first { $0.pixelsWide == 32 }
        )

        let column: [(luminance: CGFloat, blueOverRed: CGFloat)] = (0..<32).map { y in
            guard let colour = rep.colorAt(x: 16, y: y)?.usingColorSpace(.sRGB) else { return (0, 0) }
            let luminance = 0.3 * colour.redComponent
                + 0.59 * colour.greenComponent
                + 0.11 * colour.blueComponent
            return (luminance, colour.blueComponent - colour.redComponent)
        }

        // Locate the sheet by its paper rather than hard-coding rows, so nudging
        // the page geometry does not silently move this test off the artwork.
        let paper: (CGFloat) -> Bool = { $0 > 0.94 }
        let ink: (CGFloat) -> Bool = { $0 < 0.90 }
        let top = try XCTUnwrap(column.firstIndex { paper($0.luminance) })
        let bottom = try XCTUnwrap(column.lastIndex { paper($0.luminance) })

        var bands: [[Int]] = []
        for y in top...bottom {
            if ink(column[y].luminance) {
                if let last = bands.last, last.last == y - 1 {
                    bands[bands.count - 1].append(y)
                } else {
                    bands.append([y])
                }
            }
        }

        XCTAssertEqual(bands.count, 4, "expected four separated lines, got \(bands.count)")
        guard bands.count == 4 else { return }

        // And the structure, not just the count: the outer two are sluglines and
        // must read indigo, the inner two are body text and must stay neutral.
        let bluest = bands.map { band in band.map { column[$0].blueOverRed }.max()! }
        XCTAssertGreaterThan(bluest[0], 0.15, "the first slugline lost its colour")
        XCTAssertGreaterThan(bluest[3], 0.15, "the second slugline lost its colour")
        XCTAssertLessThan(bluest[1], 0.15, "an action line is tinted")
        XCTAssertLessThan(bluest[2], 0.15, "a dialogue line is tinted")
    }
}
