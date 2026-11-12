// glitch-ref-render: the Mac's Glitch stage (Receiver.swift, GlitchParams.swift,
// GlitchStage.swift, compiled as-is) on a picture, for checking the Rust port.
//   glitch-ref-render <in.png> <time> <out.png> [key=value ...]
// The receiver advances at 30 fps from zero, as playback does.
import Foundation
import Metal
import ImageIO
import CoreGraphics

let a = CommandLine.arguments
let time = Double(a[2])!
var values: [String: Double] = [:]
for kv in a.dropFirst(4) { let p = kv.split(separator: "="); values[String(p[0])] = Double(p[1])! }

let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil)!
let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let w = img.width, h = img.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
d.usage = [.shaderRead, .shaderWrite]
let input = device.makeTexture(descriptor: d)!
input.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
let output = device.makeTexture(descriptor: d)!

let settings = GlitchSettings(values: values)
let sim = ReceiverSimulator(raster: ReceiverRaster(width: w, activeLines: h))
sim.advance(to: 0, settings: settings)
var t = 0.0
while t < time { t = min(time, t + 1.0 / 30.0); sim.advance(to: t, settings: settings) }
let stage = try! GlitchStage(device: device)
let cb = queue.makeCommandBuffer()!
stage.encode(into: cb, input: input, output: output, plan: sim.plan())
cb.commit(); cb.waitUntilCompleted()
output.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
let outCtx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[3]) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, outCtx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
