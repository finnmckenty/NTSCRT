#import "include/NtscRsBridge.h"
#import <dlfcn.h>

// C ABI of ntscrs-capi (Vendor/ntscrs-capi/src/lib.rs).
typedef struct NtscInstance NtscInstance;
typedef char *(*ntsc_descriptors_fn)(void);
typedef NtscInstance *(*ntsc_new_fn)(void);
typedef void (*ntsc_free_fn)(NtscInstance *);
typedef char *(*ntsc_to_json_fn)(const NtscInstance *);
typedef int32_t (*ntsc_from_json_fn)(NtscInstance *, const char *, char **);
typedef int32_t (*ntsc_process_fn)(const NtscInstance *, int32_t, uint8_t *,
                                   uint32_t, uint32_t, uint32_t, int64_t);
typedef void (*ntsc_string_free_fn)(char *);

static const int32_t kNtscBGRA8 = 1;

static struct {
    void *handle;
    ntsc_descriptors_fn descriptors;
    ntsc_new_fn new_instance;
    ntsc_free_fn free_instance;
    ntsc_to_json_fn to_json;
    ntsc_from_json_fn from_json;
    ntsc_process_fn process;
    ntsc_string_free_fn string_free;
} gNtsc;

static NSError *NtscError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"NTSCFilter"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

@implementation NTSCFilter {
    NtscInstance *_instance;
}

+ (BOOL)loadLibrary:(NSString *)dylibPath error:(NSError **)error {
    if (gNtsc.handle != NULL) return YES;

    void *handle = dlopen(dylibPath.UTF8String, RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        if (error) {
            *error = NtscError(1, [NSString stringWithFormat:@"dlopen failed: %s", dlerror()]);
        }
        return NO;
    }

#define LOAD(field, name)                                                     \
    gNtsc.field = (typeof(gNtsc.field))dlsym(handle, name);                   \
    if (gNtsc.field == NULL) {                                                \
        if (error) *error = NtscError(2, @"missing symbol " @name);           \
        dlclose(handle);                                                      \
        memset(&gNtsc, 0, sizeof(gNtsc));                                     \
        return NO;                                                            \
    }

    LOAD(descriptors, "ntsc_settings_descriptors_json")
    LOAD(new_instance, "ntsc_new")
    LOAD(free_instance, "ntsc_free")
    LOAD(to_json, "ntsc_settings_to_json")
    LOAD(from_json, "ntsc_settings_from_json")
    LOAD(process, "ntsc_process_frame")
    LOAD(string_free, "ntsc_string_free")
#undef LOAD

    gNtsc.handle = handle;
    return YES;
}

+ (BOOL)isLibraryLoaded {
    return gNtsc.handle != NULL;
}

+ (NSString *)settingsDescriptorsJSON {
    if (gNtsc.descriptors == NULL) return nil;
    char *json = gNtsc.descriptors();
    if (json == NULL) return nil;
    NSString *result = [NSString stringWithUTF8String:json];
    gNtsc.string_free(json);
    return result;
}

- (instancetype)init {
    if (gNtsc.new_instance == NULL) return nil;
    if ((self = [super init])) {
        _instance = gNtsc.new_instance();
        if (_instance == NULL) return nil;
    }
    return self;
}

- (void)dealloc {
    if (_instance != NULL && gNtsc.free_instance != NULL) {
        gNtsc.free_instance(_instance);
    }
}

- (NSString *)settingsJSON {
    if (_instance == NULL || gNtsc.to_json == NULL) return nil;
    char *json = gNtsc.to_json(_instance);
    if (json == NULL) return nil;
    NSString *result = [NSString stringWithUTF8String:json];
    gNtsc.string_free(json);
    return result;
}

- (BOOL)setSettingsJSON:(NSString *)json error:(NSError **)error {
    if (_instance == NULL || gNtsc.from_json == NULL) {
        if (error) *error = NtscError(3, @"library not loaded");
        return NO;
    }
    char *err = NULL;
    int32_t rc = gNtsc.from_json(_instance, json.UTF8String, &err);
    if (rc != 0) {
        if (error) {
            NSString *msg = err ? [NSString stringWithUTF8String:err]
                                : [NSString stringWithFormat:@"parse failed (%d)", rc];
            *error = NtscError(rc, msg);
        }
        if (err) gNtsc.string_free(err);
        return NO;
    }
    return YES;
}

- (BOOL)processBGRA8:(void *)data
               width:(NSUInteger)width
              height:(NSUInteger)height
            rowBytes:(NSUInteger)rowBytes
          frameIndex:(NSInteger)frameIndex {
    if (_instance == NULL || gNtsc.process == NULL) return NO;
    int32_t rc = gNtsc.process(_instance, kNtscBGRA8, (uint8_t *)data,
                               (uint32_t)width, (uint32_t)height,
                               (uint32_t)rowBytes, (int64_t)frameIndex);
    return rc == 0;
}

@end
