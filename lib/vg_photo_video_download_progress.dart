// vg_photo_video_download_progress.dart
// Vanguard Media Engine — public iOS PhotoKit iCloud download progress seam
//
// Public wrapper over VanguardChannelDispatcher's per-assetId registration
// for the native `onPhotoVideoDownloadProgress` callback, emitted by the iOS
// `downloadPhotoVideoReference` route while PhotoKit downloads an iCloud-only
// video (payload `{assetId: String, progress: num}`).
//
// App code must use this library instead of importing
// `src/channel/vanguard_channel_dispatcher.dart` directly. The dispatcher
// remains the sole owner of `setMethodCallHandler`; this file only registers
// and unregisters typed listeners on it.
//
// Lifecycle:
//   - `VGPhotoVideoDownloadProgress.listen` registers a listener for one
//     assetId and returns a handle. A second `listen` for the same assetId
//     replaces the first (its handle becomes stale).
//   - `handle.cancel()` unregisters. Idempotent and stale-safe: calling it
//     after a replacement or a second time is a no-op.
//   - Events for an assetId with no live listener are dropped by the
//     dispatcher; nothing is buffered, so a late native progress event after
//     cancel can never reach a consumer.

import 'src/channel/vanguard_channel_dispatcher.dart'
    show VanguardChannelDispatcher, VGPhotoVideoDownloadProgressSubscription;

/// Handle for one `onPhotoVideoDownloadProgress` registration.
///
/// Obtained from [VGPhotoVideoDownloadProgress.listen]; call [cancel] once
/// the download has reached a terminal state (success, failure, or cancel)
/// or the owning widget is disposed.
final class VGPhotoVideoDownloadProgressListener {
  VGPhotoVideoDownloadProgressListener._(this._subscription);

  final VGPhotoVideoDownloadProgressSubscription _subscription;
  bool _cancelled = false;

  /// PhotoKit localIdentifier this listener receives progress for.
  String get assetId => _subscription.assetId;

  /// Whether [cancel] has been called on this handle.
  bool get isCancelled => _cancelled;

  /// Unregisters this listener. Safe to call more than once and safe when a
  /// newer [VGPhotoVideoDownloadProgress.listen] for the same assetId has
  /// already replaced it (the newer registration is left untouched).
  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    VanguardChannelDispatcher.instance
        .unregisterPhotoVideoDownloadProgressListener(_subscription);
  }
}

/// Static entry point for iOS PhotoKit iCloud video download progress.
///
/// ```dart
/// final progress = VGPhotoVideoDownloadProgress.listen(
///   assetId: asset.id,
///   onProgress: (value) => setState(() => _progress = value),
/// );
/// try {
///   await bridge.downloadVideoReference(asset: asset);
/// } finally {
///   progress.cancel();
/// }
/// ```
final class VGPhotoVideoDownloadProgress {
  const VGPhotoVideoDownloadProgress._();

  /// Registers [onProgress] for native download progress of [assetId].
  ///
  /// [onProgress] receives values clamped to `[0.0, 1.0]`. Replaces any
  /// existing listener for the same [assetId].
  static VGPhotoVideoDownloadProgressListener listen({
    required String assetId,
    required void Function(double progress) onProgress,
  }) {
    final subscription = VanguardChannelDispatcher.instance
        .registerPhotoVideoDownloadProgressListener(
      assetId: assetId,
      onProgress: onProgress,
    );
    return VGPhotoVideoDownloadProgressListener._(subscription);
  }
}
