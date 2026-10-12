#!/usr/bin/env swift
// Generates the Pickup app icon (Icon Composer bundle) and the menu bar template images from the Lucide
// "phone-call" icon (ISC, see THIRD_PARTY_NOTICES.md). Rules and measurements: docs/ICON.md.
//
//   swift scripts/generate-app-icon.swift                       -> App/Resources/Pickup.icon, App/Resources/MenuBar
//   swift scripts/generate-app-icon.swift --handset outline --icon <dir.icon> --menubar <dir>   (comparison builds)
//
// Icon: two foreground layers on Lucide's 24-unit grid, strokes expanded to outlines (Icon Composer wants plain
// shapes): the handset (filled or Lucide outline) and the two call arcs. Background colours, Liquid Glass,
// specular highlights and shadows are system effects set in icon.json -- nothing is baked into the artwork, and
// there is no mask (the system applies the rounded-rect shape).
// Menu bar: the same mark as a black template PDF (vector), 18 x 18 pt, in two states: connected (filled
// handset + arcs) and disconnected (outlined handset only).
import AppKit

// MARK: Lucide phone-call (icons/phone-call.svg, 24 x 24, stroke 2, round caps and joins)

let lucideHandset = "M13.832 16.568a1 1 0 0 0 1.213-.303l.355-.465A2 2 0 0 1 17 15h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2A18 18 0 0 1 2 4a2 2 0 0 1 2-2h3a2 2 0 0 1 2 2v3a2 2 0 0 1-.8 1.6l-.468.351a1 1 0 0 0-.292 1.233 14 14 0 0 0 6.392 6.384"
/// The two arcs share the centre (13, 11) and their end lines with Lucide; radii are parameters (Lucide: 9 and 5).
func arcPath(radius r: CGFloat) -> String { "M13 \(11 - r)a\(r) \(r) 0 0 1 \(r) \(r)" }

struct Options {
    var filledHandset = true
    var handsetStroke: CGFloat = 2.25     // Lucide 2; a little heavier for 16-32 px
    var arcStroke: CGFloat = 2.5          // Lucide 2; both arcs must survive at 32 px
    var outerRadius: CGFloat = 9          // as Lucide
    var innerRadius: CGFloat = 4.75       // Lucide 5; widens the gap the heavier stroke ate (1.75 units)
    var extent: CGFloat = 640             // glyph box on the 1024 canvas: 62.5 %, Apple's Phone icon is 62-64 %
    var iconDir = "App/Resources/Pickup.icon"
    var menuDir: String? = "App/Resources/MenuBar"
    /// Optional JSON with colour sample points for scripts/icon-colour-study.swift.
    var samples: String? = nil
    /// Grey of the arcs in the mono appearance (clear and tinted), see docs/ICON.md.
    var monoArcs = "C2C2C2"
}

var o = Options()
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--handset": o.filledHandset = it.next() != "outline"
    case "--icon": o.iconDir = it.next()!
    case "--menubar": o.menuDir = it.next()
    case "--no-menubar": o.menuDir = nil
    case "--samples": o.samples = it.next()
    case "--mono-arcs": o.monoArcs = it.next()!
    default: fatalError("unknown argument \(a)")
    }
}
if !o.filledHandset { o.handsetStroke = 2.5 }   // outline: one stroke family with the arcs

// MARK: SVG path data <-> CGPath

func parseSVGPath(_ d: String) -> CGPath {
    var tokens: [String] = [], cur = ""
    func flush() { if !cur.isEmpty { tokens.append(cur); cur = "" } }
    for c in d {
        if c.isLetter && c != "e" { flush(); tokens.append(String(c)) }
        else if c == "," || c == " " { flush() }
        else if c == "-" && !cur.isEmpty && cur.last != "e" { flush(); cur = "-" }
        else if c == "." && cur.contains(".") { flush(); cur = "." }
        else { cur.append(c) }
    }
    flush()
    let path = CGMutablePath()
    var k = 0, cmd: Character = "M", p = CGPoint.zero, start = CGPoint.zero
    func num() -> CGFloat { defer { k += 1 }; return CGFloat(Double(tokens[k])!) }
    while k < tokens.count {
        if Double(tokens[k]) == nil {
            cmd = Character(tokens[k]); k += 1
            if cmd == "Z" || cmd == "z" { path.closeSubpath(); p = start; continue }
        }
        let o = cmd.isLowercase ? p : .zero
        switch cmd.uppercased() {
        case "M": p = CGPoint(x: o.x + num(), y: o.y + num()); path.move(to: p); start = p; cmd = cmd.isLowercase ? "l" : "L"
        case "L": p = CGPoint(x: o.x + num(), y: o.y + num()); path.addLine(to: p)
        case "H": p = CGPoint(x: (cmd.isLowercase ? p.x : 0) + num(), y: p.y); path.addLine(to: p)
        case "V": p = CGPoint(x: p.x, y: (cmd.isLowercase ? p.y : 0) + num()); path.addLine(to: p)
        case "A":
            let rx = num(), ry = num(); _ = num()
            let large = num() != 0, sweep = num() != 0
            let end = CGPoint(x: o.x + num(), y: o.y + num())
            addArc(path, from: p, to: end, r: (rx + ry) / 2, large: large, sweep: sweep); p = end
        default: fatalError("unsupported path command \(cmd)")
        }
    }
    return path
}

