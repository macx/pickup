// Composes the README marketing images in docs/images/ from the raw window captures that
// scripts/capture-screenshots.sh writes (App/.build/screenshots/raw, 2x Retina, transparent corners).
// Everything around the windows is synthetic: a soft gradient "wallpaper" in the brand's tones, a stylised
// menu bar strip with the Pickup template glyph (App/Resources/MenuBar/MenuBarConnected.pdf), drop shadows.
// The windows are drawn 1:1 (never scaled), so the text stays as crisp as the capture.
//
// Usage: swift scripts/generate-screenshots.swift <raw dir> <out dir> <menu bar glyph pdf>
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("usage: generate-screenshots.swift <raw dir> <out dir> <glyph pdf>\n".utf8))
    exit(2)
}
let rawDir = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let glyphURL = URL(fileURLWithPath: args[3])
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

enum Look { case light, dark }

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func load(_ name: String) -> CGImage? {
    let url = rawDir.appendingPathComponent(name + ".png")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func require(_ name: String) -> CGImage {
    guard let image = load(name) else {
        FileHandle.standardError.write(Data("generate-screenshots: missing raw capture \(name).png\n".utf8))
        exit(1)
    }
    return image
}

/// Mean luminance of the image's central area (0 = black, 1 = white).
func luminance(_ image: CGImage) -> CGFloat {
    let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let crop = image.cropping(to: CGRect(x: image.width / 4, y: image.height / 4,
                                         width: image.width / 2, height: image.height / 2)) ?? image
    ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return (0.2126 * CGFloat(p[0]) + 0.7152 * CGFloat(p[1]) + 0.0722 * CGFloat(p[2])) / 255
}

/// The popover follows the menu bar's appearance, not the app's: on a Mac in Dark Mode a "light" capture
/// is still dark. Only accept a light popover capture that really is light.
func popover(_ name: String, look: Look) -> CGImage? {
    guard let image = load(name) else { return nil }
    let isLight = luminance(image) > 0.5
    return (look == .light) == isLight ? image : nil
}

// MARK: Canvas (top-left origin helpers on a bottom-left CGContext)

final class Canvas {
    let ctx: CGContext
    let width: Int
    let height: Int
    let look: Look

    init(width: Int, height: Int, look: Look) {
        self.width = width
        self.height = height
        self.look = look
        ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
    }

    /// Rect in top-left coordinates → CG rect.
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: CGFloat(height) - y - h, width: w, height: h)
    }

    /// Soft gradient wallpaper. Rendered at 1/8 size and scaled up: the result is just as smooth, but without
    /// Quartz's gradient dithering noise, so the PNG stays small.
    func wallpaper(in area: CGRect? = nil, look: Look? = nil) {
        let look = look ?? self.look
        let area = area ?? CGRect(x: 0, y: 0, width: width, height: height)
        let factor: CGFloat = 8
        let w = Int((area.width / factor).rounded(.up)), h = Int((area.height / factor).rounded(.up))
        let small = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        let base: [CGColor] = look == .light ? [rgb(0xE9EEFF), rgb(0xFFEDE3)] : [rgb(0x0F1433), rgb(0x1C0E22)]
        let linear = CGGradient(colorsSpace: sRGB, colors: base as CFArray, locations: [0, 1])!
        small.drawLinearGradient(linear, start: CGPoint(x: 0, y: full.maxY), end: CGPoint(x: full.maxX, y: 0),
                                 options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        let size = max(full.width, full.height)
        // Colourful glows, like a modern macOS wallpaper: brand orange low right, violet top left, sky blue
        // top right, rose low left (y = 0 is the bottom).
        let glows: [(CGFloat, CGFloat, CGFloat, CGColor)] = look == .light
            ? [(0.92, 0.05, 0.70, rgb(0xFF7A3D, 0.42)), (0.05, 0.95, 0.70, rgb(0x8B7CFF, 0.40)),
               (0.85, 1.00, 0.55, rgb(0x5BC8FF, 0.34)), (0.10, 0.05, 0.55, rgb(0xFF8FB1, 0.30))]
            : [(0.92, 0.05, 0.70, rgb(0xFF6A2B, 0.50)), (0.05, 0.95, 0.70, rgb(0x6A4CFF, 0.50)),
               (0.85, 1.00, 0.55, rgb(0x1FA3C9, 0.34)), (0.10, 0.05, 0.55, rgb(0xC23A8A, 0.36))]
        for (fx, fy, fr, color) in glows {
            let center = CGPoint(x: fx * full.width, y: fy * full.height)
            let radial = CGGradient(colorsSpace: sRGB, colors: [color, color.copy(alpha: 0)!] as CFArray,
                                    locations: [0, 1])!
            small.drawRadialGradient(radial, startCenter: center, startRadius: 0, endCenter: center,
                                     endRadius: fr * size, options: [])
        }
        ctx.saveGState()
        ctx.clip(to: area)
        ctx.interpolationQuality = .high
        ctx.draw(small.makeImage()!, in: CGRect(x: area.minX, y: area.minY, width: CGFloat(w) * factor,
                                                height: CGFloat(h) * factor))
        ctx.restoreGState()
    }

    /// Draws a captured window 1:1 at (x, y) (top-left coordinates) with a two-layer soft shadow.
    func window(_ image: CGImage, x: CGFloat, y: CGFloat, look: Look? = nil) {
        let r = rect(x, y, CGFloat(image.width), CGFloat(image.height))
        let (soft, tight): (CGFloat, CGFloat) = (look ?? self.look) == .light ? (0.16, 0.10) : (0.55, 0.35)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -28), blur: 70, color: rgb(0x1C1814, soft))
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 8, color: rgb(0x000000, tight))
        ctx.draw(image, in: r)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    func write(_ name: String) {
        let url = outDir.appendingPathComponent(name)
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        print("wrote \(url.path) (\(width)x\(height))")
    }
}

