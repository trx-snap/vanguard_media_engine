// Copyright 2026, Connects. All rights reserved.
// Pure Dart — no dart:io, no dart:ui, no Flutter geometry types.

/// Validated local/offline video source for Vanguard Duet.
///
/// The v1 engine takes a source video that is **already local/offline**.
/// Remote downloading, network caching, and backend admission are handled by
/// downstream app services before invoking the engine.
///
/// Filesystem existence and codec validation are deferred to the platform
/// session layer; this class only validates the path format.
class VGDuetSource {
  /// The absolute local file path to the source video.
  final String filePath;

  const VGDuetSource._({required this.filePath});

  /// Creates a [VGDuetSource] from a validated local file path.
  ///
  /// Throws [ArgumentError] if:
  /// - [filePath] is empty or blank.
  /// - [filePath] does not end with `.mp4` or `.mov` (case-insensitive).
  ///
  /// Does **not** check filesystem existence synchronously. Existence and
  /// codec validation belong to the platform session layer.
  factory VGDuetSource.localFile(String filePath) {
    final trimmed = filePath.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        filePath,
        'filePath',
        'VGDuetSource.localFile: filePath must not be empty.',
      );
    }
    final lower = trimmed.toLowerCase();
    if (!lower.endsWith('.mp4') && !lower.endsWith('.mov')) {
      throw ArgumentError.value(
        filePath,
        'filePath',
        'VGDuetSource.localFile: filePath must end with .mp4 or .mov '
            '(got "${filePath.split('/').last}").',
      );
    }
    return VGDuetSource._(filePath: trimmed);
  }

  /// The file extension, always lower-case (e.g. `'mp4'` or `'mov'`).
  String get extension {
    final dot = filePath.lastIndexOf('.');
    return dot >= 0 ? filePath.substring(dot + 1).toLowerCase() : '';
  }

  /// The file's base name including extension.
  String get fileName {
    final slash = filePath.lastIndexOf('/');
    return slash >= 0 ? filePath.substring(slash + 1) : filePath;
  }

  /// Serializes to a plain [Map] for method channel / JSON transport.
  Map<String, dynamic> toMap() => <String, dynamic>{'filePath': filePath};

  /// Deserializes from a plain [Map].
  ///
  /// Throws [ArgumentError] if the map is missing or contains an invalid path.
  factory VGDuetSource.fromMap(Map<String, dynamic> map) {
    final path = map['filePath'];
    if (path is! String) {
      throw ArgumentError.value(
        map,
        'map',
        'VGDuetSource.fromMap: missing or invalid "filePath" key.',
      );
    }
    return VGDuetSource.localFile(path);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGDuetSource &&
          runtimeType == other.runtimeType &&
          filePath == other.filePath;

  @override
  int get hashCode => filePath.hashCode;

  @override
  String toString() => 'VGDuetSource(filePath: $filePath)';
}
