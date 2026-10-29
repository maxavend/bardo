import AppKit

// Draws Bardo's head, without a plate as Windows 11 app icons are drawn, at the sizes
// Windows asks for, and packs them into one .ico (PNG entries) plus a PNG for the title bar.
// Usage: swift make-icon.swift <head with transparency.png> <output directory>
// The head is design/mascota/image-v2/bardo-mascota-original.png.
let character = NSImage(contentsOfFile: CommandLine.arguments[1])!
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
/// Windows icons keep a little room inside their square; small sizes need less of it.
func padding(_ size: Int) -> CGFloat { size <= 24 ? 0.02 : 0.06 }

func render(_ size: Int) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    let inset = CGFloat(size) * padding(size)
    let box = NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: inset, dy: inset)
    // Fitted whole, keeping its proportions.
    let scale = min(box.width / character.size.width, box.height / character.size.height)
    let drawn = NSSize(width: character.size.width * scale, height: character.size.height * scale)
    character.draw(in: NSRect(x: box.midX - drawn.width / 2, y: box.midY - drawn.height / 2, width: drawn.width, height: drawn.height))
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
