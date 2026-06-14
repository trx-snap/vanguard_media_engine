// VGMetalLibraryResolver.m
// Phase 9B-5 — Metal shader packaging repair for static-linkage CocoaPods builds.

#import "VGMetalLibraryResolver.h"
#import <os/log.h>

static os_log_t sLog(void) {
    static os_log_t l;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        l = os_log_create("com.connects.vanguard", "VGMetalLibraryResolver");
    });
    return l;
}

@implementation VGMetalLibraryResolver

+ (nullable id<MTLLibrary>)libraryForDevice:(id<MTLDevice>)device
                                     caller:(NSString *)caller {
    if (!device) {
        os_log_error(sLog(), "[VGMetalLibraryResolver] %{public}@: nil device", caller);
        return nil;
    }

    // --- Build candidate bundles in priority order ---
    NSMutableArray<NSBundle *> *candidates = [NSMutableArray array];

    // 1. Bundle that loaded this resolver class (works when pod is a dynamic framework).
    NSBundle *classBundle = [NSBundle bundleForClass:[VGMetalLibraryResolver class]];
    if (classBundle) {
        [candidates addObject:classBundle];
    }

    // 2. Main app bundle (static linkage / test host path).
    NSBundle *mainBundle = [NSBundle mainBundle];
    if (mainBundle && ![candidates containsObject:mainBundle]) {
        [candidates addObject:mainBundle];
    }

    // --- Try to locate VanguardMetal.bundle inside each candidate ---
    for (NSBundle *candidate in candidates) {
        // Look for VanguardMetal.bundle as a sub-bundle.
        NSURL *metalBundleURL = [candidate URLForResource:@"VanguardMetal"
                                            withExtension:@"bundle"];
        if (metalBundleURL) {
            NSBundle *metalBundle = [NSBundle bundleWithURL:metalBundleURL];
            if (metalBundle) {
                id<MTLLibrary> lib = [self _loadLibraryFromBundle:metalBundle
                                                           device:device
                                                           caller:caller];
                if (lib) {
                    os_log(sLog(),
                           "[VGMetalLibraryResolver] %{public}@: loaded from "
                           "VanguardMetal.bundle inside %{public}@",
                           caller,
                           candidate.bundlePath.lastPathComponent);
                    return lib;
                }
            }
        }

        // Fallback: try default.metallib directly inside the candidate's resourcePath.
        // This covers dynamic-framework mode where metallib is at the framework root.
        id<MTLLibrary> lib = [self _loadLibraryFromBundle:candidate
                                                   device:device
                                                   caller:caller];
        if (lib) {
            os_log(sLog(),
                   "[VGMetalLibraryResolver] %{public}@: loaded from bundle root %{public}@",
                   caller,
                   candidate.bundlePath.lastPathComponent);
            return lib;
        }
    }

    os_log_error(sLog(),
                 "[VGMetalLibraryResolver] %{public}@: FAILED — VanguardMetal.bundle "
                 "not found in any of %{public}lu candidate bundles. "
                 "Check podspec resource_bundles includes 'VanguardMetal' => "
                 "['Classes/**/*.metal'].",
                 caller,
                 (unsigned long)candidates.count);
    return nil;
}

// ---------------------------------------------------------------------------
// MARK: Private
// ---------------------------------------------------------------------------

/// Attempts newDefaultLibraryWithBundle: first (reads precompiled default.metallib
/// if present). Falls back to explicit newLibraryWithFile: pointing at
/// resourcePath/default.metallib for layouts where the bundle's Info.plist
/// does not register the metallib as default.
+ (nullable id<MTLLibrary>)_loadLibraryFromBundle:(NSBundle *)bundle
                                           device:(id<MTLDevice>)device
                                           caller:(NSString *)caller {
    // Strategy A: newDefaultLibraryWithBundle: — the standard path.
    NSError *err = nil;
    id<MTLLibrary> lib = [device newDefaultLibraryWithBundle:bundle error:&err];
    if (lib) {
        return lib;
    }

    // Strategy B: explicit file path — handles cases where newDefaultLibraryWithBundle:
    // fails to locate the metallib via Info.plist even though the file exists.
    NSString *metalLibPath = [bundle.resourcePath
                              stringByAppendingPathComponent:@"default.metallib"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:metalLibPath]) {
        NSError *fileErr = nil;
        lib = [device newLibraryWithFile:metalLibPath error:&fileErr];
        if (lib) {
            os_log(sLog(),
                   "[VGMetalLibraryResolver] %{public}@: Strategy B succeeded "
                   "(explicit file path in %{public}@)",
                   caller,
                   bundle.bundlePath.lastPathComponent);
            return lib;
        }
        os_log_error(sLog(),
                     "[VGMetalLibraryResolver] %{public}@: Strategy B FAILED for "
                     "%{public}@: %{public}@",
                     caller,
                     metalLibPath,
                     fileErr.localizedDescription);
    } else {
        os_log_info(sLog(),
                    "[VGMetalLibraryResolver] %{public}@: no default.metallib at "
                    "%{public}@ (Strategy A error: %{public}@)",
                    caller,
                    metalLibPath,
                    err.localizedDescription);
    }

    return nil;
}

@end
