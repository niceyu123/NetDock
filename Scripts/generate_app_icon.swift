#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

let size = 1024
guard CommandLine.arguments.count == 3 else {
    fputs("Usage: generate_app_icon.swift IOS_OUTPUT.png MACOS_APPICONSET_DIRECTORY\n", stderr)
    exit(EXIT_FAILURE)
}
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let macIconSetURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      ) else {
    fputs("Unable to create the app icon drawing context.\n", stderr)
    exit(EXIT_FAILURE)
}

// Use top-left coordinates for the waveform artwork.
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red, green, blue, 1])!
}

// Fixed system-blue branding keeps exported icons independent of the Mac's
// current accent color. The sidebar uses this same generated artwork.
let background = color(0, 122.0 / 255.0, 1)
context.setFillColor(background)
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

context.setStrokeColor(color(1, 1, 1))
context.setLineWidth(60)
context.setLineCap(.round)
context.setLineJoin(.round)

// Original vector waveform, matching the in-app mark's visual language.
// Rounded turns and a generous margin keep the line legible at Dock sizes.
let waveform = CGMutablePath()
waveform.move(to: CGPoint(x: 126, y: 548))
waveform.addLine(to: CGPoint(x: 226, y: 548))
let turns: [CGPoint] = [
    CGPoint(x: 326, y: 448), CGPoint(x: 414, y: 700),
    CGPoint(x: 512, y: 310), CGPoint(x: 600, y: 720),
    CGPoint(x: 698, y: 448), CGPoint(x: 798, y: 548)
]
var previous = CGPoint(x: 226, y: 548)
for turn in turns {
    let handle = (turn.x - previous.x) * 0.45
    waveform.addCurve(to: turn,
                      control1: CGPoint(x: previous.x + handle, y: previous.y),
                      control2: CGPoint(x: turn.x - handle, y: turn.y))
    previous = turn
}
waveform.addLine(to: CGPoint(x: 898, y: 548))
context.addPath(waveform)
context.strokePath()

guard let image = context.makeImage() else {
    fputs("Unable to create the app icon image.\n", stderr)
    exit(EXIT_FAILURE)
}

func writePNG(_ image: CGImage, to url: URL, hasAlpha: Bool = false) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else { return false }
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyHasAlpha: hasAlpha] as CFDictionary)
    return CGImageDestinationFinalize(destination)
}

guard writePNG(image, to: outputURL) else {
    fputs("Unable to write the iOS app icon PNG.\n", stderr)
    exit(EXIT_FAILURE)
}

// A regular image asset lets both platforms reuse the exact app-icon waveform
// inside the app, rather than substituting a denser SF Symbol.
let brandURL = outputURL.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("BrandMark.imageset", isDirectory: true)
try FileManager.default.createDirectory(at: brandURL, withIntermediateDirectories: true)
guard writePNG(image, to: brandURL.appendingPathComponent("BrandMark.png")) else {
    fputs("Unable to write the in-app brand image.\n", stderr)
    exit(EXIT_FAILURE)
}
let brandContents: [String: Any] = [
    "images": [["filename": "BrandMark.png", "idiom": "universal"]],
    "info": ["author": "xcode", "version": 1]
]
try JSONSerialization.data(withJSONObject: brandContents, options: [.prettyPrinted, .sortedKeys])
    .write(to: brandURL.appendingPathComponent("Contents.json"), options: .atomic)

// Modern macOS owns the enclosure. Supply full-bleed artwork to Icon Composer
// instead of placing a second rounded tile inside the system's icon mask.
let composerURL = macIconSetURL.deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("NetDockIcon.icon", isDirectory: true)
let composerAssetsURL = composerURL.appendingPathComponent("Assets", isDirectory: true)
try FileManager.default.createDirectory(at: composerAssetsURL, withIntermediateDirectories: true)
guard writePNG(image, to: composerAssetsURL.appendingPathComponent("Network.png")) else {
    fputs("Unable to write the Icon Composer artwork.\n", stderr)
    exit(EXIT_FAILURE)
}
let composerDocument: [String: Any] = [
    "fill": ["solid": "srgb:0.00000,0.47843,1.00000,1.00000"],
    "groups": [[
        "name": "Network",
        "layers": [["name": "Network", "image-name": "Network.png", "glass": false]],
        "shadow": ["kind": "none", "opacity": 0],
        "translucency": ["enabled": false, "value": 0]
    ]],
    "supported-platforms": ["squares": "shared"]
]
try JSONSerialization.data(withJSONObject: composerDocument, options: [.prettyPrinted, .sortedKeys])
    .write(to: composerURL.appendingPathComponent("icon.json"), options: .atomic)

// Retain the legacy raster asset set for compatibility/export. The Mac target
// uses NetDockIcon.icon above, whose native enclosure is generated by Xcode.
guard let macContext = CGContext(
    data: nil,
    width: size,
    height: size,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fputs("Unable to create the macOS app icon drawing context.\n", stderr)
    exit(EXIT_FAILURE)
}
let macArtworkRect = CGRect(x: 100, y: 100, width: 824, height: 824)
macContext.addPath(CGPath(
    roundedRect: macArtworkRect,
    cornerWidth: 185,
    cornerHeight: 185,
    transform: nil
))
macContext.clip()
macContext.draw(image, in: macArtworkRect)
guard let macImage = macContext.makeImage() else {
    fputs("Unable to create the rounded macOS app icon.\n", stderr)
    exit(EXIT_FAILURE)
}

let macIconSizes: [(name: String, scale: Int, pixels: Int)] = [
    ("16x16", 1, 16), ("16x16", 2, 32),
    ("32x32", 1, 32), ("32x32", 2, 64),
    ("128x128", 1, 128), ("128x128", 2, 256),
    ("256x256", 1, 256), ("256x256", 2, 512),
    ("512x512", 1, 512), ("512x512", 2, 1024)
]
try FileManager.default.createDirectory(at: macIconSetURL, withIntermediateDirectories: true, attributes: nil)
for iconSize in macIconSizes {
    guard let resizedContext = CGContext(
        data: nil,
        width: iconSize.pixels,
        height: iconSize.pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fputs("Unable to resize the macOS app icon.\n", stderr)
        exit(EXIT_FAILURE)
    }
    resizedContext.draw(macImage, in: CGRect(x: 0, y: 0, width: iconSize.pixels, height: iconSize.pixels))
    guard let resizedImage = resizedContext.makeImage() else {
        fputs("Unable to encode a macOS app icon size.\n", stderr)
        exit(EXIT_FAILURE)
    }
    let suffix = iconSize.scale == 1 ? ".png" : "@2x.png"
    let filename = "icon_\(iconSize.name)\(suffix)"
    guard writePNG(resizedImage, to: macIconSetURL.appendingPathComponent(filename), hasAlpha: true) else {
        fputs("Unable to write macOS app icon \(filename).\n", stderr)
        exit(EXIT_FAILURE)
    }
}
