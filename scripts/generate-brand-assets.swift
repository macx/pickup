#!/usr/bin/env swift
// Builds the brand assets in docs/brand/ from App/Resources/Pickup.icon and Apple's ictool renders.
// Run via scripts/generate-brand-assets.sh (it renders the PNGs with ictool first and passes their folder).
// Usage: swift scripts/generate-brand-assets.swift <ictool render dir> <docs/brand> <preview dir>
//
// Outputs (see docs/brand/README.md): PNGs with the real Liquid Glass render (8-bit sRGB, transparent outside
// the tile), marketing PNGs with a soft drop shadow, README hero images, flat and simulated-glass SVGs, glyph-only
// SVGs, the appearance overview for docs/ICON.md, and a review sheet in the preview folder.
import AppKit

let args = CommandLine.arguments
let renders = args[1], brand = args[2], preview = args[3]
let fm = FileManager.default
try fm.createDirectory(atPath: brand, withIntermediateDirectories: true)
try fm.createDirectory(atPath: preview, withIntermediateDirectories: true)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

// MARK: Geometry

/// Apple's macOS 26/27 icon tile ("squircle", continuous corners), as Figma's corner-smoothing construction
/// (radius R and smoothing ξ: straight edge, cubic transition, circular arc, cubic transition). R = 0.2595 and
/// ξ = 0.64 of the tile size were least-squares fitted to the alpha edge of ictool's 4096 px render: mean
/// deviation 0.86 px, max 1.7 px at 4096 px (≤ 0.05 % of the size). Returns SVG path data for a w x w tile at (x, y).
func squircle(x x0: Double, y y0: Double, size w: Double, radius: Double = 0.2595, smoothing s: Double = 0.64) -> String {
    let R = radius * w
    let p = (1 + s) * R
    let arcMeasure = 90 * (1 - s)
    let arcSection = sin(arcMeasure / 2 * .pi / 180) * R * sqrt(2)
    let p3p4 = R * tan((90 - arcMeasure) / 4 * .pi / 180)
    let beta = 45 * s * .pi / 180
    let c = p3p4 * cos(beta), d = c * tan(beta)
    let b = (p - arcSection - c - d) / 3, a = 2 * b
    func f(_ v: Double) -> String { String(format: "%.2f", v) }
    // One corner in local coordinates: from (w - p, 0) on the top edge round to (w, p) on the right edge; the
    // others by rotating the same numbers.
    var out = "M\(f(x0 + p)) \(f(y0))"
    let corners: [(Double, Double, (Double, Double) -> (Double, Double))] = [
        (x0 + w, y0, { u, v in (-u, v) }),          // top right: u along -x from the corner, v along +y
        (x0 + w, y0 + w, { u, v in (-v, -u) }),     // bottom right
        (x0, y0 + w, { u, v in (u, -v) }),          // bottom left
        (x0, y0, { u, v in (v, u) }),               // top left
    ]
    for (cx, cy, m) in corners {
        func pt(_ u: Double, _ v: Double) -> String { let (dx, dy) = m(u, v); return "\(f(cx + dx)) \(f(cy + dy))" }
        // u = distance from the corner along the first edge, v = along the second edge
        out += "L\(pt(p, 0))"
        out += "C\(pt(p - a, 0)) \(pt(p - a - b, 0)) \(pt(p - a - b - c, d))"
        out += "A\(f(R)) \(f(R)) 0 0 1 \(pt(d, p - a - b - c))"
        out += "C\(pt(0, p - a - b)) \(pt(0, p - a)) \(pt(0, p))"
    }
    return out + "Z"
}

/// Path data of an icon layer (the SVGs written by generate-app-icon.swift, 1024 canvas).
func layerPath(_ file: String) -> String {
    let s = try! String(contentsOfFile: "App/Resources/Pickup.icon/Assets/\(file)", encoding: .utf8)
    let r = s.range(of: " d=\"")!, e = s[r.upperBound...].firstIndex(of: "\"")!
    return String(s[r.upperBound..<e])
}
let handset = layerPath("1-handset.svg"), arcs = layerPath("2-arcs.svg")

// MARK: Brand colours (docs/ICON.md)