// MARK: Menu bar strip

func glyph(height: CGFloat, color: CGColor) -> CGImage {
    let pdf = CGPDFDocument(glyphURL as CFURL)!.page(at: 1)!
    let box = pdf.getBoxRect(.mediaBox)
    let scale = height / box.height
    let w = Int((box.width * scale).rounded(.up)), h = Int(height.rounded(.up))
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -box.minX, y: -box.minY)
    ctx.drawPDFPage(pdf)
    // Template image: keep the alpha, replace the colour.
    ctx.resetClip()
    ctx.concatenate(ctx.ctm.inverted())
    ctx.setBlendMode(.sourceIn)
    ctx.setFillColor(color)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

/// Stylised menu bar: translucent strip, a few abstract status items, the Pickup glyph (highlighted when
/// its popover is open) and a clock. No real system icons. Returns the glyph's centre x.
@discardableResult
func menuBar(_ c: Canvas, height: CGFloat, glyphX: CGFloat, highlighted: Bool) -> CGFloat {
    let ink = c.look == .light ? rgb(0x1C1814) : rgb(0xFFF8F1)
    c.ctx.setFillColor(c.look == .light ? rgb(0xFFFFFF, 0.42) : rgb(0x000000, 0.22))
    c.ctx.fill(c.rect(0, 0, CGFloat(c.width), height))
    c.ctx.setFillColor(c.look == .light ? rgb(0x000000, 0.06) : rgb(0xFFFFFF, 0.06))
    c.ctx.fill(c.rect(0, height - 1, CGFloat(c.width), 1))

    // Clock at the right edge.
    let font = CTFontCreateUIFontForLanguage(.system, height * 0.4, nil)!
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Tue 13 Oct  9:41", attributes: attributes))
    let textWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
    let textX = CGFloat(c.width) - 44 - CGFloat(textWidth)
    c.ctx.textPosition = CGPoint(x: textX, y: CGFloat(c.height) - height / 2 - height * 0.14)
    CTLineDraw(line, c.ctx)

    // Abstract neighbours: soft dots, so the glyph does not float alone.
    c.ctx.setFillColor(ink.copy(alpha: 0.22)!)
    var x = textX - 64
    for _ in 0..<3 where x > glyphX + 90 {
        let d = height * 0.28
        c.ctx.fillEllipse(in: c.rect(x - d / 2, (height - d) / 2, d, d))
        x -= 62
    }

    // Pickup glyph, with the selection pill while the popover is open.
    if highlighted {
        let pill = c.rect(glyphX - height * 0.62, height * 0.14, height * 1.24, height * 0.72)
        c.ctx.setFillColor(c.look == .light ? rgb(0x000000, 0.10) : rgb(0xFFFFFF, 0.18))
        c.ctx.addPath(CGPath(roundedRect: pill, cornerWidth: height * 0.36, cornerHeight: height * 0.36, transform: nil))
        c.ctx.fillPath()
    }
    let g = glyph(height: height * 0.5, color: ink)
    c.ctx.draw(g, in: c.rect(glyphX - CGFloat(g.width) / 2, (height - CGFloat(g.height)) / 2,
                             CGFloat(g.width), CGFloat(g.height)))
    return glyphX
}

// MARK: Layouts

/// Windows side by side, centred (or top-aligned, like popovers hanging from the menu bar), on a wallpaper `width` wide.
func feature(_ images: [CGImage], width: Int, look: Look, name: String, gap: CGFloat = 96, padY: CGFloat = 150,
             alignTop: Bool = false) {
    let contentW = images.reduce(0) { $0 + CGFloat($1.width) } + gap * CGFloat(images.count - 1)
    let contentH = CGFloat(images.map(\.height).max()!)
    let height = Int(contentH + 2 * padY)
    let c = Canvas(width: max(width, Int(contentW + 160)), height: height, look: look)
    c.wallpaper()
    var x = (CGFloat(c.width) - contentW) / 2
    for image in images {
        let dy = alignTop ? 0 : (contentH - CGFloat(image.height)) / 2
        c.window(image, x: x.rounded(), y: (padY + dy).rounded())
        x += CGFloat(image.width) + gap
    }
    c.write(name)
}

