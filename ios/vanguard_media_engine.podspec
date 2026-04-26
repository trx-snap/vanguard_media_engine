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
  s.dependency       'UMF'
  s.platform         = :ios, '14.0'

  # Frameworks required for the GPU pipeline
  s.frameworks       = 'Metal', 'MetalKit', 'AVFoundation', 'CoreVideo', 'CoreMedia', 'VideoToolbox'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE'                                          => 'YES',
    # Expose the shared C++ src/ directory to the compiler
    'HEADER_SEARCH_PATHS'                                     => '$(inherited) $(PODS_TARGET_SRCROOT)/../src $(PODS_ROOT)/../../../../UMF/ios/Classes',
    # UMF path required: VanguardFileMediaSource.h imports VGMediaNode.h directly.
    'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES'  => 'YES',
    # Weak-link Flutter so the standalone test bundle loads on simulator without
    # a Runner host app. In production Flutter is always loaded first by Runner.
    'OTHER_LDFLAGS'                                           => '$(inherited) -weak_framework Flutter',
    # Compile C++ as C++17
    'OTHER_CPLUSPLUSFLAGS'                                    => '$(inherited) -std=c++17',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]'                    => 'i386'
  }

  # user_target_xcconfig: UMF header search path removed — UMF headers now
  # resolved via UMF.framework module (UMF local pod, P1A-G infrastructure).

  s.swift_version = '5.0'

  # Phase 1A test bundle — wires VGMasterClockTest, VGResourceAllocatorTest,
  # and VGMediaNodeConformanceTest into a CocoaPods-managed test target.
  # test_spec inherits the parent pod's HEADER_SEARCH_PATHS (UMF Classes/ included).
  # Frameworks: XCTest is implicit; Metal required by VGMediaNodeConformanceTest
  # (MTLCreateSystemDefaultDevice). ImageIO required by VGMediaNodeConformanceTest.
  s.test_spec 'Tests' do |ts|
    ts.requires_app_host = true
    ts.source_files  = [
      # Phase 1A test files
      'Tests/VGMasterClockTest.m',
      'Tests/VGResourceAllocatorTest.m',
      'Tests/VGMediaNodeConformanceTest.m',
      # Phase 1B test files (P1B-02: ObjC runtime lifecycle, P1B-04: Swift registry)
      'Tests/VGGraphRuntimeLifecycleTest.m',
      'Tests/VGSessionRegistryTest.swift',
      # Phase 4 P4-3: Runtime scheduler integration gate
      'Tests/VGRuntimeSchedulerIntegrationTest.m',
      # Phase 4 P4-4: Renderer GPU-sink entry point gate
      'Tests/VGRendererPresentEnvelopeTest.m',
      # Phase 4 P4-2: Scheduler skeleton lifecycle gate (P4-5 precondition)
      'Tests/VGGraphSchedulerSkeletonTest.m',
      # Phase 4 P4-2: Scheduler chain swap gate (P4-5 precondition)
      'Tests/VGSchedulerChainSwapTest.m'
    ]
    ts.frameworks    = 'Metal', 'ImageIO'
    ts.dependency    'UMF'
  end
end