struct Look { var name: String; var tileTop: String; var tileBottom: String; var handset: String; var arcs: String; var rimTop: Double; var rimBottom: Double }
// Light tile: Icon Composer's automatic gradient of #FFFDFA as measured in the render; dark: the specified gradient.
let looks = [
    Look(name: "light", tileTop: "#FFFEFC", tileBottom: "#F2F0EC", handset: "#1C1814", arcs: "#F2571A", rimTop: 1.0, rimBottom: 0.55),
    Look(name: "dark", tileTop: "#2B2622", tileBottom: "#120F0D", handset: "#FFF8F1", arcs: "#FF6A2B", rimTop: 0.55, rimBottom: 0.12),
]

func write(_ s: String, _ name: String) throws { try s.write(toFile: "\(brand)/\(name)", atomically: true, encoding: .utf8) }

// MARK: SVGs

for l in looks {
    // Flat: the tile fills the view box (no grid margin), plain colours, no effects.
    try write("""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
    <title>Pickup for Mac</title>
    <defs><linearGradient id="t" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="\(l.tileTop)"/><stop offset="1" stop-color="\(l.tileBottom)"/></linearGradient></defs>
    <path fill="url(#t)" d="\(squircle(x: 0, y: 0, size: 1024))"/>
    <path fill="\(l.handset)" d="\(handset)"/>
    <path fill="\(l.arcs)" d="\(arcs)"/>
    </svg>\n
    """, "pickup-icon-\(l.name)-flat.svg")
    // Glass simulation on Apple's 1024 grid (tile 824 at 100, room for the shadow): soft drop shadow, inner rim
    // that is brightest at the top, a faint top sheen, and on the glyph a top-edge highlight plus a soft shadow.
    let k = 824.0 / 1024
    let g = "translate(100 100) scale(\(k))"
    try write("""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
    <title>Pickup for Mac</title>
    <defs>
    <linearGradient id="t" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="\(l.tileTop)"/><stop offset="1" stop-color="\(l.tileBottom)"/></linearGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="\(l.rimTop)"/><stop offset=".5" stop-color="#fff" stop-opacity="\(l.rimBottom * 0.6)"/><stop offset="1" stop-color="#fff" stop-opacity="\(l.rimBottom)"/></linearGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".18"/><stop offset=".45" stop-color="#fff" stop-opacity="0"/></linearGradient>
    <clipPath id="c"><path d="\(squircle(x: 0, y: 0, size: 1024))"/></clipPath>
    <filter id="drop" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="14" stdDeviation="22" flood-color="#000" flood-opacity=".32"/></filter>
    <filter id="glass" x="-10%" y="-10%" width="120%" height="130%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="5" result="b"/>
    <feOffset in="b" dy="7" result="o"/>
    <feComposite in="SourceAlpha" in2="o" operator="out" result="edge"/>
    <feFlood flood-color="#fff" flood-opacity=".6"/><feComposite in2="edge" operator="in" result="hl"/>
    <feDropShadow in="SourceAlpha" dx="0" dy="5" stdDeviation="6" flood-color="#000" flood-opacity=".14" result="sh"/>
    <feMerge><feMergeNode in="sh"/><feMergeNode in="SourceGraphic"/><feMergeNode in="hl"/></feMerge>
    </filter>
    </defs>
    <g transform="\(g)">
    <path fill="url(#t)" filter="url(#drop)" d="\(squircle(x: 0, y: 0, size: 1024))"/>
    <g clip-path="url(#c)">
    <rect width="1024" height="1024" fill="url(#sheen)"/>
    <path fill="none" stroke="url(#rim)" stroke-width="10" d="\(squircle(x: 0, y: 0, size: 1024))"/>
    </g>
    <g filter="url(#glass)"><path fill="\(l.handset)" d="\(handset)"/><path fill="\(l.arcs)" d="\(arcs)"/></g>
    </g>
    </svg>\n
    """, "pickup-icon-\(l.name)-glass.svg")
}
for (name, colour) in [("black", "#000"), ("white", "#fff")] {
    // Glyph only, monochrome, 16 pt padding around the 640 pt glyph box.
    try write("""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="176 176 672 672" width="672" height="672">
    <title>Pickup for Mac</title>
    <path fill="\(colour)" d="\(handset)\(arcs)"/>
    </svg>\n
    """, "pickup-glyph-\(name).svg")
}

// MARK: PNGs

