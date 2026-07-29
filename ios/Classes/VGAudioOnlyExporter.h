// VGAudioOnlyExporter.h
// vanguard_media_engine — Phase 5E-2
//
// VGAudioOnlyExporter is a single-use offline audio-only export service.
//
// Architecture:
//   Descriptor/service path (DEC-V2-067). NOT a graph path.
//
//   VGAudioExportProfile (descriptor)
//     + source AVAsset
//     + output URL
//   → VGAudioOnlyExporter (offline service)
//     → AVAssetReader / AVAssetReaderTrackOutput (read + decompress to PCM)
//     → AVAssetWriterInput / AVAssetWriter (encode + mux M4A or WAV)
//     → VGAudioExportManifest (result)
//
// Single-use:
//   startWithCompletion: may be called once. Second call is a no-op.
//   cancel is safe from any thread at any time.
//   dealloc calls cancel as a safety net.
//
// Threading:
//   startWithCompletion: may be called from any thread.
//   Export runs on a private serial dispatch queue.
//   requestMediaDataWhenReadyOnQueue uses the same private queue.
//   Completion fires on the private queue (background).
//   cancelWriting is called synchronously on the export queue to guarantee
//   quiescence before terminal completion fires.
//   cancelReading stops reader from producing more samples.
//
// Supported formats:
//   M4A/AAC: AVFileTypeAppleM4A + kAudioFormatMPEG4AAC
//   WAV/PCM: AVFileTypeWAVE + kAudioFormatLinearPCM (16-bit integer)
//
// Forbidden:
//   No VGGraphSchedulerV2
//   No VGExportScheduler
//   No VGFrameSink / VGFrameEnvelope
//   No VGGraphDescriptor / VGGraphValidator / VGGraphPlanner
//   No VGGraphExecutionContext
//   No VGVideoEncoderSinkNode / VGImageEncoderSinkNode
//   No camera/playback/runtime coupling
//   No real-time audio effects, voice effects, generative audio,
//     beat sync, timeline mixing, volume automation, fades, or time-remap
//
// Phase 5E-2: AVAssetReader/Writer offline pipeline. No graph.

#pragma once

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UMF/VGAudioExportProfile.h>
#import <UMF/VGAudioExportManifest.h>

NS_ASSUME_NONNULL_BEGIN

// ─── Error domain ─────────────────────────────────────────────────────────────

/// Error domain for all VGAudioOnlyExporter errors.
FOUNDATION_EXPORT NSString * const VGAudioOnlyExporterErrorDomain;

// ─── Error codes ──────────────────────────────────────────────────────────────

typedef NS_ENUM(NSInteger, VGAudioOnlyExporterErrorCode) {
    /// Source asset URL does not exist or asset cannot be loaded.
    VGAudioOnlyExporterErrorInvalidSource       = 1,
    /// Output URL is nil, unwritable, or in a nonexistent directory.
    VGAudioOnlyExporterErrorInvalidOutputURL    = 2,
    /// Profile is nil or contains invalid parameters.
    VGAudioOnlyExporterErrorInvalidProfile      = 3,
    /// Source asset contains no audio track.
    VGAudioOnlyExporterErrorNoAudioTrack        = 4,
    /// Codec is not supported (e.g. VGAudioCodecOpus on iOS < 15).
    VGAudioOnlyExporterErrorUnsupportedCodec    = 5,
    /// Container/codec combination is unsupported (e.g. AAC in WAV).
    VGAudioOnlyExporterErrorUnsupportedFormat   = 6,
    /// AVAssetReader setup or output creation failed.
    VGAudioOnlyExporterErrorReaderSetup         = 7,
    /// AVAssetWriter setup or input creation failed.
    VGAudioOnlyExporterErrorWriterSetup         = 8,
    /// AVAssetReader failed to start reading.
    VGAudioOnlyExporterErrorReaderStart         = 9,
    /// AVAssetWriter failed to start writing.
    VGAudioOnlyExporterErrorWriterStart         = 10,
    /// AVAssetWriter failed during or after writing (check NSUnderlyingErrorKey).
    VGAudioOnlyExporterErrorWriterFailed        = 11,
    /// Output file is missing or empty after a successful write.
    VGAudioOnlyExporterErrorOutputMissing       = 12,
    /// Export was cancelled.
    VGAudioOnlyExporterErrorCancelled           = 13,
    /// AVAssetReader failed at runtime during the sample pump (after startReading
    /// succeeded). Distinct from ReaderSetup/ReaderStart — maps to readFailure.
    VGAudioOnlyExporterErrorReaderRuntimeFailure = 14,
};

