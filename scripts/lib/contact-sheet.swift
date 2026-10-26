import AppKit

// Stitches PNGs into one labelled contact sheet, one row per image, on a mid-grey background
// so both black shapes and transparent edges show.
// Usage: contact-sheet <out.png> <title> <label>=<png> ...
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 3 else {
  FileHandle.standardError.write(Data("usage: contact-sheet <out.png> <title> <label>=<png> ...\n".utf8))
  exit(2)
}
let rows: [(label: String, image: NSBitmapImageRep?)] = arguments.dropFirst(2).map { pair in
  let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
  let image =
    parts.count == 2 ? NSImage(contentsOfFile: parts[1])?.representations.first as? NSBitmapImageRep : nil
  return (parts[0], image)
}
let margin = 24.0
let labelHeight = 22.0
let titleHeight = 36.0
let missingHeight = 24.0
let width = max(600, rows.map { Double($0.image?.pixelsWide ?? 0) }.max() ?? 0) + 2 * margin
let height =
  titleHeight + margin
  + rows.reduce(0) { $0 + labelHeight + Double($1.image?.pixelsHigh ?? Int(missingHeight)) + margin }
guard
  let sheet = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
    bitsPerPixel: 0)
else { exit(1) }
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: sheet)
NSColor(white: 0.5, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()
func text(_ string: String, size: Double, at y: Double) {
  let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: NSColor.white,
  ]
  NSAttributedString(string: string, attributes: attributes).draw(
    at: NSPoint(x: margin, y: height - y - size * 1.3))
}
text(arguments[1], size: 20, at: margin / 2)
var top = titleHeight + margin
for row in rows {
  text(row.label, size: 14, at: top)
  top += labelHeight
  if let image = row.image {
    let rect = NSRect(
      x: margin, y: height - top - Double(image.pixelsHigh), width: Double(image.pixelsWide),
      height: Double(image.pixelsHigh))
    image.draw(in: rect)
    top += Double(image.pixelsHigh) + margin
  } else {
    text("no capture", size: 12, at: top)
    top += missingHeight + margin
  }
}
NSGraphicsContext.current = nil
guard let png = sheet.representation(using: .png, properties: [:]) else { exit(1) }
try png.write(to: URL(fileURLWithPath: arguments[0]))
