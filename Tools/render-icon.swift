// Renders the app icon: a shutter button with the signal of a remote.
// Run from the repository root:  swift Tools/render-icon.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RGBA {
    let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha)
    }
    func cgColor(in space: CGColorSpace) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }
}

struct Variant {
    let fileName: String
    let background: (RGBA, RGBA)?
    let ring: RGBA
    let dot: RGBA
    let innerArc: RGBA
    let outerArc: RGBA
}

let variants = [
    Variant(fileName: "icon-light.png", background: (RGBA(hex: 0x4468FF), RGBA(hex: 0x1A2CB0)),
            ring: RGBA(1, 1, 1), dot: RGBA(1, 1, 1), innerArc: RGBA(1, 1, 1, 0.95), outerArc: RGBA(1, 1, 1, 0.6)),
    Variant(fileName: "icon-dark.png", background: (RGBA(hex: 0x1A2150), RGBA(hex: 0x070A1C)),
            ring: RGBA(hex: 0xE3E8FF), dot: RGBA(hex: 0xE3E8FF), innerArc: RGBA(hex: 0x7C92FF), outerArc: RGBA(hex: 0x7C92FF, alpha: 0.6)),
    Variant(fileName: "icon-tinted.png", background: nil,
            ring: RGBA(1, 1, 1), dot: RGBA(1, 1, 1), innerArc: RGBA(1, 1, 1, 0.95), outerArc: RGBA(1, 1, 1, 0.6)),
]

func render(_ variant: Variant, size: Int, to url: URL) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "render-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create a drawing context"])
    }
    let scale = CGFloat(size) / 1024
    context.scaleBy(x: scale, y: scale)
    context.setShouldAntialias(true)

    if let (top, bottom) = variant.background {
        let gradient = CGGradient(colorsSpace: space, colors: [top.cgColor(in: space), bottom.cgColor(in: space)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 1024, y: 0), options: [])
    }

    let centre = CGPoint(x: 512, y: 512)
    let fullCircle = CGFloat.pi * 2

    // Shutter ring and button.
    context.setLineWidth(46)
    context.setStrokeColor(variant.ring.cgColor(in: space))
    context.addArc(center: centre, radius: 236, startAngle: 0, endAngle: fullCircle, clockwise: false)
    context.strokePath()
    context.setFillColor(variant.dot.cgColor(in: space))
    context.addArc(center: centre, radius: 152, startAngle: 0, endAngle: fullCircle, clockwise: false)
    context.fillPath()

    // The remote's signal: two arcs either side, like sound leaving a speaker.
    context.setLineCap(.round)
    let spread: CGFloat = 0.42
    for (radius, width, colour) in [(330.0, 34.0, variant.innerArc), (412.0, 30.0, variant.outerArc)] {
        context.setLineWidth(CGFloat(width))
        context.setStrokeColor(colour.cgColor(in: space))
        for side in [CGFloat(0), CGFloat.pi] {
            context.addArc(center: centre, radius: CGFloat(radius), startAngle: side - spread, endAngle: side + spread, clockwise: false)
            context.strokePath()
        }
    }

    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "render-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not write \(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "render-icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not finalize \(url.path)"])
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconSet = root.appendingPathComponent("PairAndShoot/Assets.xcassets/AppIcon.appiconset")
for variant in variants {
    try render(variant, size: 1024, to: iconSet.appendingPathComponent(variant.fileName))
    print("wrote \(variant.fileName)")
}
try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
try render(variants[0], size: 512, to: root.appendingPathComponent("docs/icon.png"))
print("wrote docs/icon.png")
