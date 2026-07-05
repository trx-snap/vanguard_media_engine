// vg_roi_models.dart
// UMF V2 ROI Signal / Server-Ready Sidecar Dart Models (ROI-1A)

import 'package:flutter/foundation.dart';

/// Represents a bounding box in normalized [0.0, 1.0] top-left coordinate system.
class VGROIBox {
  final double x;
  final double y;
  final double w;
  final double h;

  VGROIBox({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  }) {
    if (x.isNaN || x.isInfinite || y.isNaN || y.isInfinite || w.isNaN || w.isInfinite || h.isNaN || h.isInfinite) {
      throw ArgumentError('Coordinates must be finite and not NaN.');
    }
    if (x < 0.0 || x > 1.0 || y < 0.0 || y > 1.0 || w < 0.0 || w > 1.0 || h < 0.0 || h > 1.0) {
      throw ArgumentError('Coordinates must be in normalized [0.0, 1.0] range.');
    }
    if (w < 0.0 || h < 0.0) {
      throw ArgumentError('Width and height must be non-negative.');
    }
    // Check bounds with a small tolerance to protect against IEEE 754 precision inaccuracies.
    if ((x + w) > 1.0 + 1e-9 || (y + h) > 1.0 + 1e-9) {
      throw ArgumentError('Box overflows normalized bounds (x+w > 1.0 or y+h > 1.0).');
    }
  }

