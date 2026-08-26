// VGStreamingOfflineAssetRecord.swift
// Phase 4C6H3B — iOS Streaming Offline HLS: Foreground Lifecycle Record
// Phase 4C6H3F — createdAtUnixMs/updatedAtUnixMs + catalog conversion helpers
//
// Internal mutable record of a single offline HLS acquisition task (active or
// terminal), owned exclusively by VGStreamingOfflineAssetManager. Reference
// type so that in-flight mutations from AVAssetDownloadDelegate callbacks are
// visible through dictionary lookups without a separate write-back step.
//
// All access to instances of this type must occur on
// VGStreamingOfflineAssetManager's serial workerQueue.

import AVFoundation
import Foundation

final class VGStreamingOfflineAssetRecord {
    let requestId: String
    let sourceKey: String
    let uri: String

    /// The in-flight download task, or `nil` once the record has reached a
    /// terminal state and no longer needs a live task reference.
    var task: AVAssetDownloadTask?

    /// "queued" | "running" | "succeeded" | "failed" | "cancelled"
    var state: String

    var bytesDownloaded: Int64
    var totalBytes: Int64?

    /// OS-managed local asset location delivered by didFinishDownloadingTo,
    /// populated only once the download completes successfully.
    var assetUri: URL?

    var errorCode: String?
    var errorMessage: String?
    var raw: String

    /// `var`, not `let`: catalog restoration (`restoringFromCatalog`) must be
    /// able to overwrite the freshly-initialized "now" value with the
    /// original persisted creation timestamp.
    var createdAtUnixMs: Int64
    var updatedAtUnixMs: Int64

    init(requestId: String, sourceKey: String, uri: String, task: AVAssetDownloadTask?) {
        self.requestId = requestId
        self.sourceKey = sourceKey
        self.uri = uri
        self.task = task
        self.state = "queued"
        self.bytesDownloaded = 0
        self.raw = "status=QUEUED;requestId=\(requestId)"
        let now = VGStreamingOfflineAssetRecord.nowUnixMs()
        self.createdAtUnixMs = now
        self.updatedAtUnixMs = now
    }
}

// MARK: - Catalog conversion (Phase 4C6H3F)

extension VGStreamingOfflineAssetRecord {

    static func nowUnixMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// Returns `url`'s path relative to the app's home directory
    /// (`NSHomeDirectory()`), or `nil` if `url` does not live under it. A
    /// relative-to-home path is the standard, documented-safe way to persist
    /// an AVAssetDownloadTask's on-disk location across relaunch: the app
    /// container's absolute path is not guaranteed stable, but paths
    /// relative to the container root are.
    static func relativePath(fromAbsoluteURL url: URL) -> String? {
        let home = NSHomeDirectory()
        let path = url.path
        guard path.hasPrefix(home) else { return nil }
        var relative = String(path.dropFirst(home.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return relative.isEmpty ? nil : relative
    }

    /// Reconstructs an absolute URL from a path previously produced by
    /// `relativePath(fromAbsoluteURL:)`, resolved against the *current*
    /// process's home directory.
    static func absoluteURL(fromRelativePath relativePath: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relativePath)
    }

    /// Builds a minimal, credential-safe catalog entry snapshot of this
    /// record's current state. Caller MUST supply an already-sanitized
    /// source origin (see `VGStreamingOfflineAssetCatalog.sanitizedSourceOrigin(fromURI:)`)
    /// — this method never persists `uri` itself, which may carry
    /// query-string tokens or signed segment/header credentials.
    func toCatalogEntry(sanitizedSourceOrigin: String) -> VGStreamingOfflineAssetCatalogEntry {
        VGStreamingOfflineAssetCatalogEntry(
            requestId: requestId,
            sourceKey: sourceKey,
            sanitizedSourceOrigin: sanitizedSourceOrigin,
            state: state,
            bytesDownloaded: bytesDownloaded,
            totalBytes: totalBytes,
            createdAtUnixMs: createdAtUnixMs,
            updatedAtUnixMs: updatedAtUnixMs,
            localAssetPointer: assetUri.flatMap(VGStreamingOfflineAssetRecord.relativePath(fromAbsoluteURL:))
        )
    }

    /// Reconstructs a record with no live task from a persisted catalog
    /// entry. Used only by VGStreamingOfflineAssetManager's catalog-load and
    /// background-relaunch reconciliation paths — a persisted record has no
    /// live AVAssetDownloadTask until/unless reconciliation reattaches one by
    /// matching `requestId` against `URLSession.getAllTasks`.
    static func restoringFromCatalog(_ entry: VGStreamingOfflineAssetCatalogEntry) -> VGStreamingOfflineAssetRecord {
        let record = VGStreamingOfflineAssetRecord(
            requestId: entry.requestId,
            sourceKey: entry.sourceKey,
            uri: entry.sanitizedSourceOrigin,
            task: nil
        )
        record.state = entry.state
        record.bytesDownloaded = entry.bytesDownloaded
        record.totalBytes = entry.totalBytes
        record.createdAtUnixMs = entry.createdAtUnixMs
        record.updatedAtUnixMs = entry.updatedAtUnixMs
        if let pointer = entry.localAssetPointer {
            record.assetUri = VGStreamingOfflineAssetRecord.absoluteURL(fromRelativePath: pointer)
        }
        record.raw = "status=\(entry.state.uppercased());requestId=\(entry.requestId);source=catalog_restore"
        return record
    }
}
