import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = size * scale
    let context = CGContext(
      data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let rect = CGRect(x: 64, y: 64, width: 896, height: 896)
    let shell = CGPath(roundedRect: rect, cornerWidth: 204, cornerHeight: 204, transform: nil)
    context.saveGState()
    context.setShadow(
      offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.4))
    context.addPath(shell)
    context.setFillColor(CGColor(gray: 0.08, alpha: 1))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(shell)
    context.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let background = CGGradient(
      colorSpace: space, colorComponents: [0.055, 0.060, 0.070, 1, 0.18, 0.19, 0.21, 1],
      locations: [0, 1], count: 2)!
    context.drawLinearGradient(
      background, start: CGPoint(x: 780, y: 64), end: CGPoint(x: 260, y: 960),
      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let light = CGGradient(
      colorSpace: space, colorComponents: [0.75, 0.56, 0.32, 0.11, 0.75, 0.56, 0.32, 0],
      locations: [0, 1], count: 2)!
    context.drawRadialGradient(
      light, startCenter: CGPoint(x: 320, y: 780), startRadius: 0,
      endCenter: CGPoint(x: 320, y: 780), endRadius: 650, options: [])
    context.restoreGState()
    context.addPath(shell)
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.10))
    context.setLineWidth(3)
    context.strokePath()
    for i in 0..<3 {
      let x = CGFloat(322 + i * 190)
      let y = CGFloat([630, 400, 550][i])
      context.setLineCap(.round)
      context.setLineWidth(22)
      context.setStrokeColor(CGColor(red: 0.91, green: 0.79, blue: 0.57, alpha: 0.28))
      context.move(to: CGPoint(x: x, y: 260))
      context.addLine(to: CGPoint(x: x, y: 770))
      context.strokePath()
      let thumb = CGPath(
        roundedRect: CGRect(x: x - 61, y: y - 29, width: 122, height: 58), cornerWidth: 17,
        cornerHeight: 17, transform: nil)
      context.saveGState()
      context.setShadow(
        offset: CGSize(width: 0, height: -7), blur: 15, color: CGColor(gray: 0, alpha: 0.35))
      context.addPath(thumb)
      context.setFillColor(CGColor(red: 0.91, green: 0.79, blue: 0.57, alpha: 1))
      context.fillPath()
      context.restoreGState()
      context.saveGState()
      context.addPath(thumb)
      context.clip()
      let gold = CGGradient(
        colorSpace: space, colorComponents: [0.72, 0.56, 0.33, 1, 0.98, 0.91, 0.75, 1],
        locations: [0, 1], count: 2)!
      context.drawLinearGradient(
        gold, start: CGPoint(x: x, y: y - 29), end: CGPoint(x: x, y: y + 29), options: [])
      context.restoreGState()
      context.addPath(thumb)
      context.setStrokeColor(CGColor(red: 1, green: 0.95, blue: 0.82, alpha: 0.4))
      context.setLineWidth(2)
      context.strokePath()
    }
    let name = "icon_\(size)x\(size)\(scale==2 ? "@2x":"").png"
    let destination = CGImageDestinationCreateWithURL(
      directory.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Unable to write icon") }
  }
}

// Standard PNG-backed ICNS chunks, without an iconutil dependency.
func bigEndian(_ value: Int) -> Data {
  var number = UInt32(value).bigEndian
  return withUnsafeBytes(of: &number) { Data($0) }
}
let chunks = [
  ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"), ("icp6", "icon_32x32@2x.png"),
  ("ic07", "icon_128x128.png"), ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
  ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"), ("ic12", "icon_32x32@2x.png"),
  ("ic13", "icon_128x128@2x.png"), ("ic14", "icon_256x256@2x.png"),
]
var payload = Data()
for (kind, name) in chunks {
  let png = try Data(contentsOf: directory.appendingPathComponent(name))
  payload.append(Data(kind.utf8))
  payload.append(bigEndian(png.count + 8))
  payload.append(png)
}
var icon = Data("icns".utf8)
icon.append(bigEndian(payload.count + 8))
icon.append(payload)
try icon.write(to: directory.deletingPathExtension().appendingPathExtension("icns"))
