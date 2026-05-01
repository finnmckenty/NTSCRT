import Foundation
import Metal
import MetalKit
import CoreGraphics
import ImageIO
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

public enum ImageIOError: Error {
    case loadFailed(String)
    case writeFailed(String)
}

/// Load an image file (PNG, JPEG, HEIC, …) into an MTLTexture.
///
/// The texture is BGRA8Unorm (linear), private storage, usable as shader read.
/// Origin is top-left, matching how the rest of the pipeline expects input.
public func loadTexture(url: URL, device: MTLDevice) throws -> MTLTexture {
    let loader = MTKTextureLoader(device: device)
    let opts: [MTKTextureLoader.Option: Any] = [
        .textureUsage:        NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
        .textureStorageMode:  NSNumber(value: MTLStorageMode.private.rawValue),
        .SRGB:                NSNumber(value: false),
        .origin:              MTKTextureLoader.Origin.topLeft.rawValue,
    ]
    return try loader.newTexture(URL: url, options: opts)
}

/// Read an MTLTexture back into a CGImage.
///
/// Caller must ensure the texture is shared-storage (so `getBytes` works) — the
/// pipeline uses a blit to a staging texture for this.
public func makeCGImage(from texture: MTLTexture) throws -> CGImage {
    precondition(texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .bgra8Unorm_srgb,
                 "expected BGRA8 texture")
    let width = texture.width
    let height = texture.height
    let bpr = width * 4
    var pixels = [UInt8](repeating: 0, count: height * bpr)
    pixels.withUnsafeMutableBytes { raw in
        texture.getBytes(raw.baseAddress!,
                         bytesPerRow: bpr,
                         from: MTLRegionMake2D(0, 0, width, height),
                         mipmapLevel: 0)
    }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let bm: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
                   | CGBitmapInfo.byteOrder32Little.rawValue
    guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
        throw ImageIOError.writeFailed("CGDataProvider")
    }
    guard let cg = CGImage(width: width, height: height,
                           bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: bpr,
                           space: cs,
                           bitmapInfo: CGBitmapInfo(rawValue: bm),
                           provider: provider, decode: nil,
                           shouldInterpolate: false, intent: .defaultIntent) else {
        throw ImageIOError.writeFailed("CGImage")
    }
    return cg
}

/// Write a CGImage as a PNG file at `url`.
public func writePNG(_ image: CGImage, to url: URL) throws {
    let pngType: CFString = {
        if #available(macOS 11.0, *) { return UTType.png.identifier as CFString }
        return "public.png" as CFString
    }()
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, pngType, 1, nil) else {
        throw ImageIOError.writeFailed("CGImageDestination")
    }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) {
        throw ImageIOError.writeFailed("CGImageDestination finalize")
    }
}

/// Allocate a private MTLTexture for use as a shader render target.
public func makeRenderTarget(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
    let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
    )
    d.usage = [.renderTarget, .shaderRead, .shaderWrite]
    d.storageMode = .private
    return device.makeTexture(descriptor: d)
}

/// Allocate a shared-storage staging texture so we can read pixels back.
public func makeStagingTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
    let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
    )
    d.usage = [.shaderRead]
    d.storageMode = .shared
    return device.makeTexture(descriptor: d)
}
