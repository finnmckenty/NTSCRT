#ifndef LIBRASHADER_BRIDGE_H
#define LIBRASHADER_BRIDGE_H

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

@interface LRShaderParam : NSObject
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *desc;
@property (nonatomic, readonly) float initial;
@property (nonatomic, readonly) float minimum;
@property (nonatomic, readonly) float maximum;
@property (nonatomic, readonly) float step;
@end

@interface LRShaderChain : NSObject

/// Load librashader.dylib from the given path. Must be called once before any chain is created.
/// If `path` is nil, the loader uses the OS default search (next to the executable, DYLD_LIBRARY_PATH, @rpath).
/// Returns NO and fills `error` on failure (dylib not found, ABI mismatch, etc.).
+ (BOOL)loadLibrary:(nullable NSString *)dylibPath error:(NSError * _Nullable * _Nullable)error;

/// YES once a library has been loaded successfully.
+ (BOOL)isLibraryLoaded;

/// Create a filter chain from a .slangp preset for the given Metal command queue.
- (nullable instancetype)initWithPresetPath:(NSString *)presetPath
                               commandQueue:(id<MTLCommandQueue>)queue
                                      error:(NSError * _Nullable * _Nullable)error;

/// Encode one frame of the filter chain into `commandBuffer`.
/// Reads from `inputTexture` and writes to `outputTexture` over the given viewport.
/// `frameCount` is the running frame number some shaders use for animation (interlacing, scanline drift).
- (BOOL)renderInputTexture:(id<MTLTexture>)inputTexture
             outputTexture:(id<MTLTexture>)outputTexture
                  viewport:(MTLViewport)viewport
                frameCount:(NSUInteger)frameCount
             commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                     error:(NSError * _Nullable * _Nullable)error;

/// Runtime parameters declared by the preset (sliders the UI should expose).
- (NSArray<LRShaderParam *> *)parameters;

/// Set a runtime parameter by name. Must match a name returned from `parameters`.
- (BOOL)setParameter:(NSString *)name value:(float)value error:(NSError * _Nullable * _Nullable)error;

/// Get the current value of a runtime parameter.
- (float)parameterValue:(NSString *)name;

@end

NS_ASSUME_NONNULL_END

#import "NtscRsBridge.h"

#endif
