// Counts the pixels that differ between two PNGs of the same size, for the
// macOS parity check.
//
//   swift nix/image-diff.swift a.png b.png [--fuzz <percent>] [--out diff.png]
//
// A pixel differs when the Euclidean RGBA distance exceeds `fuzz` percent of
// the maximum (ImageMagick's `compare -metric AE -fuzz`); default 2. Prints
// "<differing> of <total>" and, with --out, writes the differing pixels in
// red over a dimmed copy of `a`. Exit 0 always (1 on a read error).

import AppKit
import CoreGraphics
import Foundation

func pixels(_ path: String) -> (width: Int, height: Int, data: [UInt8])? {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let width = cg.width, height = cg.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (width, height, data)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var fuzz = 2.0
var out: String?
if let i = arguments.firstIndex(of: "--fuzz"), i + 1 < arguments.count {
    fuzz = Double(arguments[i + 1]) ?? 2
    arguments.removeSubrange(i...(i + 1))
}
if let i = arguments.firstIndex(of: "--out"), i + 1 < arguments.count {
    out = arguments[i + 1]
    arguments.removeSubrange(i...(i + 1))
}
guard arguments.count == 2, let a = pixels(arguments[0]), let b = pixels(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: image-diff a.png b.png [--fuzz <percent>] [--out diff.png]\n".utf8))
    exit(1)
}
guard a.width == b.width, a.height == b.height else {
    print("sizes differ: \(a.width)x\(a.height) vs \(b.width)x\(b.height)")
    exit(0)
}
let limit = fuzz / 100 * (255.0 * 2)  // sqrt(4 * 255²)
var differing = 0
var diff = a.data.enumerated().map { $0.offset % 4 == 3 ? UInt8(255) : $0.element / 4 }
for p in 0..<(a.width * a.height) {
    var sum = 0.0
    for c in 0..<4 {
        let d = Double(a.data[p * 4 + c]) - Double(b.data[p * 4 + c])
        sum += d * d
    }
    if sum.squareRoot() > limit {
        differing += 1
        diff[p * 4] = 255; diff[p * 4 + 1] = 0; diff[p * 4 + 2] = 0
    }
}
print("\(differing) of \(a.width * a.height)")
if let out {
    let provider = CGDataProvider(data: Data(diff) as CFData)!
    let image = CGImage(width: a.width, height: a.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: a.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
}
