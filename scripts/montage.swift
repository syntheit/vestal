// Lays PNGs out on one canvas for the README images, with CoreGraphics
// only (no third-party tools). Each input is scaled to the cell width.
//
//   swiftc -O -o montage scripts/montage.swift
//   montage out.png --columns 3 --width 600 --gap 24 --pad 32 [--trim 40] [--bg 1b1d26] [--masonry] [--radius 12] a.png b.png ...
//
// Without --bg the canvas is transparent. `--trim 40` crops each input, top
// and bottom, to what differs from its top-left pixel, keeping 40 pixels of
// margin; the width stays, so every input keeps the same scale.
//
// Grid: row by row, each row as tall as its tallest image, images top-aligned.
// Masonry: each image goes to the shortest column so far.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Arguments

var columns = 3, cellWidth = 600.0, gap = 24.0, pad = 32.0, radius = 0.0, trim = -1
var bg: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
var masonry = false
var inputs: [String] = []
var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    FileHandle.standardError.write("usage: montage out.png [options] in.png...\n".data(using: .utf8)!)
    exit(2)
}
let output = args.removeFirst()
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--columns": columns = Int(args.removeFirst())!
    case "--width": cellWidth = Double(args.removeFirst())!
    case "--gap": gap = Double(args.removeFirst())!
    case "--pad": pad = Double(args.removeFirst())!
    case "--radius": radius = Double(args.removeFirst())!
    case "--trim": trim = Int(args.removeFirst())!
    case "--masonry": masonry = true
    case "--bg":
        let v = UInt32(args.removeFirst(), radix: 16)!
        bg = (CGFloat((v >> 16) & 0xff) / 255, CGFloat((v >> 8) & 0xff) / 255, CGFloat(v & 0xff) / 255, 1)
    default: inputs.append(a)
    }
}

// MARK: - Layout

func load(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        FileHandle.standardError.write("montage: can't read \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    return img
}

/// The image cropped, top and bottom, to the rows with a pixel that differs
/// from its top-left one, plus `margin` above and below.
func trimmed(_ img: CGImage, margin: Int) -> CGImage {
    let w = img.width, h = img.height
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    // Row 0 of the buffer is the top of the image.
    let ref = Array(px[0..<4])
    var minY = h, maxY = -1
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            if (0..<4).contains(where: { abs(Int(px[i + $0]) - Int(ref[$0])) > 12 }) {
                minY = min(minY, y); maxY = max(maxY, y)
                break
            }
        }
    }
    guard maxY >= 0 else { return img }
    let top = max(0, minY - margin)
    let box = CGRect(x: 0, y: top, width: w, height: min(h, maxY + margin + 1) - top)
    return img.cropping(to: box) ?? img
}

let images = inputs.map(load).map { trim >= 0 ? trimmed($0, margin: trim) : $0 }
let heights = images.map { cellWidth * Double($0.height) / Double($0.width) }
var frames: [CGRect] = []
var canvasHeight = 0.0
if masonry {
    var tops = Array(repeating: pad, count: columns)
    for h in heights {
        let c = tops.indices.min { tops[$0] < tops[$1] }!
        frames.append(CGRect(x: pad + Double(c) * (cellWidth + gap), y: tops[c], width: cellWidth, height: h))
        tops[c] += h + gap
    }
    canvasHeight = tops.max()! - gap + pad
} else {
    var y = pad
    for start in stride(from: 0, to: images.count, by: columns) {
        let row = start..<min(start + columns, images.count)
        for i in row {
            frames.append(CGRect(x: pad + Double(i - start) * (cellWidth + gap), y: y, width: cellWidth, height: heights[i]))
        }
        y += row.map { heights[$0] }.max()! + gap
    }
    canvasHeight = y - gap + pad
}
let canvasWidth = pad * 2 + Double(columns) * cellWidth + Double(columns - 1) * gap

// MARK: - Draw

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(canvasWidth.rounded()), height: Int(canvasHeight.rounded()),
                    bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
ctx.setFillColor(CGColor(colorSpace: space, components: [bg.0, bg.1, bg.2, bg.3])!)
ctx.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
for (img, f) in zip(images, frames) {
    // CoreGraphics counts y from the bottom.
    let r = CGRect(x: f.minX, y: canvasHeight - f.maxY, width: f.width, height: f.height)
    ctx.saveGState()
    if radius > 0 {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
    }
    ctx.draw(img, in: r)
    ctx.restoreGState()
}

let url = URL(fileURLWithPath: output) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { exit(1) }
