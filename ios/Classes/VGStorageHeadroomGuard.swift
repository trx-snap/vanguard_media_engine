// VGStorageHeadroomGuard.swift
// Phase 4C6H — iOS Streaming Cache: Storage Headroom Admission Guard
//
// Mirrors the Android AndroidDagPlaybackStorageGuard (Phase4C6F3).
// Evaluates projected free volume capacity before admitting an
// AVAssetDownloadTask prewarm job.
//
// Threading: called on com.connects.vanguard.cache.worker serial queue.
// All Foundation volume-capacity queries are synchronous on that queue.
//
// Result field names match Android/Dart contract verbatim:
//   availableBytes, requestedBytes, minimumFreeBytesAfterPrewarm,
//   projectedAvailableBytes, storageGuardPhase, storageGuardPass

import Foundation

/// Phase4C6H storage admission guard for iOS.
///
/// Uses `URLResourceValues.volumeAvailableCapacityForImportantUsageKey`
/// (iOS 11+) with a fallback to `FileManager.attributesOfFileSystem` to
/// measure available volume capacity before admitting a prewarm job.
struct VGStorageHeadroomGuard {

    // MARK: - Constants

    /// Default minimum free bytes to leave on volume after a prewarm job.
    /// 64 MiB — matches `AndroidDagPlaybackStorageGuard.DEFAULT_MIN_FREE_BYTES`.
    static let defaultMinFreeBytes: Int64 = 64 * 1024 * 1024

    // MARK: - Result types

    enum GuardResult {
        /// Guard passed — proceed with prewarm job creation.
        case pass(
            availableBytes: Int64,
            requestedBytes: Int64,
            minimumFreeBytesAfterPrewarm: Int64,
            projectedAvailableBytes: Int64
        )
        /// Insufficient projected free space — prewarm admission blocked.
        case blockedLowStorage(
            availableBytes: Int64,
            requestedBytes: Int64,
            minimumFreeBytesAfterPrewarm: Int64,
            projectedAvailableBytes: Int64
        )
        /// Storage measurement failed — prewarm admission blocked.
        case storageGuardError(reason: String)
    }

    // MARK: - Evaluation

    /// Evaluates whether `requestedBytes` can safely be downloaded while
    /// leaving at least `minimumFreeBytesAfterPrewarm` bytes free on volume.
    ///
    /// - Parameters:
    ///   - cacheDirURL:                    A URL on the target volume. The URL or its nearest
    ///                                     existing ancestor is used for the volume query, so the
    ///                                     directory need not exist yet (Fix 1 — P1 defect).
    ///   - requestedBytes:                 Estimate of bytes the prewarm job will use.
    ///   - minimumFreeBytesAfterPrewarm:   Minimum bytes that must remain free.
    ///                                     0 disables the guard. Negative → defaultMinFreeBytes.
    static func evaluate(
        cacheDirURL: URL,
        requestedBytes: Int64,
        minimumFreeBytesAfterPrewarm: Int64
    ) -> GuardResult {
        // Resolve effective reserve.
        let reserve = minimumFreeBytesAfterPrewarm < 0
            ? VGStorageHeadroomGuard.defaultMinFreeBytes
            : minimumFreeBytesAfterPrewarm

        // Fix 1: walk up to the nearest existing ancestor so we can query
        // volume capacity without requiring the cache directory to exist yet.
        let probeURL = existingAncestor(of: cacheDirURL)

        // Probe available volume capacity.
        let available: Int64
        do {
            available = try queryAvailableBytes(for: probeURL)
        } catch {
            return .storageGuardError(reason: "volume_query_error:\(error.localizedDescription)")
        }

        let projected = available - requestedBytes

        // Guard disabled when reserve == 0.
        if reserve == 0 {
            return .pass(
                availableBytes: available,
                requestedBytes: requestedBytes,
                minimumFreeBytesAfterPrewarm: 0,
                projectedAvailableBytes: projected
            )
        }

        if projected >= reserve {
            return .pass(
                availableBytes: available,
                requestedBytes: requestedBytes,
                minimumFreeBytesAfterPrewarm: reserve,
                projectedAvailableBytes: projected
            )
        } else {
            return .blockedLowStorage(
                availableBytes: available,
                requestedBytes: requestedBytes,
                minimumFreeBytesAfterPrewarm: reserve,
                projectedAvailableBytes: projected
            )
        }
    }

    // MARK: - Ancestor resolution (Fix 1)

    /// Returns `url` if it exists, otherwise walks up the path until an
    /// existing ancestor is found. Falls back to the filesystem root ("/")
    /// which always exists so the volume query never throws on a missing dir.
    private static func existingAncestor(of url: URL) -> URL {
        var candidate = url.standardized
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            // Stop if we've reached the root (path won't shrink further).
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return candidate
    }

    // MARK: - Volume capacity query

    /// Returns available volume capacity in bytes.
    ///
    /// Primary:  `URLResourceValues.volumeAvailableCapacityForImportantUsage` (iOS 11+).
    /// Fallback: `FileManager.attributesOfFileSystem[.systemFreeSize]`.
    private static func queryAvailableBytes(for url: URL) throws -> Int64 {
        // Primary path: volumeAvailableCapacityForImportantUsage (iOS 11+).
        if #available(iOS 11.0, *) {
            let resourceValues = try url.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            )
            if let capacity = resourceValues.volumeAvailableCapacityForImportantUsage,
               capacity > 0 {
                return Int64(capacity)
            }
        }

        // Fallback: FileManager systemFreeSize.
        let attrs = try FileManager.default.attributesOfFileSystem(
            forPath: url.path
        )
        if let freeSize = attrs[.systemFreeSize] as? Int64 {
            return freeSize
        }
        if let freeSize = attrs[.systemFreeSize] as? Int {
            return Int64(freeSize)
        }
        throw StorageQueryError.noCapacityData
    }

    // MARK: - Diagnostics map

    /// Builds the structured diagnostic map to embed in a `startPrewarm` result.
    /// Field names mirror the Android/Dart contract verbatim.
    static func diagnosticMap(for result: GuardResult) -> [String: Any] {
        switch result {
        case let .pass(avail, req, minFree, projected):
            return [
                "availableBytes":               avail,
                "requestedBytes":               req,
                "minimumFreeBytesAfterPrewarm": minFree,
                "projectedAvailableBytes":      projected,
                "storageGuardPhase":            "Phase4C6F3",
                "storageGuardPass":             true,
            ]
        case let .blockedLowStorage(avail, req, minFree, projected):
            return [
                "availableBytes":               avail,
                "requestedBytes":               req,
                "minimumFreeBytesAfterPrewarm": minFree,
                "projectedAvailableBytes":      projected,
                "storageGuardPhase":            "Phase4C6F3",
                "storageGuardPass":             false,
            ]
        case .storageGuardError:
            return [
                "storageGuardPhase": "Phase4C6F3",
                "storageGuardPass":  false,
            ]
        }
    }

    // MARK: - Private error

    private enum StorageQueryError: Error {
        case noCapacityData
    }
}
