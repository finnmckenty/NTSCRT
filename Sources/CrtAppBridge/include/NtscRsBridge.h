#ifndef NTSCRS_BRIDGE_H
#define NTSCRS_BRIDGE_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C wrapper around the ntscrs-capi dylib (a minimal C ABI over
/// the ntsc-rs core library). Mirrors the LRShaderChain pattern: the dylib
/// is dlopen'd once via +loadLibrary:error:, instances hold an opaque
/// effect-settings handle.
///
/// Settings travel as JSON in ntsc-rs's stable "version": 1 preset format —
/// the same format the ntsc-rs GUI copies/pastes — so presets are portable
/// between the two apps.
@interface NTSCFilter : NSObject

/// Load ntscrs_capi.dylib from the given path. Call once before creating
/// any filter.
+ (BOOL)loadLibrary:(NSString *)dylibPath error:(NSError * _Nullable * _Nullable)error;

/// YES once the library is loaded.
+ (BOOL)isLibraryLoaded;

/// JSON schema of every setting (name, label, description, kind, ranges,
/// enum options, nested groups) for building a UI. nil if not loaded.
+ (nullable NSString *)settingsDescriptorsJSON;

/// New filter with ntsc-rs default settings. nil if the library isn't loaded.
- (nullable instancetype)init;

/// Current settings as preset JSON.
- (nullable NSString *)settingsJSON;

/// Replace settings from preset JSON (accepts ntsc-rs GUI presets,
/// including legacy ntscQT ones).
- (BOOL)setSettingsJSON:(NSString *)json error:(NSError * _Nullable * _Nullable)error;

/// Apply the effect in place to a BGRA8 buffer. `frameIndex` selects the
/// field (interlacing) and seeds the deterministic noise. Alpha is written
/// opaque.
- (BOOL)processBGRA8:(void *)data
               width:(NSUInteger)width
              height:(NSUInteger)height
            rowBytes:(NSUInteger)rowBytes
          frameIndex:(NSInteger)frameIndex;

@end

NS_ASSUME_NONNULL_END

#endif
