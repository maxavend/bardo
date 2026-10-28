import AppKit

// Draws Bardo's character on the light plate the macOS icon uses, at the sizes Windows
// asks for, and packs them into one .ico (PNG entries) plus a PNG for the title bar.
// Usage: swift make-icon.swift <character.png> <output directory>
let character = NSImage(contentsOfFile: CommandLine.arguments[1])!
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let plate = NSColor(srgbRed: 0.97647, green: 0.96471, blue: 0.99216, alpha: 1)

func render(_ size: Int) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    // The same rounded plate as the macOS icon.
    let shape = NSBezierPath(roundedRect: rect, xRadius: CGFloat(size) * 0.18, yRadius: CGFloat(size) * 0.18)
    plate.setFill()
    shape.fill()
    shape.addClip()
    character.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

let sizes = [16, 20, 24, 32, 40, 48, 64, 256]
let images = sizes.map(render)
var ico = Data()
func append16(_ value: Int) { ico.append(contentsOf: [UInt8(value & 0xff), UInt8(value >> 8 & 0xff)]) }
func append32(_ value: Int) { append16(value & 0xffff); append16(value >> 16 & 0xffff) }
append16(0); append16(1); append16(sizes.count)
var offset = 6 + 16 * sizes.count
for (size, image) in zip(sizes, images) {
    ico.append(UInt8(size >= 256 ? 0 : size)); ico.append(UInt8(size >= 256 ? 0 : size))
    ico.append(0); ico.append(0)
    append16(1); append16(32)
    append32(image.count); append32(offset)
    offset += image.count
}
images.forEach { ico.append($0) }
try! ico.write(to: output.appendingPathComponent("AppIcon.ico"))
try! render(256).write(to: output.appendingPathComponent("AppIcon.png"))