/// Hero: the top-right corner of a Mac, cropped to the content. Menu bar with the Pickup glyph, the popover with
/// the recent calls open below it, and the incoming-call banner where macOS shows it, with the call window of
/// a second caller below the banner.
func hero(look: Look, name: String) {
    let suffix = look == .light ? "light" : "dark"
    let banner = require("banner-\(suffix)-en-1")
    let pop = popover("popover-empty-\(suffix)-en-1", look: look) ?? require("popover-empty-\(suffix)-en-1")
    let call = load("waiting-\(suffix)-en-1")
    let bar: CGFloat = 56, margin: CGFloat = 120, gap: CGFloat = 110
    let columnW = max(CGFloat(banner.width), CGFloat(call?.width ?? 0))
    let width = Int(margin + CGFloat(pop.width) + gap + columnW + margin)
    let columnH = CGFloat(banner.height) + (call.map { 70 + CGFloat($0.height) } ?? 0)
    let height = Int(bar + 6 + max(CGFloat(pop.height), 24 + columnH) + 120)
    let c = Canvas(width: width, height: height, look: look)
    c.wallpaper()
    let popX = margin
    menuBar(c, height: bar, glyphX: popX + CGFloat(pop.width) / 2, highlighted: true)
    c.window(pop, x: popX, y: bar + 6)
    let columnX = popX + CGFloat(pop.width) + gap
    c.window(banner, x: (columnX + (columnW - CGFloat(banner.width)) / 2).rounded(), y: bar + 30)
    if let call {
        c.window(call, x: (columnX + (columnW - CGFloat(call.width)) / 2).rounded(), y: bar + 30 + CGFloat(banner.height) + 70)
    }
    c.write(name)
}

/// Light and dark side by side: banner above the call HUD in each half.
func lightAndDark(name: String) {
    let width = 2400, half = CGFloat(width) / 2
    let gap: CGFloat = 90, padY: CGFloat = 140
    let columns = [(Look.light, require("banner-light-en-1"), require("hud-light-en-1")),
                   (Look.dark, require("banner-dark-en-1"), require("hud-dark-en-1"))]
    let height = Int(padY * 2 + CGFloat(columns[0].1.height) + gap + CGFloat(columns[0].2.height))
    let c = Canvas(width: width, height: height, look: .light)
    for (index, (look, banner, hud)) in columns.enumerated() {
        c.wallpaper(in: CGRect(x: half * CGFloat(index), y: 0, width: half, height: CGFloat(height)), look: look)
    }
    for (index, (look, banner, hud)) in columns.enumerated() {
        let cx = half * CGFloat(index) + half / 2
        c.window(banner, x: (cx - CGFloat(banner.width) / 2).rounded(), y: padY, look: look)
        c.window(hud, x: (cx - CGFloat(hud.width) / 2).rounded(), y: padY + CGFloat(banner.height) + gap, look: look)
    }
    c.write(name)
}

try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
// The README uses the dark images: on macOS 26 a capture of the popover window alone renders its Liquid Glass
// without a backdrop, which is flat grey in light mode. Banner, call window and Settings exist in both.
hero(look: .dark, name: "hero-dark.png")
lightAndDark(name: "light-dark.png")
for look in [Look.light, .dark] {
    let s = look == .light ? "light" : "dark"
    feature([require("banner-\(s)-en-1")], width: 1600, look: look, name: "banner-\(s).png", padY: 190)
    feature([require("banner-\(s)-de-1")], width: 1600, look: look, name: "banner-de-\(s).png", padY: 190)
    feature([require("hud-\(s)-en-1"), require("hud-ended-\(s)-en-1")], width: 1600, look: look, name: "call-hud-\(s).png")
    feature([require("settings-\(s)-en-1")], width: 1600, look: look, name: "settings-\(s).png")
    if let waiting = load("waiting-\(s)-en-1") {
        feature([waiting] + [load("held-\(s)-en-1")].compactMap { $0 }, width: 1600, look: look,
                name: "call-waiting-\(s).png", padY: 170)
    }
    for lang in ["en", "de"] where look == .dark {
        let tag = lang == "en" ? "" : "-de"
        if let empty = popover("popover-empty-\(s)-\(lang)-1", look: look),
           let search = popover("popover-search-\(s)-\(lang)-1", look: look) {
            feature([empty, search], width: 1600, look: look, name: "popover-search\(tag)-\(s).png", padY: 130,
                    alignTop: true)
        } else {
            print("skipped popover-search\(tag)-\(s).png: no \(s) popover capture (the popover follows the menu bar's appearance; capture with the Mac in \(s) mode)")
        }
    }
}
