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
  # .metal files are excluded from source_files and placed in resource_bundles
  # instead. With use_frameworks! :linkage => :static (required for
  # TensorFlowLiteC static xcframeworks), the pod compiles into a static archive.
  # Xcode compiles .metal files listed in source_files into an intermediate
  # default.metallib inside the pod's fake .framework in DerivedData — but that
  # intermediate is NOT copied into Runner.app at install time (only dynamic
  # frameworks are embedded). Placing .metal files in resource_bundles causes
  # Xcode to compile them into default.metallib inside VanguardMetal.bundle,
  # which CocoaPods correctly copies into Runner.app for all linkage modes.
  s.source_files     = 'Classes/**/*.{swift,h,m,mm}'
  s.private_header_files = [
    'Classes/VGTimelineStateSnapshot.h',
    # Phase 10-C Slice D: audio preview runtime — package-internal only.
    'Classes/VanguardAudioPreviewRuntime.h',
    # Audio Modularity M2A: track descriptor — package-internal only.
    'Classes/VGAudioPreviewTrackDescriptor.h',
    # Audio Slice J: keyframe automation — package-internal only.
    'Classes/VGAudioPreviewVolumeKeyframe.h',
    'Classes/VGAudioPreviewKeyframeNormalizer.h',
    'Classes/VGAudioPreviewEnvelopeEvaluator.h',
    'Classes/VGAudioPreviewAutomationTimer.h',
    'Classes/VGAudioPreviewAutomationCoordinator.h',
    # VanguardGraphRuntime+AudioPreview.h is module-visible (not private_header_files)
    # so Swift can call setAudioSidecarPlan:timelineDuration:completion: directly.
  ]

  # Phase 9B — model asset bundle.
  # selfie_multiclass_256x256.tflite: Apache 2.0 (Google MediaPipe Solutions).
  # SHA256: c6748b1253a99067ef71f7e26ca71096cd449baefa8f101900ea23016507e0e0
  # Bundled under 'VanguardMLModels' so the resource resolver can locate it
  # via NSBundle(identifier:) or by walking the main bundle's path.
  #
  # Metal shader bundle — VanguardMetal.bundle:
  # VanguardEffects.metal + VanguardCompositor.metal are compiled by Xcode into
  # default.metallib inside this bundle. VGMetalLibraryResolver locates it at
  # runtime via NSBundle(identifier:) or main bundle path walk.
  s.resource_bundles = {
    'VanguardMLModels' => ['Assets/**/*.tflite'],
    'VanguardMetal'    => ['Classes/**/*.metal']
  }

  s.dependency       'Flutter'
  s.dependency       'UMF'
  # Phase 9B — TFLite C runtime + Metal GPU delegate (prebuilt dynamic xcframeworks).
  #
  # TensorFlowLiteC is the dynamic xcframework variant of the TFLite runtime.
  # It is compatible with Flutter's use_frameworks! Podfile directive.
  #
  # TensorFlowLiteObjC (the high-level ObjC wrapper pod) is NOT declared here
  # because it is a source-code-only pod that compiles to a static library,
  # which conflicts with use_frameworks! in the Flutter example Podfile.
  # The VGLiteRTMaskProvider implementation (Phase 9B-1) will use the
  # TFLite C API directly via TensorFlowLiteC headers, which expose a complete
  # Objective-C-compatible C interface for interpreter lifecycle and tensor I/O.
  #
  # TensorFlowLiteC/Metal adds the prebuilt GPU delegate xcframework
  # (TensorFlowLiteCMetal.xcframework) required for < 25 ms live-preview
  # inference. CPU fallback (~140 ms) is forbidden for real-time video.
  s.dependency       'TensorFlowLiteC', '~> 2.14'
  s.dependency       'TensorFlowLiteC/Metal', '~> 2.14'
  s.static_framework = true
  s.platform         = :ios, '14.0'

  # Frameworks required for the GPU pipeline + Vision (Phase 4C face detection, DEC-61)
  s.frameworks       = 'Metal', 'MetalKit', 'AVFoundation', 'CoreVideo', 'CoreMedia', 'VideoToolbox', 'Vision'

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
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]'                    => 'i386',
    # Tie Objective-C and Swift camera graph flags together with standard Xcode resolution
    'VG_USE_CAMERA_GRAPH'                                     => '1',
    'GCC_PREPROCESSOR_DEFINITIONS'                            => '$(inherited) VG_USE_CAMERA_GRAPH=$(VG_USE_CAMERA_GRAPH) VG_USE_V2_GRAPH=1',
    'OTHER_SWIFT_FLAGS_0'                                     => '$(inherited)',
    'OTHER_SWIFT_FLAGS_1'                                     => '$(inherited) -DVG_USE_CAMERA_GRAPH -DVG_USE_V2_GRAPH',
    'OTHER_SWIFT_FLAGS'                                       => '$(OTHER_SWIFT_FLAGS_$(VG_USE_CAMERA_GRAPH))'
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
      # Phase 4 P4-Remote: URL resolution unit tests
      'Tests/VanguardURLResolutionTest.swift',
      # Phase 4 P4-3: Runtime scheduler integration gate
      'Tests/VGRuntimeSchedulerIntegrationTest.m',
      # Phase 4 P4-4: Renderer GPU-sink entry point gate
      'Tests/VGRendererPresentEnvelopeTest.m',
      # Phase 4 P4-2: Scheduler skeleton lifecycle gate (P4-5 precondition)
      'Tests/VGGraphSchedulerSkeletonTest.m',
      # Phase 4 P4-2: Scheduler chain swap gate (P4-5 precondition)
      'Tests/VGSchedulerChainSwapTest.m',
      # Phase 4 P4-5: Scheduler frame delivery gate (P4-5 mandatory gate)
      'Tests/VGSchedulerFrameDeliveryTest.m',
      # Phase 4 P4-5: Scheduler filter execution gate (P4-5 mandatory gate)
      'Tests/VGSchedulerFilterExecutionTest.m',
      # Phase 4 P4-6: Legacy renderer path smoke test (camera smoke substitute)
      'Tests/VGRendererLegacyPathSmokeTest.m',
      # Phase 4 P4-7D: Pool unification, sizing, and budget validation gates
      'Tests/VGPoolUnificationTest.m',
      'Tests/VGPoolSizingTest.m',
      'Tests/VGPoolBudgetTest.m',
      # Phase 4 P4-7D: Pool pressure behavior hardening gate
      'Tests/VGPoolPressureBehaviorTest.m',
      # Phase 4 P4-8A: Pool drain / GPU fence budget accounting gate
      'Tests/VGPoolDrainTest.m',
      # Phase 4 P4-8B: GPU fence release timing gate (plan:200)
      'Tests/VGPoolReleaseTimingTest.m',
      # Phase 4 P4-8B: 10-cycle churn + phys_footprint leak gate (plan:200, RR-29)
      'Tests/VGSessionChurnPoolLeakTest.m',
      # Phase 4 P4-9: Cost-budget thermal policy gate — 3-node Phase 3 equivalence (plan:365, RR-33)
      'Tests/VGCostBudgetThermalTest.m',
      # Phase 4 P4-9: Cost-budget future-node scaling gate (plan:366, RR-33)
      'Tests/VGCostBudgetFutureNodeTest.m',
      # Phase 4 Pre-4A: Pixel parity test infrastructure
      'Tests/VGSchedulerParityTest.m',
      'Tests/VGAdapterParityTest.m',
      # Phase 4 Batch 4B: V2 setFilterChain hot-swap gate
      'Tests/VGSchedulerV2ChainSwapTest.m',
      # Phase 4C: V2 thermal policy gate
      'Tests/VGSchedulerV2ThermalTest.m',
      # Phase 5B: Encoder backward compatibility and hardening gate
      'Tests/VGEncoderBackwardCompatTest.m',
      # Phase 5C-1: Pull export scheduler skeleton gate
      'Tests/VGExportSchedulerPullLoopTest.m',
      # Phase 5C-2: Pull export file source gate
      'Tests/VGExportFileSourceNodePullTest.m',
      # Phase 5C-3: Pull export graph factory gate
      'Tests/VGExportGraphFactoryTest.m',
      # Phase 5C-4: Pull export encoder sink gate
      'Tests/VGVideoEncoderSinkNodeTest.m',
      # Phase 5C-5: Full video export session integration
      'Tests/VGVideoExportSessionTest.m',
      # Phase 5D-2: Image encoder sink gate
      'Tests/VGImageEncoderSinkNodeTest.m',
      # Phase 5D-3: Image export session integration gate
      'Tests/VGImageExportSessionTest.m',
      # Phase 5E-2: Audio-only export gate
      'Tests/VGAudioOnlyExporterTest.m',
      # Phase 6A-1: Camera graph foundation unit tests
      'Tests/VGFanOutSinkTest.m',
      'Tests/VGCameraGraphFactoryTest.m',
      # Phase 6A-2: Camera graph session unit tests
      'Tests/VGCameraGraphSessionTest.m',
      # Phase 6A-3C-1: Camera graph filter chain integration unit tests
      'Tests/VGCameraFilterChainTest.m',
      # Phase 6A-3D-1: Camera resource contract unit tests
      'Tests/VGCameraResourceContractTest.m',
      # Phase 6A-3D-2: Camera filter construction unit tests (Beauty V1)
      'Tests/VGCameraFilterConstructionTest.m',
      # Phase 9A: Provider-backed segmentation architecture contract tests
      'Tests/VGSegmentationNodeProviderTest.m',
      # Phase 9B: Model asset integrity smoke test
      'Tests/VGMLModelAssetTest.m',
      # Phase 9B-1: Face+Neck beauty mask policy unit tests (synthetic tensors, no TFLite API)
      'Tests/VGFaceNeckBeautyMaskPolicyTest.m',
      # Phase 9B-2: LiteRT mask provider tests (real bundled model + synthetic CVPixelBuffer)
      'Tests/VGLiteRTMaskProviderTest.m',
      # Phase 9B-3: Camera graph factory gate test (gate-OFF path, VGHeuristicMaskProvider default)
      'Tests/VGCameraGraphFactoryGateTest.m',
      # Phase 10-C-3L.1D: Spatial transform filter node tests
      'Tests/VGTransformFilterNodeTest.m',
      # Phase 10-C Slice A: Audio export static zero-gain correction gate
      'Tests/VGAudioExportMuxerTest.m',
      # Phase 10-C Slice C: timeline-state snapshot contract tests
      'Tests/VGTimelineSnapshotTest.m',
      # Phase 10-C Slice D: audio preview runtime deterministic unit tests
      'Tests/VGAPrTestCollaborators.m',
      'Tests/VanguardAudioPreviewRuntimeTest.m',
      'Tests/VanguardAudioPreviewRuntimeTest_Prepare.m',
      'Tests/VanguardAudioPreviewRuntimeTest_StateTransitions.m',
      'Tests/VanguardAudioPreviewRuntimeTest_SourceRange.m',
      'Tests/VanguardAudioPreviewRuntimeTest_Rescheduling.m',
      'Tests/VanguardAudioPreviewRuntimeTest_Teardown.m',
      'Tests/VanguardAudioPreviewRuntimeTest_SliceF_Arbitration.m',
      'Tests/VanguardAudioPreviewRuntimeTest_SliceF_Races.m',
      'Tests/VanguardAudioPreviewRuntimeTest_SliceF_Sequences.m',
      'Tests/VanguardAudioPreviewRuntimeTest_SliceE.m',
      # Audio Slice J: preview keyframe automation tests
      'Tests/VanguardAudioPreviewRuntimeTest_SliceJ_Normalization.m',
      'Tests/VanguardAudioPreviewRuntimeTest_SliceJ_Evaluator.m',
      'Tests/VanguardAudioPreviewRuntimeTest_SliceJ_Automation.m',
      'Tests/VanguardAudioPreviewRuntimeTest_SliceJ_TimerProduction.m',
      # Audio Slice K: four-scenario preview proof (two-slot architecture)
      'Tests/VanguardAudioPreviewRuntimeTest_SliceK_Scenarios.m',
      # Audio Slice L: preview/export parity gate tests
      'Tests/VanguardAudioParity_SliceL_Tests.m',
      # Audio Slice M: recording contract and minimal native capture tests
      'Tests/VanguardAudioRecorderTests.m'
    ]
    ts.frameworks    = 'Metal', 'ImageIO', 'CoreImage', 'AVFoundation'
    ts.dependency    'UMF'
  end

end
