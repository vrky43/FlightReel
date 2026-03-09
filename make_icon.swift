#!/usr/bin/env swift
import AppKit
import Foundation

// MARK: - Draw the 1024×1024 master icon

func makeIcon(size: Int) -> CGImage {
    let S  = CGFloat(size)
    let cx = S / 2
    let cy = S / 2
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: size * 4,
                        space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // ── 1. Orange gradient background ────────────────────────────────────
    let bgColors = [CGColor(red: 1.00, green: 0.45, blue: 0.00, alpha: 1),   // deep orange
                    CGColor(red: 1.00, green: 0.65, blue: 0.10, alpha: 1)] as CFArray
    let locs: [CGFloat] = [0, 1]
    let bgGrad = CGGradient(colorsSpace: cs, colors: bgColors, locations: locs)!
    ctx.drawLinearGradient(bgGrad,
                           start: CGPoint(x: 0,  y: S),
                           end:   CGPoint(x: S,  y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // ── 2. Subtle inner shadow/vignette ──────────────────────────────────
    let vigColors = [CGColor(red: 0, green: 0, blue: 0, alpha: 0.25),
                     CGColor(red: 0, green: 0, blue: 0, alpha: 0.00)] as CFArray
    let vigGrad = CGGradient(colorsSpace: cs, colors: vigColors, locations: locs)!
    ctx.drawRadialGradient(vigGrad,
                           startCenter: CGPoint(x: cx, y: cy), startRadius: S * 0.45,
                           endCenter:   CGPoint(x: cx, y: cy), endRadius:   S * 0.70,
                           options: [.drawsAfterEndLocation])

    // ── 3. Drone (quadcopter, top view) ──────────────────────────────────
    // Measurements (all relative to S)
    let armLen:   CGFloat = S * 0.270   // centre → motor centre
    let motorR:   CGFloat = S * 0.090   // filled motor disc
    let propR:    CGFloat = S * 0.125   // propeller ring (stroke only)
    let propW:    CGFloat = S * 0.018   // ring stroke width
    let armW:     CGFloat = S * 0.048   // arm thickness
    let bodyR:    CGFloat = S * 0.072   // central body disc
    let hubR:     CGFloat = S * 0.028   // tiny hub

    let droneColor = CGColor(red: 1, green: 1, blue: 1, alpha: 0.95)
    let shadowColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.25)

    // Arm angles: NE, NW, SW, SE (45° diagonals)
    let angles: [CGFloat] = [45, 135, 225, 315].map { $0 * .pi / 180 }
    let motorCenters = angles.map {
        CGPoint(x: cx + armLen * cos($0), y: cy + armLen * sin($0))
    }

    // --- Shadow pass (offset draw) ---
    let shadowDx: CGFloat = S * 0.012
    let shadowDy: CGFloat = -S * 0.012

    func drawDrone(dx: CGFloat, dy: CGFloat, color: CGColor) {
        ctx.setFillColor(color)
        ctx.setStrokeColor(color)

        // Arms
        ctx.setLineWidth(armW)
        ctx.setLineCap(.round)
        for (i, angle) in angles.enumerated() {
            let mc = motorCenters[i]
            let startX = cx + (bodyR + armW * 0.3) * cos(angle) + dx
            let startY = cy + (bodyR + armW * 0.3) * sin(angle) + dy
            let endX   = mc.x - motorR * cos(angle) + dx
            let endY   = mc.y - motorR * sin(angle) + dy
            ctx.move(to: CGPoint(x: startX, y: startY))
            ctx.addLine(to: CGPoint(x: endX, y: endY))
            ctx.strokePath()
        }

        // Motor discs
        for mc in motorCenters {
            ctx.fillEllipse(in: CGRect(x: mc.x - motorR + dx,
                                       y: mc.y - motorR + dy,
                                       width:  motorR * 2,
                                       height: motorR * 2))
        }

        // Propeller rings
        ctx.setLineWidth(propW)
        for mc in motorCenters {
            ctx.strokeEllipse(in: CGRect(x: mc.x - propR + dx,
                                         y: mc.y - propR + dy,
                                         width:  propR * 2,
                                         height: propR * 2))
        }

        // Central body
        ctx.fillEllipse(in: CGRect(x: cx - bodyR + dx,
                                    y: cy - bodyR + dy,
                                    width:  bodyR * 2,
                                    height: bodyR * 2))

        // Hub dot
        ctx.setFillColor(CGColor(red: 1.0, green: 0.55, blue: 0.0, alpha: color == droneColor ? 0.85 : 0))
        ctx.fillEllipse(in: CGRect(x: cx - hubR + dx,
                                    y: cy - hubR + dy,
                                    width:  hubR * 2,
                                    height: hubR * 2))
    }

    drawDrone(dx: shadowDx, dy: shadowDy, color: shadowColor)
    drawDrone(dx: 0,        dy: 0,        color: droneColor)

    return ctx.makeImage()!
}

// MARK: - Helpers

func scale(_ src: CGImage, to size: Int) -> CGImage {
    let cs  = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: size * 4,
                        space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

func savePNG(_ img: CGImage, path: String) {
    let url  = URL(fileURLWithPath: path)
    let dest = CGImageDestinationCreateWithURL(url as CFURL,
                   "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - Main

let dir = "Sources/FlightReel/Assets.xcassets/AppIcon.appiconset"
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

let base = makeIcon(size: 1024)

let sizes: [(String, Int)] = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png",1024),
]

for (name, px) in sizes {
    savePNG(scale(base, to: px), path: "\(dir)/\(name)")
    print("  ✓ \(name)")
}

let contents = """
{
  "images": [
    {"filename":"icon_16x16.png",      "idiom":"mac","scale":"1x","size":"16x16"},
    {"filename":"icon_16x16@2x.png",   "idiom":"mac","scale":"2x","size":"16x16"},
    {"filename":"icon_32x32.png",      "idiom":"mac","scale":"1x","size":"32x32"},
    {"filename":"icon_32x32@2x.png",   "idiom":"mac","scale":"2x","size":"32x32"},
    {"filename":"icon_128x128.png",    "idiom":"mac","scale":"1x","size":"128x128"},
    {"filename":"icon_128x128@2x.png", "idiom":"mac","scale":"2x","size":"128x128"},
    {"filename":"icon_256x256.png",    "idiom":"mac","scale":"1x","size":"256x256"},
    {"filename":"icon_256x256@2x.png", "idiom":"mac","scale":"2x","size":"256x256"},
    {"filename":"icon_512x512.png",    "idiom":"mac","scale":"1x","size":"512x512"},
    {"filename":"icon_512x512@2x.png", "idiom":"mac","scale":"2x","size":"512x512"}
  ],
  "info": {"author":"xcode","version":1}
}
"""
try! contents.write(toFile: "\(dir)/Contents.json", atomically: true, encoding: .utf8)
print("  ✓ Contents.json")
print("Done.")
