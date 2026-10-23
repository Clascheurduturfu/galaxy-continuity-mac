import AppKit

// Apply after --render-screenshots: bitmap stamping stays visible even when an offscreen SwiftUI overlay has not drawn yet.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let label = "Demo · fictional account and device state" as NSString
let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)!
for case let file as URL in files where file.pathExtension == "png" {
    guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: file)), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
    let scale = CGFloat(bitmap.pixelsWide) / 1040
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11 * scale, weight: .semibold), .foregroundColor: NSColor.white]
    let size = label.size(withAttributes: attributes), pad = 9 * scale
    let rect = NSRect(x: CGFloat(bitmap.pixelsWide) - size.width - pad * 3, y: pad, width: size.width + pad * 2, height: size.height + pad * 2)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    NSColor.black.withAlphaComponent(0.9).setFill(); NSBezierPath(roundedRect: rect, xRadius: 5 * scale, yRadius: 5 * scale).fill()
    label.draw(at: NSPoint(x: rect.minX + pad, y: rect.minY + pad), withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: file, options: .atomic)
}
