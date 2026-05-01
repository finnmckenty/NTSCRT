#import "LibrashaderBridge.h"

#define LIBRA_RUNTIME_METAL
#include "librashader_ld.h"

static NSString *const kErrorDomain = @"LibrashaderBridge";

static libra_instance_t gInstance;
static BOOL gLoaded = NO;

static NSError *makeError(NSInteger code, NSString *msg) {
    return [NSError errorWithDomain:kErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static NSString *libraErrorMessage(libra_error_t err) {
    if (err == NULL) return @"unknown error";
    char *buf = NULL;
    int32_t rc = gInstance.error_write(err, &buf);
    NSString *out = (rc == 0 && buf != NULL)
        ? [NSString stringWithUTF8String:buf]
        : @"unknown librashader error";
    if (buf != NULL) {
        gInstance.error_free_string(&buf);
    }
    libra_error_t e = err;
    gInstance.error_free(&e);
    return out;
}

#pragma mark - LRShaderParam

@implementation LRShaderParam {
    NSString *_name;
    NSString *_desc;
    float _initial, _minimum, _maximum, _step;
}
- (instancetype)initWithName:(NSString *)name
                        desc:(NSString *)desc
                     initial:(float)initial
                     minimum:(float)minimum
                     maximum:(float)maximum
                        step:(float)step {
    if ((self = [super init])) {
        _name = [name copy];
        _desc = [desc copy];
        _initial = initial;
        _minimum = minimum;
        _maximum = maximum;
        _step = step;
    }
    return self;
}
- (NSString *)name { return _name; }
- (NSString *)desc { return _desc; }
- (float)initial { return _initial; }
- (float)minimum { return _minimum; }
- (float)maximum { return _maximum; }
- (float)step { return _step; }
@end

#pragma mark - LRShaderChain

@implementation LRShaderChain {
    libra_mtl_filter_chain_t _chain;
    NSArray<LRShaderParam *> *_params;
}

+ (BOOL)loadLibrary:(NSString *)dylibPath error:(NSError **)error {
    if (gLoaded) return YES;

    void *handle = NULL;
    if (dylibPath.length > 0) {
        handle = dlopen(dylibPath.fileSystemRepresentation, RTLD_LAZY);
        if (!handle) {
            if (error) *error = makeError(1, [NSString stringWithFormat:@"dlopen failed for %@: %s", dylibPath, dlerror()]);
            return NO;
        }
        // Use the manual loader path so we control which dylib we open.
        gInstance = __librashader_make_null_instance();

        #define LOAD(name) do { \
            void *addr = dlsym(handle, "libra_" #name); \
            if (addr) gInstance.name = (PFN_libra_##name)addr; \
        } while(0)

        LOAD(instance_abi_version);
        LOAD(instance_api_version);

        if (gInstance.instance_abi_version() != LIBRASHADER_CURRENT_ABI) {
            if (error) *error = makeError(2, [NSString stringWithFormat:@"librashader ABI mismatch: have %zu, expected %zu", gInstance.instance_abi_version(), (size_t)LIBRASHADER_CURRENT_ABI]);
            return NO;
        }

        LOAD(error_errno); LOAD(error_print); LOAD(error_free); LOAD(error_write); LOAD(error_free_string);
        LOAD(preset_create); LOAD(preset_free); LOAD(preset_set_param); LOAD(preset_get_param);
        LOAD(preset_get_runtime_params); LOAD(preset_free_runtime_params);
        LOAD(mtl_filter_chain_create);
        LOAD(mtl_filter_chain_create_deferred);
        LOAD(mtl_filter_chain_frame);
        LOAD(mtl_filter_chain_set_param);
        LOAD(mtl_filter_chain_get_param);
        LOAD(mtl_filter_chain_set_active_pass_count);
        LOAD(mtl_filter_chain_get_active_pass_count);
        LOAD(mtl_filter_chain_free);

        #undef LOAD
        gInstance.instance_loaded = true;
    } else {
        gInstance = librashader_load_instance();
        if (!gInstance.instance_loaded) {
            if (error) *error = makeError(3, @"librashader_load_instance failed (dylib not on search path?)");
            return NO;
        }
    }

    gLoaded = YES;
    return YES;
}

+ (BOOL)isLibraryLoaded { return gLoaded; }

- (nullable instancetype)initWithPresetPath:(NSString *)presetPath
                               commandQueue:(id<MTLCommandQueue>)queue
                                      error:(NSError **)error {
    if (!gLoaded) {
        if (error) *error = makeError(10, @"librashader library not loaded; call +loadLibrary:error: first");
        return nil;
    }
    if ((self = [super init])) {
        libra_shader_preset_t preset = NULL;
        libra_error_t e = gInstance.preset_create(presetPath.fileSystemRepresentation, &preset);
        if (e != NULL) {
            if (error) *error = makeError(11, [@"preset_create: " stringByAppendingString:libraErrorMessage(e)]);
            return nil;
        }

        // Snapshot runtime parameters before the chain consumes the preset.
        libra_preset_param_list_t list = {0};
        e = gInstance.preset_get_runtime_params(&preset, &list);
        if (e != NULL) {
            if (error) *error = makeError(12, [@"preset_get_runtime_params: " stringByAppendingString:libraErrorMessage(e)]);
            gInstance.preset_free(&preset);
            return nil;
        }
        NSMutableArray *acc = [NSMutableArray arrayWithCapacity:list.length];
        for (uint64_t i = 0; i < list.length; i++) {
            const libra_preset_param_t *p = &list.parameters[i];
            [acc addObject:[[LRShaderParam alloc]
                initWithName:[NSString stringWithUTF8String:p->name]
                        desc:[NSString stringWithUTF8String:p->description]
                     initial:p->initial
                     minimum:p->minimum
                     maximum:p->maximum
                        step:p->step]];
        }
        gInstance.preset_free_runtime_params(list);
        _params = [acc copy];

        e = gInstance.mtl_filter_chain_create(&preset, queue, NULL, &_chain);
        if (e != NULL) {
            if (error) *error = makeError(13, [@"mtl_filter_chain_create: " stringByAppendingString:libraErrorMessage(e)]);
            gInstance.preset_free(&preset);
            return nil;
        }
        // mtl_filter_chain_create consumes the preset on success, so we don't free it here.
    }
    return self;
}

- (void)dealloc {
    if (_chain) {
        gInstance.mtl_filter_chain_free(&_chain);
        _chain = NULL;
    }
}

- (BOOL)renderInputTexture:(id<MTLTexture>)inputTexture
             outputTexture:(id<MTLTexture>)outputTexture
                  viewport:(MTLViewport)viewport
                frameCount:(NSUInteger)frameCount
             commandBuffer:(id<MTLCommandBuffer>)commandBuffer
                     error:(NSError **)error {
    libra_viewport_t vp;
    vp.x = (float)viewport.originX;
    vp.y = (float)viewport.originY;
    vp.width = (uint32_t)viewport.width;
    vp.height = (uint32_t)viewport.height;

    libra_error_t e = gInstance.mtl_filter_chain_frame(
        &_chain,
        commandBuffer,
        (size_t)frameCount,
        inputTexture,
        outputTexture,
        &vp,
        NULL,   // mvp = identity
        NULL    // frame opts
    );
    if (e != NULL) {
        if (error) *error = makeError(20, [@"mtl_filter_chain_frame: " stringByAppendingString:libraErrorMessage(e)]);
        return NO;
    }
    return YES;
}

- (NSArray<LRShaderParam *> *)parameters { return _params; }

- (BOOL)setParameter:(NSString *)name value:(float)value error:(NSError **)error {
    libra_error_t e = gInstance.mtl_filter_chain_set_param(&_chain, name.UTF8String, value);
    if (e != NULL) {
        if (error) *error = makeError(30, [@"mtl_filter_chain_set_param: " stringByAppendingString:libraErrorMessage(e)]);
        return NO;
    }
    return YES;
}

- (float)parameterValue:(NSString *)name {
    float v = 0.0f;
    gInstance.mtl_filter_chain_get_param(&_chain, name.UTF8String, &v);
    return v;
}

@end
