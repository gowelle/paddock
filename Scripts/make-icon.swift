// Renders Resources/AppIcon.svg into Resources/AppIcon.icns.
// Run from the repository root: swift Scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let svg = root.appendingPathComponent("Resources/AppIcon.svg")
let icns = root.appendingPathComponent("Resources/AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathComponent("AppIcon.iconset")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

guard let image = NSImage(contentsOf: svg) else { fail("can't read \(svg.path)") }
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func write(pixels: Int, name: String) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        fail("can't make a \(pixels)px bitmap")
    }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fail("can't encode \(name)") }
    do { try png.write(to: iconset.appendingPathComponent(name)) } catch { fail("can't write \(name): \(error)") }
}

for points in [16, 32, 128, 256, 512] {
    write(pixels: points, name: "icon_\(points)x\(points).png")
    write(pixels: points * 2, name: "icon_\(points)x\(points)@2x.png")
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", icns.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset.deletingLastPathComponent())
guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }
print(icns.path)
