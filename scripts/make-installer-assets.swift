// Draws the DMG window background and the installer icon into Resources/Installer/.
// Run after changing the design: swift scripts/make-installer-assets.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let out = root.appendingPathComponent("Resources/Installer")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func png(_ size: NSSize, scale: CGFloat, _ draw: (NSSize) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(size)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func text(_ s: String, font: NSFont, color c: NSColor, centerX: CGFloat? = nil, x: CGFloat = 0, top: CGFloat, height: CGFloat) {
    let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c])
    let w = str.size().width
    // Callers give y from the top, like the Finder window; AppKit draws from the bottom.
    str.draw(at: NSPoint(x: centerX.map { $0 - w / 2 } ?? x, y: height - top - str.size().height))
}

// MARK: DMG background, 600×400 points. Finder draws the installer icon centered at (300, 190).

let serif = NSFont(descriptor: NSFont.systemFont(ofSize: 26, weight: .semibold).fontDescriptor.withDesign(.serif)!, size: 26)!
// Signed builds use the plain background; unsigned ones add a footer explaining the one-time Gatekeeper step.
for (suffix, unsigned) in [("", false), ("-unsigned", true)] {
for scale in [1, 2] as [CGFloat] {
    let data = png(NSSize(width: 600, height: 400), scale: scale) { size in
        color(0xF3F2EC).setFill(); NSRect(origin: .zero, size: size).fill()
        text("Seperate", font: serif, color: color(0x23241F), x: 32, top: 26, height: size.height)
        text("在一个窗口里并排运行 Claude Code、Codex 和终端", font: .systemFont(ofSize: 12), color: color(0x6A6B63), x: 33, top: 62, height: size.height)
        text("双击图标开始安装", font: .systemFont(ofSize: 14, weight: .medium), color: color(0x5B5A4A), centerX: 300, top: 292, height: size.height)
        guard unsigned else { return }
        color(0xDCDBD2).setFill(); NSRect(x: 32, y: 56, width: 536, height: 1).fill()
        text("首次打开被拦截？前往 系统设置 → 隐私与安全性，点“仍要打开”。", font: .systemFont(ofSize: 11),
             color: color(0x8E8F86), centerX: 300, top: 356, height: size.height)
    }
    try data.write(to: out.appendingPathComponent("dmg-background\(suffix)\(scale == 1 ? "" : "@2x").png"))
}
}

// MARK: Installer icon: the app icon with a download badge.

let appIcon = NSImage(contentsOf: root.appendingPathComponent("design/app-icon-1024.png"))!
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("InstallerIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let data = png(NSSize(width: base, height: base), scale: CGFloat(scale)) { size in
            let s = size.width / 1024
            appIcon.draw(in: NSRect(origin: .zero, size: size))
            // Badge sits over the icon's bottom-right corner (icon body spans 100…924 of 1024).
            let badge = NSRect(x: 640 * s, y: 70 * s, width: 320 * s, height: 320 * s)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowBlurRadius = 24 * s; shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.set()
            color(0xF5F4EC).setFill(); NSBezierPath(ovalIn: badge).fill()
            NSGraphicsContext.restoreGraphicsState()
            color(0x22231E).setFill(); NSBezierPath(ovalIn: badge.insetBy(dx: 22 * s, dy: 22 * s)).fill()
            let arrow = NSBezierPath()
            let cx = badge.midX, cy = badge.midY
            arrow.move(to: NSPoint(x: cx, y: cy + 80 * s)); arrow.line(to: NSPoint(x: cx, y: cy - 70 * s))
            arrow.move(to: NSPoint(x: cx - 62 * s, y: cy - 8 * s)); arrow.line(to: NSPoint(x: cx, y: cy - 72 * s))
            arrow.line(to: NSPoint(x: cx + 62 * s, y: cy - 8 * s))
            arrow.lineWidth = 30 * s; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
            color(0xF5F4EC).setStroke(); arrow.stroke()
        }
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.appendingPathComponent("InstallerIcon.icns").path]
try p.run(); p.waitUntilExit()
try? FileManager.default.copyItem(at: iconset.appendingPathComponent("icon_512x512@2x.png"), to: FileManager.default.temporaryDirectory.appendingPathComponent("installer-icon-preview.png"))
print(out.path)
