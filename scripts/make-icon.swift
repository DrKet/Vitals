// Renders the Vitals app icon to a 1024x1024 PNG.
//
// Drawn from the app's own palette so the icon matches the UI rather than
// sitting beside it: the same dark surface the pages use, and a chart line
// like the ones the app actually draws.
//
// Run: swift scripts/make-icon.swift <output.png>
import AppKit

let side: CGFloat = 1024
// macOS icons supply their own rounded shape and are not masked by the system,
// so the artwork insets itself. ~10% margin matches Apple's own grid.
let margin: CGFloat = side * 0.10
let plate = NSRect(x: margin, y: margin, width: side - margin * 2, height: side - margin * 2)

// Drawn straight into a pixel-exact bitmap context rather than via
// NSImage(size:).lockFocus(): lockFocus renders at the *screen's* backing
// scale factor, so on any Mac with a Retina main display the resulting
// tiffRepresentation comes out at 2x the requested size (2048x2048 here,
// not 1024x1024). That silently breaks the packer's final step, which
// copies this file in verbatim as the already-doubled 512@2x slot —
// iconutil then rejects that entry for being the wrong pixel size and
// drops it, yielding a 9-entry .icns instead of 10. Rendering into an
// explicitly-sized NSBitmapImageRep sidesteps the screen scale factor
// entirely, so the output is exactly `side` x `side` pixels regardless of
// the machine running this script.
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(side),
    pixelsHigh: Int(side),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write("failed to create bitmap rep\n".data(using: .utf8)!)
    exit(1)
}
rep.size = NSSize(width: side, height: side)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Transparent outside the plate.
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: side, height: side).fill()

// Squircle-ish plate. 22.37% of the plate's width is Apple's corner ratio.
let corner = plate.width * 0.2237
let platePath = NSBezierPath(roundedRect: plate, xRadius: corner, yRadius: corner)
platePath.addClip()

// Vitals.Palette's surface, deepened toward the bottom.
let gradient = NSGradient(
    starting: NSColor(srgbRed: 0.16, green: 0.17, blue: 0.21, alpha: 1),
    ending:   NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1)
)!
gradient.draw(in: plate, angle: -90)

// A chart line across the plate, in Vitals.Palette.cpu.
let points: [CGPoint] = [
    CGPoint(x: 0.10, y: 0.38), CGPoint(x: 0.22, y: 0.46), CGPoint(x: 0.32, y: 0.34),
    CGPoint(x: 0.43, y: 0.72), CGPoint(x: 0.54, y: 0.30), CGPoint(x: 0.65, y: 0.52),
    CGPoint(x: 0.78, y: 0.44), CGPoint(x: 0.90, y: 0.60),
].map { CGPoint(x: plate.minX + plate.width * $0.x, y: plate.minY + plate.height * $0.y) }

// Filled area beneath the line, echoing the app's stacked bands.
let area = NSBezierPath()
area.move(to: CGPoint(x: points[0].x, y: plate.minY))
points.forEach { area.line(to: $0) }
area.line(to: CGPoint(x: points[points.count - 1].x, y: plate.minY))
area.close()
NSColor(srgbRed: 0.49, green: 0.78, blue: 1.00, alpha: 0.22).setFill()
area.fill()

let line = NSBezierPath()
line.move(to: points[0])
points.dropFirst().forEach { line.line(to: $0) }
line.lineWidth = side * 0.035
line.lineCapStyle = .round
line.lineJoinStyle = .round
NSColor(srgbRed: 0.49, green: 0.78, blue: 1.00, alpha: 1).setStroke()
line.stroke()

NSGraphicsContext.restoreGraphicsState()

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <output.png>\n".data(using: .utf8)!)
    exit(2)
}
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
