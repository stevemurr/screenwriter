#!/usr/bin/env swift
//
//  make-icon.swift — generates Resources/AppIcon/Screenwriter.icns
//
//  Run from the repository root:
//
//      swift Resources/AppIcon/make-icon.swift
//
//  The icon is drawn as vectors and re-rendered at every size rather than
//  downsampled from 1024, so the thin marks stay crisp at 32pt instead of
//  turning to grey mush. Nothing here needs a font: every mark is a capsule,
//  which is also why the artwork survives being 16 points tall.
//
//  The palette is the app's own — `Style.paper` for the sheet and
//  `Style.Element.sceneHeading`'s indigo for the sluglines — so the icon and
//  the editor read as the same product.
//

import AppKit
import CoreGraphics

// MARK: - Geometry

/// The macOS Big Sur-and-later icon grid: a 1024 canvas with the shape itself
/// occupying 824 points, leaving the margin the system expects for its shadow.
let canvas: CGFloat = 1024
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)

/// The plate silhouette: straight sides with a corner radius of 0.225 of the
/// side, which is the Big Sur grid's 185.4 at 824.
///
/// A superellipse is the usual shorthand for Apple's continuous-corner shape,
/// but it bows the *sides* as well as the corners, and at icon scale that reads
/// as a pillow next to the real icons in the Dock. Circular corners on straight
/// sides are very slightly tighter than Apple's true corner curve and far
/// closer than the pillow.
func plateShape(in rect: CGRect) -> CGPath {
    let radius = rect.width * 0.225
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func capsule(_ rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
}

// MARK: - Palette

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let groundTop = rgb(0.28, 0.29, 0.53)
let groundBottom = rgb(0.13, 0.14, 0.25)
let paper = rgb(0.99, 0.985, 0.97)          // Style.paper
let slugline = rgb(0.29, 0.28, 0.72)        // the scene-heading indigo, weighted for cream
let cue = rgb(0.10, 0.10, 0.12, 0.88)       // Style.paperInk
/// Weighted to still be visible at 128pt. A lighter grey looked better at 1024
/// and disappeared entirely by the time the icon was in a Finder list.
let bodyText = rgb(0.32, 0.32, 0.38, 0.72)
/// The small sizes spend their contrast budget on antialiasing, so they get no
/// transparency at all.
let bodyTextOpaque = rgb(0.30, 0.30, 0.36)

// MARK: - The page

/// A sheet at US Letter's 8.5 × 11 proportion, centred on the plate.
let pageWidth: CGFloat = 520
let pageHeight = pageWidth * 11 / 8.5       // 673
let page = CGRect(
    x: (canvas - pageWidth) / 2,
    y: plate.midY - pageHeight / 2,
    width: pageWidth,
    height: pageHeight
)

/// A mark on the page, positioned in page-local coordinates measured *down*
/// from the top edge — the way one reads a screenplay.
struct Mark {
    let indent: CGFloat     // from the page's left margin
    let top: CGFloat        // from the page's top edge
    let width: CGFloat
    let height: CGFloat
    let color: CGColor
}

let margin: CGFloat = 74

/// Screenplays are mostly whitespace, and honouring that is what keeps the
/// artwork legible: two coloured sluglines anchor it, and everything else
/// recedes.
let detailedMarks: [Mark] = [
    Mark(indent: 0, top: 98, width: 296, height: 25, color: slugline),
    Mark(indent: 0, top: 164, width: 372, height: 16, color: bodyText),
    Mark(indent: 0, top: 199, width: 314, height: 16, color: bodyText),

    Mark(indent: 142, top: 285, width: 118, height: 22, color: cue),
    Mark(indent: 104, top: 327, width: 208, height: 16, color: bodyText),
    Mark(indent: 104, top: 362, width: 208, height: 16, color: bodyText),
    Mark(indent: 104, top: 397, width: 138, height: 16, color: bodyText),

    Mark(indent: 0, top: 484, width: 230, height: 25, color: slugline),
    Mark(indent: 0, top: 550, width: 372, height: 16, color: bodyText),
    Mark(indent: 0, top: 585, width: 276, height: 16, color: bodyText),
]

/// The same page, hand-tuned for the sizes where the detailed set collapses.
///
/// A 16pt-tall mark is *half a pixel* at 32×32, so it renders at half contrast
/// and neighbouring lines blur into one grey mass — measured, not guessed: the
/// action lines came out 45 luminance below the paper and the two sluglines
/// merged with them. So the small sizes get four chunky, opaque marks with gaps
/// wide enough to survive a pixel of antialiasing, which is the same reason
/// Apple ships hand-drawn small variants rather than downsampling.
let compactMarks: [Mark] = [
    Mark(indent: 0, top: 110, width: 306, height: 54, color: slugline),
    Mark(indent: 0, top: 245, width: 372, height: 54, color: bodyTextOpaque),
    Mark(indent: 104, top: 380, width: 204, height: 54, color: bodyTextOpaque),
    Mark(indent: 0, top: 515, width: 246, height: 54, color: slugline),
]

/// Below this the detailed artwork stops resolving. 128 is the smallest size
/// where a 16pt mark is still two pixels tall.
func marks(forPixelSize size: Int) -> [Mark] {
    size >= 128 ? detailedMarks : compactMarks
}

// MARK: - Render

func draw(into context: CGContext, pixelSize size: Int) {
    context.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)

    // Ground.
    context.saveGState()
    context.addPath(plateShape(in: plate))
    context.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(colorsSpace: space, colors: [groundTop, groundBottom] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.midX, y: plate.maxY),
        end: CGPoint(x: plate.midX, y: plate.minY),
        options: []
    )
    context.restoreGState()

    // The sheet, with a soft cast shadow so it sits above the ground.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 34, color: rgb(0, 0, 0, 0.35))
    context.addPath(CGPath(roundedRect: page, cornerWidth: 8, cornerHeight: 8, transform: nil))
    context.setFillColor(paper)
    context.fillPath()
    context.restoreGState()

    // Marks.
    context.saveGState()
    context.addPath(CGPath(roundedRect: page, cornerWidth: 8, cornerHeight: 8, transform: nil))
    context.clip()
    for mark in marks(forPixelSize: size) {
        let rect = CGRect(
            x: page.minX + margin + mark.indent,
            y: page.maxY - mark.top - mark.height,
            width: mark.width,
            height: mark.height
        )
        context.addPath(capsule(rect))
        context.setFillColor(mark.color)
        context.fillPath()
    }
    context.restoreGState()

    // A single top highlight along the plate's edge, for a little dimension.
    context.saveGState()
    context.addPath(plateShape(in: plate))
    context.setStrokeColor(rgb(1, 1, 1, 0.14))
    context.setLineWidth(3)
    context.strokePath()
    context.restoreGState()
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: size * 4, bitsPerPixel: 32
    )!
    guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("could not make a context for \(size)")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    draw(into: graphics.cgContext, pixelSize: size)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(size)")
    }
    return data
}

// MARK: - Write the iconset

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputDirectory = root.appendingPathComponent("Resources/AppIcon")
let iconset = outputDirectory.appendingPathComponent("Screenwriter.iconset")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// `iconutil` requires every one of these names; a missing size makes it fail
/// rather than interpolate.
let entries: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

var cache: [Int: Data] = [:]
for entry in entries {
    let data = cache[entry.size] ?? render(size: entry.size)
    cache[entry.size] = data
    try data.write(to: iconset.appendingPathComponent("\(entry.name).png"))
}

// A standalone 1024 preview, handy for eyeballing the artwork without mounting
// the .icns.
try cache[1024]!.write(to: outputDirectory.appendingPathComponent("preview-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "-c", "icns",
    iconset.path,
    "-o", outputDirectory.appendingPathComponent("Screenwriter.icns").path,
]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}

// The iconset is an intermediate; the .icns is the artefact.
try FileManager.default.removeItem(at: iconset)
print("wrote Resources/AppIcon/Screenwriter.icns")
