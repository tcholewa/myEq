import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory,withIntermediateDirectories:true)
let colors: [[CGFloat]] = [[0.96,0.69,0.25,1],[0.40,0.83,0.48,1],[0.25,0.79,0.67,1],[0.28,0.76,0.91,1],[0.64,0.49,0.94,1]]
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels=size*scale
        let context=CGContext(data:nil,width:pixels,height:pixels,bitsPerComponent:8,bytesPerRow:pixels*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x:CGFloat(pixels)/1024,y:CGFloat(pixels)/1024)
        let rect=CGRect(x:40,y:40,width:944,height:944)
        context.addPath(CGPath(roundedRect:rect,cornerWidth:220,cornerHeight:220,transform:nil))
        context.setFillColor(CGColor(red:0.09,green:0.11,blue:0.14,alpha:1));context.fillPath()
        for i in 0..<5 {
            let x=CGFloat(235+i*138), y=CGFloat([610,390,550,460,650][i])
            context.setLineCap(.round);context.setLineWidth(22)
            context.setStrokeColor(CGColor(red:0.23,green:0.27,blue:0.31,alpha:1))
            context.move(to:CGPoint(x:x,y:250));context.addLine(to:CGPoint(x:x,y:775));context.strokePath()
            context.setStrokeColor(CGColor(colorSpace:CGColorSpaceCreateDeviceRGB(),components:colors[i])!)
            context.move(to:CGPoint(x:x,y:250));context.addLine(to:CGPoint(x:x,y:y));context.strokePath()
            context.setFillColor(CGColor(colorSpace:CGColorSpaceCreateDeviceRGB(),components:colors[i])!)
            context.addPath(CGPath(roundedRect:CGRect(x:x-43,y:y-25,width:86,height:50),cornerWidth:13,cornerHeight:13,transform:nil));context.fillPath()
        }
        let name="icon_\(size)x\(size)\(scale==2 ? "@2x":"").png"
        let destination=CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(destination,context.makeImage()!,nil)
        guard CGImageDestinationFinalize(destination) else {fatalError("Unable to write icon")}
    }
}

// Standard PNG-backed ICNS chunks, without an iconutil dependency.
func bigEndian(_ value: Int) -> Data {
    var number = UInt32(value).bigEndian
    return withUnsafeBytes(of: &number) { Data($0) }
}
let chunks = [("icp4","icon_16x16.png"),("icp5","icon_32x32.png"),("icp6","icon_32x32@2x.png"),("ic07","icon_128x128.png"),("ic08","icon_256x256.png"),("ic09","icon_512x512.png"),("ic10","icon_512x512@2x.png"),("ic11","icon_16x16@2x.png"),("ic12","icon_32x32@2x.png"),("ic13","icon_128x128@2x.png"),("ic14","icon_256x256@2x.png")]
var payload = Data()
for (kind,name) in chunks {
    let png = try Data(contentsOf: directory.appendingPathComponent(name))
    payload.append(Data(kind.utf8)); payload.append(bigEndian(png.count+8)); payload.append(png)
}
var icon = Data("icns".utf8); icon.append(bigEndian(payload.count+8)); icon.append(payload)
try icon.write(to: directory.deletingPathExtension().appendingPathExtension("icns"))
