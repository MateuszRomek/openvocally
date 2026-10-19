// Renders the OpenVocally.dmg window background: a soft neutral field, a thin arrow from the app
// to Applications and one line of hint text. Writes a 1x and a 2x PNG and combines them with
// tiffutil into one HiDPI TIFF, so Finder draws it sharp on every display.
//
// Usage: xcrun swift scripts/release/dmg-background.swift [output.tiff]
// The default output is scripts/release/dmg-background.tiff, which is committed. Rerun this after
// a change here, or to dmg-settings.py's icon positions, and commit the new TIFF.
//
// The slot positions below must match icon_locations in dmg-settings.py.

import AppKit

/// The drawing in points, top-left origin, the same coordinates Finder uses for icon positions.
enum Layout {
    /// Finder shows 640 by 400 points of content. The extra 40 points below are the same plain
    /// field, so a Finder with a shorter title bar never shows an empty strip under the image.
    static let size = CGSize(width: 640, height: 440)
    static let appCenter = CGPoint(x: 160, y: 168)
    static let applicationsCenter = CGPoint(x: 480, y: 168)
    static let iconSize: CGFloat = 128
    /// The arrow keeps this much air from each icon's edge.
    static let arrowInset: CGFloat = 34
    static let arrowHead: CGFloat = 7
    static let arrowWidth: CGFloat = 1.5
    static let hintBaseline: CGFloat = 320
    static let hint = "Drag OpenVocally to Applications"
}

/// Neutral greys only, to match the monochrome app chrome. Finder picks the icon label color from
/// the background's brightness, not from the system appearance: over this light field it draws
/// black labels in Dark Mode too, so the labels stay readable in both. A light field also keeps the
/// black app icon distinct, where a dark one would swallow its edge.
enum Palette {
    static let top = NSColor(white: 0.975, alpha: 1)
    static let bottom = NSColor(white: 0.925, alpha: 1)
    static let arrow = NSColor(white: 0, alpha: 0.28)
    static let hint = NSColor(white: 0, alpha: 0.42)
}

func draw(in context: CGContext) {
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [Palette.top.cgColor, Palette.bottom.cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 400), options: [.drawsAfterEndLocation])

    let y = Layout.appCenter.y
    let startX = Layout.appCenter.x + Layout.iconSize / 2 + Layout.arrowInset
    let endX = Layout.applicationsCenter.x - Layout.iconSize / 2 - Layout.arrowInset
    context.setStrokeColor(Palette.arrow.cgColor)
    context.setLineWidth(Layout.arrowWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: startX, y: y))
    context.addLine(to: CGPoint(x: endX, y: y))
    context.move(to: CGPoint(x: endX - Layout.arrowHead, y: y - Layout.arrowHead))
    context.addLine(to: CGPoint(x: endX, y: y))
    context.addLine(to: CGPoint(x: endX - Layout.arrowHead, y: y + Layout.arrowHead))
    context.strokePath()

    let hint = NSAttributedString(
        string: Layout.hint,
        attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: Palette.hint,
        ])
    let line = CTLineCreateWithAttributedString(hint)
    let width = CTLineGetTypographicBounds(line, nil, nil, nil)
    context.saveGState()
    // CoreText draws with a bottom-left origin, so flip the text matrix inside the flipped context.
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.textPosition = CGPoint(x: (Layout.size.width - width) / 2, y: Layout.hintBaseline)
    CTLineDraw(line, context)
    context.restoreGState()
}

func render(scale: Int, to url: URL) throws {
    let pixelsWide = Int(Layout.size.width) * scale
    let pixelsHigh = Int(Layout.size.height) * scale
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0),
        let graphics = NSGraphicsContext(bitmapImageRep: rep)
    else { throw RenderError.context }
    rep.size = Layout.size  // 72 dpi at 1x and 144 dpi at 2x, which tiffutil needs to pair them.
    let context = graphics.cgContext
    context.translateBy(x: 0, y: CGFloat(pixelsHigh))
    context.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    NSGraphicsContext.current = graphics
    draw(in: context)
    graphics.flushGraphics()
    guard let png = rep.representation(using: .png, properties: [:]) else { throw RenderError.encode }
    try png.write(to: url)
}

enum RenderError: Error {
    case context, encode, tiffutil(Int32)
}

let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let output =
    CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : scriptDirectory.appendingPathComponent("dmg-background.tiff")
let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let oneX = work.appendingPathComponent("background.png")
let twoX = work.appendingPathComponent("background@2x.png")
try render(scale: 1, to: oneX)
try render(scale: 2, to: twoX)

let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck", oneX.path, twoX.path, "-out", output.path]
try tiffutil.run()
tiffutil.waitUntilExit()
guard tiffutil.terminationStatus == 0 else { throw RenderError.tiffutil(tiffutil.terminationStatus) }