// ─── VGAudioOnlyExporter ──────────────────────────────────────────────────────

/// Single-use offline audio-only export service.
///
/// Reads audio from a source AVAsset via AVAssetReader, encodes and muxes
/// to M4A/AAC or WAV/PCM via AVAssetWriter, and returns a VGAudioExportManifest
/// reflecting the actual output file metadata.
///
/// This class does NOT participate in any UMF V2 graph topology.
/// It is a descriptor-driven standalone offline service.
@interface VGAudioOnlyExporter : NSObject

// ─── Designated initializer ───────────────────────────────────────────────────

/// Initialize the audio export service for full-range extraction.
///
/// Does NOT start export — call startWithCompletion: to begin.
///
/// @param asset      Source AVAsset with at least one audio track.
/// @param profile    Audio export configuration (codec, bitrate, sample rate,
///                   channels, container format). Must be non-nil.
/// @param outputURL  Destination file URL. Any existing file is deleted before
///                   writing. Parent directory must exist.
///
/// All existing callers use this initializer; it is preserved unchanged.
- (instancetype)initWithAsset:(AVAsset *)asset
                      profile:(VGAudioExportProfile *)profile
                    outputURL:(NSURL *)outputURL NS_DESIGNATED_INITIALIZER;

/// Initialize the audio export service with an optional trim range.
///
/// Phase 10-C Slice T: cohesive trim API added alongside the existing
/// full-range initializer. All existing callers continue to use the
/// initWithAsset:profile:outputURL: initializer above.
///
/// @param asset      Source AVAsset with at least one audio track.
/// @param profile    Audio export configuration. Must be non-nil.
/// @param outputURL  Destination file URL. Parent directory must exist.
/// @param trimRange  CMTimeRange to apply to the AVAssetReader. Pass
///                   CMTimeRangeMake(kCMTimeZero, kCMTimePositiveInfinity)
///                   for full-range extraction.
///
/// The range is validated before starting: start must be >= 0 and
/// duration must be positive. An invalid range causes startWithCompletion:
/// to fire completion with VGAudioOnlyExporterErrorReaderSetup.
- (instancetype)initWithAsset:(AVAsset *)asset
                      profile:(VGAudioExportProfile *)profile
                    outputURL:(NSURL *)outputURL
                    trimRange:(CMTimeRange)trimRange;

/// Unavailable. Use initWithAsset:profile:outputURL: or initWithAsset:profile:outputURL:trimRange:.
- (instancetype)init NS_UNAVAILABLE;

// ─── State ────────────────────────────────────────────────────────────────────

/// YES while the export is in progress (after startWithCompletion:, before completion).
@property (nonatomic, readonly, getter=isExporting) BOOL exporting;

/// YES after cancel has been called (even before any in-flight work acknowledges it).
@property (nonatomic, readonly, getter=isCancelled) BOOL cancelled;

/// YES after the completion block has been fired exactly once.
@property (nonatomic, readonly, getter=isFinished) BOOL finished;

// ─── Export control ───────────────────────────────────────────────────────────

/// Start the export asynchronously.
///
/// Reads all audio samples from the source AVAsset, encodes them per
/// the profile, and writes to outputURL. Fires completion exactly once.
///
/// On success: manifest is non-nil, error is nil.
/// On failure: manifest is nil, error describes the failure.
/// Completion fires on a background queue.
///
/// Single-use: if startWithCompletion: has already been called, or if
/// cancel was called before start, this call fires completion with the
/// appropriate result and does not start the pipeline again.
- (void)startWithCompletion:(void (^)(VGAudioExportManifest * _Nullable manifest,
                                      NSError * _Nullable error))completion;

/// Cancel the export. Atomic. Safe from any thread at any time.
///
/// If export has not started: marks the session cancelled so that a
/// subsequent startWithCompletion: fires completion with a cancellation error.
///
/// If export is in progress: sets the cancellation flag; the sample pump
/// checks the flag at each iteration and exits safely.
///
/// If export has finished: no-op.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
