// VanguardVideoToolboxEncoder.h
// Phase 5B: iOS Hardware Encoder via VideoToolbox — Dual-Mode Hardening
//
// Accepts raw CVPixelBuffer frames from the Metal compositor (or export
// frame pump) and encodes them directly on Apple's VideoToolbox hardware.
// Supports both realtime camera recording and offline export modes.

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <UMF/VGExportProfile.h>  // VGEncoderUsage enum (Phase 5A)

NS_ASSUME_NONNULL_BEGIN

/// Called for each encoded NAL unit (camera/realtime path).
/// Provides Annex-B formatted data, PTS, key-frame flag, and optional error.
typedef void (^VanguardEncodedPacketHandler)(NSData *_Nullable nalData,
                                             CMTime pts, BOOL isKeyFrame,
                                             NSError *_Nullable error);

@interface VanguardVideoToolboxEncoder : NSObject

/// YES while the VTCompressionSession is created and not yet invalidated.
@property(nonatomic, readonly) BOOL isReady;

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Initializers
// ─────────────────────────────────────────────────────────────────────────────

/// Phase 5B designated initializer — dual-mode encoder.
///
/// Creates a VTCompressionSession for the specified codec, profile, and usage.
/// VT properties are set according to §A.1 of 01_encoder_export_foundation.md.
///
/// @param width          Frame width in pixels (e.g. 1080)
/// @param height         Frame height in pixels (e.g. 1920)
/// @param bitrate        Target average bitrate in bits/second
/// @param fps            Frame rate (e.g. 30)
/// @param codecType      kCMVideoCodecType_H264 or kCMVideoCodecType_HEVC
/// @param profileLevel   VT profile-level string (e.g. kVTProfileLevel_H264_Baseline_4_0)
/// @param usage          VGEncoderUsageRealtime or VGEncoderUsageOffline
/// @param handler        Called for each encoded NAL unit (camera path). May be nil.
- (instancetype)initWithWidth:(int)width
                       height:(int)height
                      bitrate:(int)bitrate
                          fps:(int)fps
                    codecType:(CMVideoCodecType)codecType
                 profileLevel:(NSString *)profileLevel
                        usage:(VGEncoderUsage)usage
                packetHandler:(nullable VanguardEncodedPacketHandler)handler
    NS_DESIGNATED_INITIALIZER;

/// Phase 4 backward-compatible initializer — realtime / camera path.
///
/// Convenience wrapper calling the 8-arg designated init with:
///   codecType = kCMVideoCodecType_H264
///   profileLevel = kVTProfileLevel_H264_Baseline_4_0
///   usage = VGEncoderUsageRealtime
///
/// All existing call sites in VanguardMediaEnginePlugin.swift use this form.
/// @param width    Frame width in pixels (e.g. 1080)
/// @param height   Frame height in pixels (e.g. 1920)
/// @param bitrate  Target average bitrate in bits/second (e.g. 10_000_000)
/// @param fps      Frame rate (e.g. 30)
/// @param handler  Called for each encoded NAL unit
- (instancetype)initWithWidth:(int)width
                       height:(int)height
                      bitrate:(int)bitrate
                          fps:(int)fps
                packetHandler:(VanguardEncodedPacketHandler)handler;

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Export Handler Properties (Phase 5B, used by 5C sink)
// ─────────────────────────────────────────────────────────────────────────────

/// Called from vtOutputCallback for EVERY VT callback: success, drop, or error.
/// Does NOT receive CMSampleBufferRef. Used by VGVideoEncoderSinkNode to signal
/// the admission semaphore. Separate from packetHandler (camera NAL path).
///
/// Thread safety: atomic, copy — safe to set/nil from any thread.
@property(atomic, copy, nullable)
    void (^frameCompletionHandler)(OSStatus status, VTEncodeInfoFlags infoFlags);

/// Called from vtOutputCallback ONLY when status == noErr and sampleBuffer != NULL.
/// Receives the encoded CMSampleBufferRef for AVAssetWriter append.
/// Separate from packetHandler (camera NAL path).
///
/// Thread safety: atomic, copy — safe to set/nil from any thread.
/// Ownership: caller must CFRetain before dispatch_async if crossing a queue.
@property(atomic, copy, nullable)
    void (^encodedSampleHandler)(CMSampleBufferRef sampleBuffer);

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Encoding
// ─────────────────────────────────────────────────────────────────────────────

/// Submit a decoded frame (from AVAssetReader or Metal render pass) for encoding.
/// No-op if the session has been invalidated.
- (void)encodePixelBuffer:(CVPixelBufferRef)pixelBuffer
         presentationTime:(CMTime)pts;

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Lifecycle
// ─────────────────────────────────────────────────────────────────────────────

/// Flush all pending frames synchronously.
/// Calls completeFrames internally. Return value discarded for backward compat.
- (void)finish;

/// Backward-compatible teardown. Calls invalidateOnce then clears isReady.
/// Does NOT CFRelease the session — that is dealloc's responsibility.
- (void)invalidate;

/// Phase 5B: Idempotent session invalidation. Thread-safe via atomic CAS.
///
/// - Calls VTCompressionSessionInvalidate exactly once (CAS-protected).
/// - Does NOT CFRelease the session (_session released only in dealloc).
/// - Does NOT set _session = NULL.
/// - Safe to call from any thread, any number of times.
- (void)invalidateOnce;

/// Phase 5B: Flush all pending frames and return completion status.
///
/// Blocks until all pending VT callbacks have fired.
/// @returns YES  All frames completed normally.
/// @returns NO   Session was invalidated before or during the call (terminal).
///               Treat NO as a signal that no further callback-driven work will arrive.
- (BOOL)completeFrames;

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Runtime Properties
// ─────────────────────────────────────────────────────────────────────────────

/// G-04: Update the encoder's target bitrate at runtime (thermal degradation).
/// Uses VTSessionSetProperty — takes effect on the next encode call.
/// Applies usage-conditional DataRateLimits multiplier (1.5× realtime, 2.5× offline).
/// @param kbps  New target bitrate in kilobits/second (e.g. 4000 = 4Mbps).
- (void)setBitrateKbps:(int)kbps;

/// P3-T3: Pre-warms the VTCompressionSession without submitting any frames.
/// Call at startCamera so the hardware encoder is ready before the user taps
/// Record. Idempotent. The first 5 real encode calls are discarded automatically.
- (void)prewarm;

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Diagnostics (P5-C)
// ─────────────────────────────────────────────────────────────────────────────

/// Monotonic count of frames that completed VTCompressionOutputCallback.
/// Ground truth for encoder flush completeness. Atomically readable from any thread.
@property(atomic, readonly) int64_t vtCallbackCount;

/// Phase 5B: Monotonic count of vtOutputCallback bodies that have FULLY returned
/// (after both handlers have been invoked). Used by VGVideoEncoderSinkNode for
/// callback body drain verification before handler nil-out.
/// Incremented at the LAST line of vtOutputCallback.
@property(nonatomic, readonly) int64_t callbackBodiesReturned;

/// P5-C: Reset the vtCallbackCount to zero before starting a flush-completeness
/// test. Call before startRecording to get a per-session count.
- (void)resetCallbackCount;

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Internal (ARC bridge)
// ─────────────────────────────────────────────────────────────────────────────

/// Internal: called by the VTCompressionOutputCallback C function.
/// Must be visible to ARC for the __bridge cast to work correctly.
- (void)_handleEncodedSample:(CMSampleBufferRef)sampleBuffer;

@end

NS_ASSUME_NONNULL_END
