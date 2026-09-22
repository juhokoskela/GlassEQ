#!/usr/bin/env swift

import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resourcesURL =
    root
    .appendingPathComponent("Sources", isDirectory: true)
    .appendingPathComponent("GlassEQApp", isDirectory: true)
    .appendingPathComponent("Resources", isDirectory: true)
let iconsetURL =
    root
    .appendingPathComponent(".build", isDirectory: true)
    .appendingPathComponent("icon-generation", isDirectory: true)
    .appendingPathComponent("GlassEQ.iconset", isDirectory: true)
let icnsURL = resourcesURL.appendingPathComponent("GlassEQ.icns")

try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

func fill(_ path: NSBezierPath, _ fill: NSColor) {
    fill.setFill()
    path.fill()
}

func stroke(_ path: NSBezierPath, _ stroke: NSColor, lineWidth: CGFloat) {
    stroke.setStroke()
    path.lineWidth = lineWidth
    path.stroke()
}

func drawGradient(_ gradient: NSGradient, in path: NSBezierPath, angle: CGFloat) {
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    gradient.draw(in: path.bounds, angle: angle)
    NSGraphicsContext.restoreGraphicsState()
}

func drawShadowedFill(_ path: NSBezierPath, fillColor: NSColor, offset: NSSize, blur: CGFloat, shadowColor: NSColor) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = offset
    shadow.shadowBlurRadius = blur
    shadow.shadowColor = shadowColor
    shadow.set()
    fill(path, fillColor)
    NSGraphicsContext.restoreGraphicsState()
}

func drawIcon(size: Int) -> NSImage {
    let canvas = CGFloat(size)
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high
    let rect = NSRect(x: 0, y: 0, width: canvas, height: canvas)
    color(0, 0, 0, 0).setFill()
    rect.fill()

    let iconRect = rect.insetBy(dx: canvas * 0.035, dy: canvas * 0.035)
    let icon = NSBezierPath(
        roundedRect: iconRect,
        xRadius: canvas * 0.215,
        yRadius: canvas * 0.215
    )

    drawShadowedFill(
        icon,
        fillColor: color(58, 61, 66),
        offset: NSSize(width: 0, height: -canvas * 0.030),
        blur: canvas * 0.050,
        shadowColor: color(0, 0, 0, 0.30)
    )

    drawGradient(
        NSGradient(
            colorsAndLocations: (color(220, 223, 226), 0.00),
            (color(151, 156, 163), 0.52),
            (color(88, 94, 103), 1.00)
        )!,
        in: icon,
        angle: 90
    )

    stroke(icon, color(255, 255, 255, 0.44), lineWidth: max(1, canvas * 0.008))

    let panelRect = rect.insetBy(dx: canvas * 0.130, dy: canvas * 0.125)
    let panel = NSBezierPath(
        roundedRect: panelRect,
        xRadius: canvas * 0.135,
        yRadius: canvas * 0.135
    )

    drawShadowedFill(
        panel,
        fillColor: color(255, 255, 255, 0.18),
        offset: NSSize(width: 0, height: -canvas * 0.012),
        blur: canvas * 0.026,
        shadowColor: color(0, 0, 0, 0.20)
    )

    drawGradient(
        NSGradient(
            colorsAndLocations: (color(255, 255, 255, 0.30), 0.00),
            (color(255, 255, 255, 0.24), 1.00)
        )!,
        in: panel,
        angle: 90
    )
    stroke(panel, color(255, 255, 255, 0.70), lineWidth: max(1, canvas * 0.010))

    let inner = panelRect.insetBy(dx: canvas * 0.125, dy: canvas * 0.135)
    let sliderCount = 5
    let trackWidth = max(2, canvas * 0.030)
    let knobRadius = canvas * 0.052
    let levels: [CGFloat] = [0.34, 0.62, 0.46, 0.72, 0.54]

    for index in 0..<sliderCount {
        let fraction = CGFloat(index) / CGFloat(sliderCount - 1)
        let x = inner.minX + inner.width * fraction
        let trackRect = NSRect(
            x: x - trackWidth / 2,
            y: inner.minY,
            width: trackWidth,
            height: inner.height
        )
        let track = NSBezierPath(roundedRect: trackRect, xRadius: trackWidth / 2, yRadius: trackWidth / 2)
        fill(track, color(255, 255, 255, 0.25))

        let knobY = inner.minY + inner.height * levels[index]
        let activeRect = NSRect(
            x: x - trackWidth / 2,
            y: inner.minY,
            width: trackWidth,
            height: max(trackWidth, knobY - inner.minY)
        )
        let active = NSBezierPath(roundedRect: activeRect, xRadius: trackWidth / 2, yRadius: trackWidth / 2)
        drawGradient(
            NSGradient(colors: [color(214, 219, 225, 0.78), color(255, 255, 255, 0.64)])!,
            in: active,
            angle: 90
        )

        let knobRect = NSRect(
            x: x - knobRadius,
            y: knobY - knobRadius,
            width: knobRadius * 2,
            height: knobRadius * 2
        )
        let knob = NSBezierPath(ovalIn: knobRect)
        drawShadowedFill(
            knob,
            fillColor: color(255, 255, 255, 0.70),
            offset: NSSize(width: 0, height: -canvas * 0.006),
            blur: canvas * 0.014,
            shadowColor: color(0, 0, 0, 0.22)
        )
        drawGradient(
            NSGradient(colors: [
                color(255, 255, 255, 0.95),
                color(224, 228, 232, 0.82),
                color(255, 255, 255, 0.56),
            ])!,
            in: knob,
            angle: -45
        )
        stroke(knob, color(255, 255, 255, 0.82), lineWidth: max(1, canvas * 0.006))
    }

    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let data = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(
            domain: "GlassEQIconGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }

    try data.write(to: url, options: .atomic)
}

for entry in sizes {
    try writePNG(drawIcon(size: entry.pixels), to: iconsetURL.appendingPathComponent(entry.name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    throw NSError(
        domain: "GlassEQIconGenerator", code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}

print(icnsURL.path)
