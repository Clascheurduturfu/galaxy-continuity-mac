import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func render(_ pixels: Int, to name: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    let background = NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 216, yRadius: 216)
    NSGradient(starting: NSColor(calibratedRed: 0.23, green: 0.59, blue: 1, alpha: 1), ending: NSColor(calibratedRed: 0.12, green: 0.31, blue: 0.86, alpha: 1))!.draw(in: background, angle: -50)
    NSColor.white.setStroke()
    let monitor = NSBezierPath(roundedRect: NSRect(x: 190, y: 332, width: 430, height: 332), xRadius: 45, yRadius: 45)
    monitor.lineWidth = 35; monitor.stroke()
    let stand = NSBezierPath(); stand.move(to: NSPoint(x: 402, y: 332)); stand.line(to: NSPoint(x: 402, y: 259)); stand.move(to: NSPoint(x: 313, y: 252)); stand.line(to: NSPoint(x: 492, y: 252)); stand.lineWidth = 34; stand.lineCapStyle = .round; stand.stroke()
    NSColor(calibratedRed: 0.17, green: 0.42, blue: 0.91, alpha: 1).setFill()
    let phone = NSBezierPath(roundedRect: NSRect(x: 580, y: 225, width: 244, height: 452), xRadius: 48, yRadius: 48)
    phone.fill(); NSColor.white.setStroke(); phone.lineWidth = 34; phone.stroke()
    let bottom = NSBezierPath(); bottom.move(to: NSPoint(x: 667, y: 269)); bottom.line(to: NSPoint(x: 735, y: 269)); bottom.lineWidth = 20; bottom.lineCapStyle = .round; bottom.stroke()
    let link = NSBezierPath(); link.move(to: NSPoint(x: 390, y: 493)); link.curve(to: NSPoint(x: 703, y: 477), controlPoint1: NSPoint(x: 485, y: 595), controlPoint2: NSPoint(x: 602, y: 359)); link.lineWidth = 32; link.lineCapStyle = .round; link.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
}
for size in [16, 32, 128, 256, 512] {
    try render(size, to: "icon_\(size)x\(size).png")
    try render(size * 2, to: "icon_\(size)x\(size)@2x.png")
}
