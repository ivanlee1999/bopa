import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Renders the bopa app icon: a white page on ink-blue, with handwriting strokes.
// Usage: icongen <output.png> [size]

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let size = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2])! : 1024
let s = CGFloat(size)

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("cannot create context") }

// Flip to a top-left origin so the drawing math reads naturally.
ctx.translateBy(x: 0, y: s)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r / 255, g / 255, b / 255, 1])!
}

// Background: ink-blue gradient.
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [rgb(46, 62, 110), rgb(22, 28, 54)] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(
    gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: s, y: s), options: [])

// Page: white rounded sheet with a soft drop shadow.
let inset = s * 0.135
let pageRect = CGRect(x: inset, y: inset * 0.92, width: s - inset * 2, height: s - inset * 1.84)
let pagePath = CGPath(
    roundedRect: pageRect, cornerWidth: s * 0.045, cornerHeight: s * 0.045, transform: nil)

ctx.saveGState()
ctx.setShadow(
    offset: CGSize(width: 0, height: s * 0.012), blur: s * 0.05,
    color: CGColor(colorSpace: colorSpace, components: [0, 0, 0, 0.35])!)
ctx.addPath(pagePath)
ctx.setFillColor(rgb(255, 255, 255))
ctx.fillPath()
ctx.restoreGState()

// A handwritten lowercase "b" — the app's initial, drawn like pen strokes.
ctx.saveGState()
ctx.addPath(pagePath)
ctx.clip()
ctx.setStrokeColor(rgb(20, 22, 28))
ctx.setLineCap(.round)
ctx.setLineJoin(.round)

let cx = pageRect.midX
let top = pageRect.minY + pageRect.height * 0.17
let baseline = pageRect.maxY - pageRect.height * 0.22
let bowlTop = pageRect.minY + pageRect.height * 0.50
let stemX = cx - pageRect.width * 0.20
let bowlRight = cx + pageRect.width * 0.26

// Ascender: a slightly curved stem with an entry flick, thick like a downstroke.
ctx.setLineWidth(s * 0.058)
ctx.move(to: CGPoint(x: stemX - pageRect.width * 0.10, y: top + pageRect.height * 0.06))
ctx.addCurve(
    to: CGPoint(x: stemX, y: bowlTop),
    control1: CGPoint(x: stemX - pageRect.width * 0.02, y: top),
    control2: CGPoint(x: stemX - pageRect.width * 0.015, y: bowlTop - pageRect.height * 0.18))
ctx.addCurve(
    to: CGPoint(x: stemX + pageRect.width * 0.012, y: baseline),
    control1: CGPoint(x: stemX + pageRect.width * 0.008, y: bowlTop + pageRect.height * 0.08),
    control2: CGPoint(x: stemX - pageRect.width * 0.01, y: baseline - pageRect.height * 0.06))
ctx.strokePath()

// Bowl: the round of the "b", closing back onto the stem.
ctx.setLineWidth(s * 0.052)
ctx.move(to: CGPoint(x: stemX + pageRect.width * 0.006, y: bowlTop + pageRect.height * 0.05))
ctx.addCurve(
    to: CGPoint(x: bowlRight, y: (bowlTop + baseline) / 2),
    control1: CGPoint(x: stemX + pageRect.width * 0.16, y: bowlTop - pageRect.height * 0.04),
    control2: CGPoint(x: bowlRight + pageRect.width * 0.04, y: bowlTop + pageRect.height * 0.02))
ctx.addCurve(
    to: CGPoint(x: stemX + pageRect.width * 0.02, y: baseline),
    control1: CGPoint(x: bowlRight - pageRect.width * 0.02, y: baseline - pageRect.height * 0.02),
    control2: CGPoint(x: stemX + pageRect.width * 0.20, y: baseline + pageRect.height * 0.04))
ctx.strokePath()

// Exit flick off the baseline, the way a pen leaves the paper.
ctx.setLineWidth(s * 0.030)
ctx.move(to: CGPoint(x: stemX + pageRect.width * 0.02, y: baseline))
ctx.addCurve(
    to: CGPoint(x: cx + pageRect.width * 0.30, y: baseline - pageRect.height * 0.045),
    control1: CGPoint(x: stemX + pageRect.width * 0.14, y: baseline + pageRect.height * 0.035),
    control2: CGPoint(x: cx + pageRect.width * 0.20, y: baseline + pageRect.height * 0.01))
ctx.strokePath()
ctx.restoreGState()

guard let image = ctx.makeImage() else { fatalError("cannot render") }
let url = URL(fileURLWithPath: outputPath)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("cannot create destination") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("cannot write png") }
print("wrote \(outputPath) (\(size)x\(size))")
