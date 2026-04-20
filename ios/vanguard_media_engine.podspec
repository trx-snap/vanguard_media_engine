Pod::Spec.new do |s|
  s.name             = 'vanguard_media_engine'
  s.version          = '0.0.1'
  s.summary          = 'Vanguard GPU Media Engine – hardware-accelerated C++/Metal NLE for Flutter.'
  s.description      = 'Platform-agnostic NLE package powering GPU preview (Metal/OpenGL) and hardware encoding (VideoToolbox/MediaCodec) for the Connects story composer.'
  s.homepage         = 'https://github.com/connects-app/vanguard_media_engine'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Connects' => 'dev@connects.app' }

  s.source           = { :path => '.' }

  # Classes/**  — Swift/ObjC/Metal native bindings
  # VanguardFFIBridge.mm — forwarder that #includes the C++ core (../src/)
  # The .mm extension compiles the C++ source as Objective-C++ so the FFI symbols
  # (vanguard_engine_create etc.) are compiled into the vanguard_media_engine.framework.
  # Because the app uses use_frameworks!, this framework is a dylib loaded at launch.
  # DynamicLibrary.process() finds symbols in all loaded dylibs — no linker flags needed.
  s.source_files     = 'Classes/**/*.{swift,h,m,mm,metal}'

  s.dependency       'Flutter'
  s.platform         = :ios, '14.0'

  # Frameworks required for the GPU pipeline
  s.frameworks       = 'Metal', 'MetalKit', 'AVFoundation', 'CoreVideo', 'CoreMedia', 'VideoToolbox'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE'                                          => 'YES',
    # Expose the shared C++ src/ directory to the compiler
    # UMF Classes/ added so VGMasterClock.h is found during pod compilation.
    # PODS_ROOT = Pods/ (4 levels up reaches connects_app/packages/UMF/ios/Classes).
    'HEADER_SEARCH_PATHS'                                     => '$(inherited) $(PODS_TARGET_SRCROOT)/../src $(PODS_ROOT)/../../../../UMF/ios/Classes',
    # UMF headers (VGMediaNode.h, VGMasterClock.h) live in a separate package and
    # cannot be in the vanguard_media_engine module map. Allow the import.
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES'  => 'YES',
    # Compile C++ as C++17
    'OTHER_CPLUSPLUSFLAGS'                                    => '$(inherited) -std=c++17',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]'                    => 'i386'
  }

  # user_target_xcconfig: propagates UMF Classes to the Runner target's header search
  # path so the clang module compiler (which processes the vanguard_media_engine module
  # umbrella in the Runner build context) can resolve VGMasterClock.h during module
  # validation. Required since P1A-04 added VGMasterClock.h as a transitive include.
  s.user_target_xcconfig = {
    'HEADER_SEARCH_PATHS' => '$(inherited) $(PODS_ROOT)/../../../../UMF/ios/Classes'
  }

  s.swift_version = '5.0'

  # Phase 1A test bundle — wires VGMasterClockTest, VGResourceAllocatorTest,
  # and VGMediaNodeConformanceTest into a CocoaPods-managed test target.
  # test_spec inherits the parent pod's HEADER_SEARCH_PATHS (UMF Classes/ included).
  # Frameworks: XCTest is implicit; Metal required by VGMediaNodeConformanceTest
  # (MTLCreateSystemDefaultDevice). ImageIO required by VGMediaNodeConformanceTest.
  s.test_spec 'Tests' do |ts|
    ts.source_files  = [
      # Phase 1A test files only — other Tests/ files have pre-existing
      # compile errors (missing imports) and are excluded from this bundle.
      'Tests/VGMasterClockTest.m',
      'Tests/VGResourceAllocatorTest.m',
      'Tests/VGMediaNodeConformanceTest.m'
    ]
    ts.frameworks    = 'Metal', 'ImageIO'
    ts.pod_target_xcconfig = {
      'HEADER_SEARCH_PATHS' => '$(inherited) $(PODS_ROOT)/../../../../UMF/ios/Classes'
    }
  end
end
