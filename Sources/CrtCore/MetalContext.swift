import Foundation
import Metal

/// Holds the single Metal device + command queue used by the entire app.
///
/// librashader's Metal runtime is not thread-safe; everything that touches a
/// chain — including the downscaler that runs in the same command buffer —
/// must funnel through this single queue.
public final class MetalContext {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let downscaler: Downscaler

    public init() throws {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "MetalContext", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no Metal device"])
        }
        guard let q = dev.makeCommandQueue() else {
            throw NSError(domain: "MetalContext", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no command queue"])
        }
        self.device = dev
        self.queue = q
        self.downscaler = try Downscaler(device: dev)
    }
}