  factory VGROIBox.fromJson(Map<String, dynamic> json) {
    if (!json.containsKey('x') || !json.containsKey('y') || !json.containsKey('w') || !json.containsKey('h')) {
      throw ArgumentError('JSON map must contain x, y, w, and h keys.');
    }
    return VGROIBox(
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
      w: (json['w'] as num).toDouble(),
      h: (json['h'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'x': x,
      'y': y,
      'w': w,
      'h': h,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGROIBox &&
          runtimeType == other.runtimeType &&
          x == other.x &&
          y == other.y &&
          w == other.w &&
          h == other.h;

  @override
  int get hashCode => x.hashCode ^ y.hashCode ^ w.hashCode ^ h.hashCode;

  @override
  String toString() => 'VGROIBox(x: $x, y: $y, w: $w, h: $h)';
}

/// Represents a single timestamped ROI sample.
class VGROISample {
  final int timestampMs;
  final int framePtsMs;
  final int recordingRelativeMs;
  final VGROIBox? box;
  final String quality;
  final double? confidence;
  final String? paddingPolicy;

  VGROISample({
    required this.timestampMs,
    required this.framePtsMs,
    required this.recordingRelativeMs,
    this.box,
    required this.quality,
    this.confidence,
    this.paddingPolicy,
  }) {
    if (timestampMs < 0) {
      throw ArgumentError('timestampMs must be non-negative.');
    }
    if (framePtsMs < 0) {
      throw ArgumentError('framePtsMs must be non-negative.');
    }
    if (recordingRelativeMs < 0) {
      throw ArgumentError('recordingRelativeMs must be non-negative.');
    }
    if (quality.isEmpty) {
      throw ArgumentError('quality must not be empty.');
    }
    if (confidence != null) {
      if (confidence!.isNaN || confidence!.isInfinite || confidence! < 0.0 || confidence! > 1.0) {
        throw ArgumentError('confidence must be a normalized finite value in [0.0, 1.0].');
      }
    }
  }

  factory VGROISample.fromJson(Map<String, dynamic> json) {
    return VGROISample(
      timestampMs: json['timestampMs'] as int,
      framePtsMs: json['framePtsMs'] as int,
      recordingRelativeMs: json['recordingRelativeMs'] as int,
      box: json['box'] != null ? VGROIBox.fromJson(json['box'] as Map<String, dynamic>) : null,
      quality: json['quality'] as String,
      confidence: json['confidence'] != null ? (json['confidence'] as num).toDouble() : null,
      paddingPolicy: json['paddingPolicy'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'timestampMs': timestampMs,
      'framePtsMs': framePtsMs,
      'recordingRelativeMs': recordingRelativeMs,
      if (box != null) 'box': box!.toJson() else 'box': null,
      'quality': quality,
      if (confidence != null) 'confidence': confidence else 'confidence': null,
      if (paddingPolicy != null) 'paddingPolicy': paddingPolicy else 'paddingPolicy': null,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGROISample &&
          runtimeType == other.runtimeType &&
          timestampMs == other.timestampMs &&
          framePtsMs == other.framePtsMs &&
          recordingRelativeMs == other.recordingRelativeMs &&
          box == other.box &&
          quality == other.quality &&
          confidence == other.confidence &&
          paddingPolicy == other.paddingPolicy;

  @override
  int get hashCode =>
      timestampMs.hashCode ^
      framePtsMs.hashCode ^
      recordingRelativeMs.hashCode ^
      box.hashCode ^
      quality.hashCode ^
      confidence.hashCode ^
      paddingPolicy.hashCode;

  @override
  String toString() {
    return 'VGROISample(timestampMs: $timestampMs, framePtsMs: $framePtsMs, recordingRelativeMs: $recordingRelativeMs, box: $box, quality: $quality, confidence: $confidence, paddingPolicy: $paddingPolicy)';
  }
}

/// Represents an interval where ROI tracking failed or was unavailable.
class VGROIMissingInterval {
  final int startMs;
  final int endMs;
  final String reason;
  final bool postProcessRequired;

  VGROIMissingInterval({
    required this.startMs,
    required this.endMs,
    required this.reason,
    required this.postProcessRequired,
  }) {
    if (startMs < 0) {
      throw ArgumentError('startMs must be non-negative.');
    }
    if (endMs < startMs) {
      throw ArgumentError('endMs must be greater than or equal to startMs.');
    }
    if (reason.isEmpty) {
      throw ArgumentError('reason must not be empty.');
    }
  }

  factory VGROIMissingInterval.fromJson(Map<String, dynamic> json) {
    return VGROIMissingInterval(
      startMs: json['startMs'] as int,
      endMs: json['endMs'] as int,
      reason: json['reason'] as String,
      postProcessRequired: json['postProcessRequired'] as bool,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'startMs': startMs,
      'endMs': endMs,
      'reason': reason,
      'postProcessRequired': postProcessRequired,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGROIMissingInterval &&
          runtimeType == other.runtimeType &&
          startMs == other.startMs &&
          endMs == other.endMs &&
          reason == other.reason &&
          postProcessRequired == other.postProcessRequired;

  @override
  int get hashCode =>
      startMs.hashCode ^ endMs.hashCode ^ reason.hashCode ^ postProcessRequired.hashCode;

  @override
  String toString() {
    return 'VGROIMissingInterval(startMs: $startMs, endMs: $endMs, reason: $reason, postProcessRequired: $postProcessRequired)';
  }
}

/// Summarizes the metadata coverage and gaps.
class VGROICoverage {
  final double coveragePercent;
  final List<VGROIMissingInterval> missingIntervals;

  VGROICoverage({
    required this.coveragePercent,
    this.missingIntervals = const [],
  }) {
    if (coveragePercent.isNaN || coveragePercent.isInfinite || coveragePercent < 0.0 || coveragePercent > 1.0) {
      throw ArgumentError('coveragePercent must be a normalized finite value in [0.0, 1.0].');
    }
  }

  factory VGROICoverage.fromJson(Map<String, dynamic> json) {
    final intervalsList = json['missingIntervals'] as List?;
    return VGROICoverage(
      coveragePercent: (json['coveragePercent'] as num).toDouble(),
      missingIntervals: intervalsList != null
          ? intervalsList
              .map((i) => VGROIMissingInterval.fromJson(i as Map<String, dynamic>))
              .toList()
          : const [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'coveragePercent': coveragePercent,
      'missingIntervals': missingIntervals.map((i) => i.toJson()).toList(),
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGROICoverage &&
          runtimeType == other.runtimeType &&
          coveragePercent == other.coveragePercent &&
          listEquals(missingIntervals, other.missingIntervals);

  @override
  int get hashCode => coveragePercent.hashCode ^ missingIntervals.hashCode;

  @override
  String toString() {
    return 'VGROICoverage(coveragePercent: $coveragePercent, missingIntervals: $missingIntervals)';
  }
}

/// Defines target video identities.
class VGROIIdentity {
  final int durationMs;
  final int width;
  final int height;
  final String? hash;

  VGROIIdentity({
    required this.durationMs,
    required this.width,
    required this.height,
    this.hash,
  }) {
    if (durationMs < 0) {
      throw ArgumentError('durationMs must be non-negative.');
    }
    if (width <= 0) {
      throw ArgumentError('width must be greater than zero.');
    }
    if (height <= 0) {
      throw ArgumentError('height must be greater than zero.');
    }
  }

  factory VGROIIdentity.fromJson(Map<String, dynamic> json) {
    return VGROIIdentity(
      durationMs: json['durationMs'] as int,
      width: json['width'] as int,
      height: json['height'] as int,
      hash: json['hash'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'durationMs': durationMs,
      'width': width,
      'height': height,
      if (hash != null) 'hash': hash else 'hash': null,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGROIIdentity &&
          runtimeType == other.runtimeType &&
          durationMs == other.durationMs &&
          width == other.width &&
          height == other.height &&
          hash == other.hash;

  @override
  int get hashCode => durationMs.hashCode ^ width.hashCode ^ height.hashCode ^ hash.hashCode;

  @override
  String toString() {
    return 'VGROIIdentity(durationMs: $durationMs, width: $width, height: $height, hash: $hash)';
  }
}

/// The top-level ROI sidecar persistence metadata block.
class VGROISidecar {
  final int version;
  final String sourceType;
  final String platform;
  final String coordinateSpace;
  final String recordingSessionId;
  final VGROIIdentity videoIdentity;
  final VGROICoverage coverage;
  final List<VGROISample> samples;
  final bool finalized;

  VGROISidecar({
    required this.version,
    required this.sourceType,
    required this.platform,
    required this.coordinateSpace,
    required this.recordingSessionId,
    required this.videoIdentity,
    required this.coverage,
    this.samples = const [],
    required this.finalized,
  }) {
    if (version <= 0) {
      throw ArgumentError('version must be greater than zero.');
    }
    if (sourceType.isEmpty) {
      throw ArgumentError('sourceType must not be empty.');
    }
    if (platform.isEmpty) {
      throw ArgumentError('platform must not be empty.');
    }
    if (coordinateSpace.isEmpty) {
      throw ArgumentError('coordinateSpace must not be empty.');
    }
    if (recordingSessionId.isEmpty) {
      throw ArgumentError('recordingSessionId must not be empty.');
    }
  }

  factory VGROISidecar.fromJson(Map<String, dynamic> json) {
    final samplesList = json['samples'] as List?;
    return VGROISidecar(
      version: json['version'] as int,
      sourceType: json['sourceType'] as String,
      platform: json['platform'] as String,
      coordinateSpace: json['coordinateSpace'] as String,
      recordingSessionId: json['recordingSessionId'] as String,
      videoIdentity: VGROIIdentity.fromJson(json['videoIdentity'] as Map<String, dynamic>),
      coverage: VGROICoverage.fromJson(json['coverage'] as Map<String, dynamic>),
      samples: samplesList != null
          ? samplesList.map((s) => VGROISample.fromJson(s as Map<String, dynamic>)).toList()
          : const [],
      finalized: json['finalized'] as bool,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'sourceType': sourceType,
      'platform': platform,
      'coordinateSpace': coordinateSpace,
      'recordingSessionId': recordingSessionId,
      'videoIdentity': videoIdentity.toJson(),
      'coverage': coverage.toJson(),
      'samples': samples.map((s) => s.toJson()).toList(),
      'finalized': finalized,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VGROISidecar &&
          runtimeType == other.runtimeType &&
          version == other.version &&
          sourceType == other.sourceType &&
          platform == other.platform &&
          coordinateSpace == other.coordinateSpace &&
          recordingSessionId == other.recordingSessionId &&
          videoIdentity == other.videoIdentity &&
          coverage == other.coverage &&
          listEquals(samples, other.samples);

  @override
  int get hashCode =>
      version.hashCode ^
      sourceType.hashCode ^
      platform.hashCode ^
      coordinateSpace.hashCode ^
      recordingSessionId.hashCode ^
      videoIdentity.hashCode ^
      coverage.hashCode ^
      samples.hashCode;

  @override
  String toString() {
    return 'VGROISidecar(version: $version, sourceType: $sourceType, platform: $platform, coordinateSpace: $coordinateSpace, recordingSessionId: $recordingSessionId, videoIdentity: $videoIdentity, coverage: $coverage, samples: $samples, finalized: $finalized)';
  }
}