/// Circular SVG arc (Lucide only uses circles) as cubic Béziers of at most 90 degrees.
func addArc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, r r0: CGFloat, large: Bool, sweep: Bool) {
    let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
    let r = max(r0, hypot(dx, dy))
    var coef = sqrt(max(0, (r * r - dx * dx - dy * dy) / (dx * dx + dy * dy)))
    if large == sweep { coef = -coef }
    let c = CGPoint(x: coef * dy + (p0.x + p1.x) / 2, y: -coef * dx + (p0.y + p1.y) / 2)
    let a0 = atan2(p0.y - c.y, p0.x - c.x)
    var da = atan2(p1.y - c.y, p1.x - c.x) - a0
    if sweep && da < 0 { da += 2 * .pi } else if !sweep && da > 0 { da -= 2 * .pi }
    let n = Int(ceil(abs(da) / (.pi / 2) - 1e-9)), step = da / CGFloat(n), t = 4 / 3 * tan(step / 4)
    for i in 0..<n {
        let a = a0 + CGFloat(i) * step, b = a + step
        let pa = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        let pb = i == n - 1 ? p1 : CGPoint(x: c.x + r * cos(b), y: c.y + r * sin(b))
        path.addCurve(to: pb, control1: CGPoint(x: pa.x - t * r * sin(a), y: pa.y + t * r * cos(a)),
                      control2: CGPoint(x: pb.x + t * r * sin(b), y: pb.y - t * r * cos(b)))
    }
}

func svgData(_ path: CGPath) -> String {
    func f(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }
    var s = ""
    path.applyWithBlock { e in
        let p = e.pointee.points
        switch e.pointee.type {
        case .moveToPoint: s += "M\(f(p[0].x)) \(f(p[0].y))"
        case .addLineToPoint: s += "L\(f(p[0].x)) \(f(p[0].y))"
        case .addQuadCurveToPoint: s += "Q\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y))"
        case .addCurveToPoint: s += "C\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) \(f(p[2].x)) \(f(p[2].y))"
        case .closeSubpath: s += "Z"
        @unknown default: break
        }
    }
    return s
}

func stroked(_ d: String, _ w: CGFloat) -> CGPath {
    parseSVGPath(d).copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10).normalized()
}

// MARK: The mark (Lucide units)

let rawHandset = parseSVGPath(lucideHandset)
let handset = o.filledHandset ? rawHandset.union(stroked(lucideHandset, o.handsetStroke)).normalized()
                              : stroked(lucideHandset, o.handsetStroke)
let arcs = stroked(arcPath(radius: o.outerRadius), o.arcStroke).union(stroked(arcPath(radius: o.innerRadius), o.arcStroke))
let box = handset.union(arcs).boundingBoxOfPath

/// Scales the mark so its larger side is `extent` and centres its box in a square of `size` (y down).
func placement(extent: CGFloat, size: CGFloat) -> CGAffineTransform {
    let k = extent / max(box.width, box.height)
    return CGAffineTransform(translationX: -box.midX, y: -box.midY).concatenating(CGAffineTransform(scaleX: k, y: k))
        .concatenating(CGAffineTransform(translationX: size / 2, y: size / 2))
}

// MARK: Icon Composer bundle

func srgb(_ hex: String) -> String {
    let v = UInt32(hex, radix: 16)!
    return String(format: "srgb:%.5f,%.5f,%.5f,1.00000", Double(v >> 16 & 255) / 255, Double(v >> 8 & 255) / 255, Double(v & 255) / 255)
}
/// Default, dark and tinted fills. Tinted is derived from luminance, so it gets explicit greys: white handset,
/// mid-grey arcs (two distinct levels, same features as the other appearances).
func fills(_ light: String, _ dark: String, _ tinted: String) -> [[String: Any]] {
    [["value": ["solid": srgb(light)]], ["appearance": "dark", "value": ["solid": srgb(dark)]],
     ["appearance": "tinted", "value": ["solid": srgb(tinted)]]]
}
func group(_ image: String, _ fill: [[String: Any]]) -> [String: Any] {
    // System Liquid Glass: specular highlight on, neutral shadow, opaque (translucency let the tile bleed into
    // the glyph and cost contrast in earlier rounds).
    ["layers": [["image-name": image, "name": (image as NSString).deletingPathExtension, "glass": true, "fill-specializations": fill]],
     "lighting": "individual", "specular": true, "shadow": ["kind": "neutral", "opacity": 0.5],
     "translucency": ["enabled": false, "value": 0]]
}

