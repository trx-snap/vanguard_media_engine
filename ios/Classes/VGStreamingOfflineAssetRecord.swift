// VGStreamingOfflineAssetRecord.swift
// Phase 4C6H3B — iOS Streaming Offline HLS: Foreground Lifecycle Record
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

    init(requestId: String, sourceKey: String, uri: String, task: AVAssetDownloadTask?) {
        self.requestId = requestId
        self.sourceKey = sourceKey
        self.uri = uri
        self.task = task
        self.state = "queued"
        self.bytesDownloaded = 0
        self.raw = "status=QUEUED;requestId=\(requestId)"
    }
}