func load(_ path: String) -> CGImage {
    guard let i = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("missing \(path)") }
    return i
}
func context(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func savePNG(_ img: CGImage, _ path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}
/// ictool writes 16-bit PNGs (13 MB at 4096 px); re-encoded as 8-bit sRGB they are a fraction of that and
/// visually identical.
func eightBit(_ img: CGImage) -> CGImage {
    let c = context(img.width, img.height)
    c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return c.makeImage()!
}
/// Marketing style: the tile on Apple's grid (824/1024 of the canvas, centred) with a soft drop shadow.
func withShadow(_ tile: CGImage, canvas n: Int) -> CGImage {
    let c = context(n, n), N = CGFloat(n), t = N * 824 / 1024
    c.interpolationQuality = .high
    c.setShadow(offset: CGSize(width: 0, height: -N * 0.014), blur: N * 0.03, color: CGColor(gray: 0, alpha: 0.38))
    c.draw(tile, in: CGRect(x: (N - t) / 2, y: (N - t) / 2 + N * 0.006, width: t, height: t))
    return c.makeImage()!
}

var created: [String] = []
for (look, rendition) in [("light", "Default"), ("dark", "Dark")] {
    for n in [4096, 2048, 1024] {
        let img = eightBit(load("\(renders)/\(rendition)-\(n).png"))
        savePNG(img, "\(brand)/pickup-icon-\(look)-\(n).png"); created.append("pickup-icon-\(look)-\(n).png")
        savePNG(withShadow(img, canvas: n), "\(brand)/pickup-icon-\(look)-shadow-\(n).png"); created.append("pickup-icon-\(look)-shadow-\(n).png")
    }
    // README hero: shown at 256 pt, stored at 3x (768 px) so it is sharp on every display.
    savePNG(withShadow(eightBit(load("\(renders)/\(rendition)-1024.png")), canvas: 768), "\(brand)/readme-icon-\(look).png")
}
for (name, rendition) in [("clear-light", "ClearLight"), ("clear-dark", "ClearDark"), ("tinted-light", "TintedLight"), ("tinted-dark", "TintedDark")] {
    savePNG(eightBit(load("\(renders)/\(rendition)-2048.png")), "\(brand)/pickup-icon-\(name)-2048.png")
}

// MARK: Appearance overview (docs/ICON.md) and review sheet

func drawText(_ s: String, _ x: CGFloat, _ y: CGFloat, _ c: NSColor, _ size: CGFloat = 14, _ w: NSFont.Weight = .medium) {
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: w), .foregroundColor: c]).draw(at: NSPoint(x: x, y: y))
}
let appearances: [(String, String, NSColor)] = [
    ("Default", "Default (light)", NSColor(white: 0.93, alpha: 1)), ("Dark", "Dark", NSColor(white: 0.12, alpha: 1)),
    ("ClearLight", "Clear light", NSColor(srgbRed: 0.78, green: 0.85, blue: 0.93, alpha: 1)),
    ("ClearDark", "Clear dark", NSColor(srgbRed: 0.10, green: 0.11, blue: 0.20, alpha: 1)),
    ("TintedLight", "Tinted light (purple)", NSColor(white: 0.93, alpha: 1)), ("TintedDark", "Tinted dark (purple)", NSColor(white: 0.12, alpha: 1)),
    ("TintedLightGreen", "Tinted light (green)", NSColor(white: 0.93, alpha: 1)), ("TintedDarkGreen", "Tinted dark (green)", NSColor(white: 0.12, alpha: 1)),
]
func sheet(cell: CGFloat, sizes: [Int], enlarge: Bool, path: String) {
    let cols = appearances.count
    let W = CGFloat(cols) * cell, H = cell + (enlarge ? 330 : 40)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    for (i, (file, title, bg)) in appearances.enumerated() {
        let x = CGFloat(i) * cell
        bg.setFill(); NSRect(x: x, y: 0, width: cell, height: H).fill()
        let ink: NSColor = (bg.usingColorSpace(.sRGB)?.brightnessComponent ?? 1) > 0.5 ? .black : .white
        drawText(title, x + 10, H - 26, ink, enlarge ? 14 : 12)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(contentsOfFile: "\(renders)/\(file)-1024.png")?.draw(in: NSRect(x: x + cell * 0.1, y: H - 34 - cell * 0.8, width: cell * 0.8, height: cell * 0.8))
        guard enlarge else { continue }
        var sx = x + 10
        let row = H - 44 - cell * 0.8 - 10
        for s in sizes {
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(contentsOfFile: "\(renders)/\(file)-\(s).png")?.draw(in: NSRect(x: sx, y: row - CGFloat(s), width: CGFloat(s), height: CGFloat(s)))
            sx += CGFloat(s) + 8
        }
        NSImage(contentsOfFile: "\(renders)/\(file)-32.png")?.draw(in: NSRect(x: x + 10, y: 10, width: 128, height: 128))
        NSImage(contentsOfFile: "\(renders)/\(file)-16.png")?.draw(in: NSRect(x: x + 150, y: 10, width: 128, height: 128))
    }
    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
// WCAG contrast per appearance, measured in the 1024 px renders at fixed points: the handset's back, the outer
// arc, and the empty tile in the lower left (median of a 15 px patch). Printed for docs/ICON.md.
func luminance(_ c: (Double, Double, Double)) -> Double {
    func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(c.0) + 0.7152 * lin(c.1) + 0.0722 * lin(c.2)
}
func ratio(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
let points = ["handset": (375.0, 649.0), "arcs": (720.8, 303.2), "tile": (252.8, 771.2)]
var table = "| Appearance | Handset / tile | Arcs / tile | Arcs / handset |\n|---|---|---|---|\n"
for (file, title, _) in appearances {
    let img = load("\(renders)/\(file)-1024.png")
    let c = context(1024, 1024); c.draw(img, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    let px = c.data!.assumingMemoryBound(to: UInt8.self), row = c.bytesPerRow
    var l: [String: Double] = [:]
    for (k, (x, y)) in points {
        var v: [Double] = []
        for dy in -7...7 { for dx in -7...7 {
            let i = (Int(y) + dy) * row + (Int(x) + dx) * 4, a = max(Double(px[i + 3]) / 255, 1e-6)
            v.append(luminance((Double(px[i]) / 255 / a, Double(px[i + 1]) / 255 / a, Double(px[i + 2]) / 255 / a))) } }
        l[k] = v.sorted()[v.count / 2]
    }
    func f(_ v: Double) -> String { String(format: "%.1f:1", v) }
    table += "| \(title) | \(f(ratio(l["handset"]!, l["tile"]!))) | \(f(ratio(l["arcs"]!, l["tile"]!))) | \(f(ratio(l["arcs"]!, l["handset"]!))) |\n"
}
print(table)
try table.write(toFile: "\(preview)/appearance-contrast.md", atomically: true, encoding: .utf8)
sheet(cell: 160, sizes: [], enlarge: false, path: "\(brand)/appearances.png")
sheet(cell: 300, sizes: [128, 64, 32, 16], enlarge: true, path: "\(preview)/appearances-sheet.png")

// Review sheet of the brand assets: PNGs on a checkerboard, SVGs rendered by CoreSVG (NSImage).
do {
    let items = ["pickup-icon-light-1024.png", "pickup-icon-dark-1024.png", "pickup-icon-light-shadow-1024.png", "pickup-icon-dark-shadow-1024.png",
                 "readme-icon-light.png", "readme-icon-dark.png", "pickup-icon-clear-light-2048.png", "pickup-icon-clear-dark-2048.png",
                 "pickup-icon-tinted-light-2048.png", "pickup-icon-tinted-dark-2048.png", "pickup-icon-light-flat.svg", "pickup-icon-dark-flat.svg",
                 "pickup-icon-light-glass.svg", "pickup-icon-dark-glass.svg", "pickup-glyph-black.svg", "pickup-glyph-white.svg"]
    let cell: CGFloat = 300, cols = 4
    let W = CGFloat(cols) * cell, H = CGFloat((items.count + cols - 1) / cols) * cell
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    for (i, name) in items.enumerated() {
        let x = CGFloat(i % cols) * cell, y = H - CGFloat(i / cols + 1) * cell
        for cy in stride(from: 0, to: Int(cell), by: 20) { for cx in stride(from: 0, to: Int(cell), by: 20) {
            ((cx / 20 + cy / 20) % 2 == 0 ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.7, alpha: 1)).setFill()
            NSRect(x: x + CGFloat(cx), y: y + CGFloat(cy), width: 20, height: 20).fill() } }
        if name.contains("glyph-white") { NSColor(white: 0.2, alpha: 1).setFill(); NSRect(x: x, y: y, width: cell, height: cell).fill() }
        NSImage(contentsOfFile: "\(brand)/\(name)")?.draw(in: NSRect(x: x + 30, y: y + 40, width: cell - 60, height: cell - 60))
        drawText(name, x + 8, y + 8, .black, 11)
    }
    NSGraphicsContext.current = nil
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(preview)/brand-sheet.png"))
}
print("Brand assets in \(brand)")