let iconURL = URL(fileURLWithPath: o.iconDir, isDirectory: true)
let assets = iconURL.appendingPathComponent("Assets", isDirectory: true)
try? FileManager.default.removeItem(at: iconURL)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
let t = placement(extent: o.extent, size: 1024)
for (name, path) in [("1-handset.svg", handset), ("2-arcs.svg", arcs)] {
    var tt = t
    let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">" +
        "<path fill=\"#000\" d=\"\(svgData(path.copy(using: &tt)!))\"/></svg>\n"
    try svg.write(to: assets.appendingPathComponent(name), atomically: true, encoding: .utf8)
}
let json: [String: Any] = [
    // Background: near-white paper (light, system gradient) and warm ink (dark) as a gradient with a lifted top,
    // so the dark tile separates from dark desktops without any baked rim.
    "fill-specializations": [
        ["value": ["automatic-gradient": srgb("FFFDFA")]],
        ["appearance": "dark", "value": ["linear-gradient": [srgb("2B2622"), srgb("120F0D")],
                                         "orientation": ["start": ["x": 0.5, "y": 0], "stop": ["x": 0.5, "y": 1]]]],
    ],
    // Groups front to back: arcs (orange accent), handset (ink on light, warm white on dark).
    "groups": [
        group("2-arcs.svg", fills("F2571A", "FF6A2B", o.monoArcs)),
        group("1-handset.svg", fills("1C1814", "FFF8F1", "FFFFFF")),
    ],
    "supported-platforms": ["squares": ["macOS"]],
]
try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: iconURL.appendingPathComponent("icon.json"))
let g = box.applying(t)
print(String(format: "icon: %@ glyph box %.0f x %.0f at (%.0f, %.0f) = %.1f %% x %.1f %% of the canvas",
             o.iconDir, g.width, g.height, g.minX, g.minY, 100 * g.width / 1024, 100 * g.height / 1024))

if let file = o.samples {
    // On the handset's back (stroke centre line), on the outer arc, and in the empty lower-left corner.
    let pts = ["handset": CGPoint(x: 20 - 18 * sin(CGFloat.pi / 4), y: 4 + 18 * cos(CGFloat.pi / 4)),
               "accent": CGPoint(x: 13 + o.outerRadius * cos(CGFloat.pi / 4), y: 11 - o.outerRadius * sin(CGFloat.pi / 4)),
               "tile": CGPoint(x: 3, y: 21)].mapValues { p -> [CGFloat] in let q = p.applying(t); return [q.x, q.y] }
    let name = iconURL.deletingPathExtension().lastPathComponent
    let entry: [String: Any] = ["name": name, "samples": pts,
                                "light": ["tile": "FFFDFA", "handset": "1C1814", "accent": "F2571A"],
                                "dark": ["tile": "171411", "handset": "FFF8F1", "accent": "FF6A2B"]]
    var all = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file)))) as? [[String: Any]] ?? []
    all.removeAll { $0["name"] as? String == name }
    all.append(entry)
    try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: file))
}

// MARK: Menu bar template PDFs

if let dir = o.menuDir {
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
    // 18 x 18 pt canvas, mark 15 pt, centred: optically matched to SF Symbols in the 24 pt menu bar.
    let mt = placement(extent: 15, size: 18)
    // Connected: filled handset + arcs. Disconnected: the handset in Lucide's own outline (stroke 2, about the
    // weight of a regular SF Symbol at this size) without arcs -- the same filled/outline convention as the
    // system's phone.fill / phone, plus the arcs as a second cue. Both share one placement, so nothing jumps.
    let idle = stroked(lucideHandset, 2)
    for (name, shapes) in [("MenuBarConnected", [handset, arcs]), ("MenuBarDisconnected", [idle])] {
        let target = URL(fileURLWithPath: dir).appendingPathComponent("\(name).pdf")
        let data = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 18, height: 18)
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &media,
                            [kCGPDFContextCreator: "scripts/generate-app-icon.swift"] as CFDictionary)!
        ctx.beginPDFPage(nil)
        ctx.translateBy(x: 0, y: 18); ctx.scaleBy(x: 1, y: -1)     // y down, as the SVG geometry
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for s in shapes { var tt = mt; ctx.addPath(s.copy(using: &tt)!) }
        ctx.fillPath()
        ctx.endPDFPage(); ctx.closePDF()
        // PDFs carry their creation date and a random ID: keep the existing file when only those differ (no churn in git).
        func undated(_ d: Data) -> String {
            String(decoding: d, as: UTF8.self).replacingOccurrences(of: #"\((D:[0-9+\-Z']+)\)"#, with: "()", options: .regularExpression)
                .replacingOccurrences(of: #"<[0-9a-f]{32}>"#, with: "<>", options: .regularExpression)
        }
        if let old = try? Data(contentsOf: target), undated(old) == undated(data as Data) { continue }
        try (data as Data).write(to: target)
    }
    print("menu bar: \(dir)/MenuBarConnected.pdf, MenuBarDisconnected.pdf (18 x 18 pt, mark 15 pt)")
}
