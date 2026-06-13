// VGMLModelBundle.m
// Phase 9B — Model resource resolver for VanguardMLModels.bundle.

#import "VGMLModelBundle.h"
#import <os/log.h>

static os_log_t sLog(void) {
    static os_log_t l;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = os_log_create("com.connects.vanguard", "VGMLModelBundle"); });
    return l;
}

@implementation VGMLModelBundle

+ (nullable NSURL *)URLForModelNamed:(NSString *)modelName {
    if (modelName.length == 0) return nil;

    NSBundle *modelBundle = [self _VanguardMLModelsBundle];
    if (!modelBundle) {
        os_log_error(sLog(), "VGMLModelBundle: VanguardMLModels.bundle not found");
        return nil;
    }

    NSURL *url = [modelBundle URLForResource:modelName withExtension:@"tflite"];
    if (!url) {
        os_log_error(sLog(), "VGMLModelBundle: asset '%@.tflite' not found in bundle", modelName);
    }
    return url;
}

// ─── Private ─────────────────────────────────────────────────────────────────

/// Locate VanguardMLModels.bundle. The search order is:
///   1. The bundle that contains this class (pod framework bundle — use_frameworks! path).
///   2. The main bundle (non-framework static lib path or unit-test host app).
///
/// The result is cached after the first successful lookup.
+ (nullable NSBundle *)_VanguardMLModelsBundle {
    static NSBundle *cachedBundle = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *const bundleName = @"VanguardMLModels";

        // 1. Look inside the bundle that owns this class (framework path).
        NSBundle *classBundle = [NSBundle bundleForClass:[VGMLModelBundle class]];
        NSURL *url = [classBundle URLForResource:bundleName withExtension:@"bundle"];
        if (url) {
            cachedBundle = [NSBundle bundleWithURL:url];
            return;
        }

        // 2. Fallback: walk main bundle (static-lib or test host path).
        url = [[NSBundle mainBundle] URLForResource:bundleName withExtension:@"bundle"];
        if (url) {
            cachedBundle = [NSBundle bundleWithURL:url];
            return;
        }

        // 3. Not found — cachedBundle remains nil; callers receive nil URLs.
        os_log_error(sLog(),
                     "VGMLModelBundle: VanguardMLModels.bundle not found in class bundle "
                     "(%{public}@) or main bundle",
                     classBundle.bundlePath);
    });
    return cachedBundle;
}

@end
