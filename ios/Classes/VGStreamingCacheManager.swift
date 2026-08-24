// VGStreamingCacheManager.swift
// Phase 4C6H — iOS Streaming Cache: AVFoundation Cache Lifecycle Manager
//
// Singleton that manages AVAssetDownloadURLSession and all prewarm job
// lifecycle for the Vanguard streaming cache subsystem.
//
// Threading model (matches readiness packet §5):
//   workerQueue   (com.connects.vanguard.cache.worker, serial)  — all state mutations
//   delegateQueue (com.connects.vanguard.cache.delegateQueue, serial OperationQueue)
//                                                                — AVAssetDownloadDelegate
//   MainThread   — result callbacks posted via DispatchQueue.main
//
// AVAssetDownloadURLSession deterministic identifier: com.connects.vanguard.streamingcache

import AVFoundation
import Foundation

// MARK: - Job record

/// Internal record of a single prewarm job (active or terminal).
private final class VGPrewarmJob {
    let requestId: String
    let task: AVAssetDownloadTask
    var state: String      // "queued" | "running" | "succeeded" | "failed" | "cancelled"
    var bytesCached: Int64
    var raw: String

    init(requestId: String, task: AVAssetDownloadTask) {
        self.requestId   = requestId
        self.task        = task
        self.state       = "queued"
        self.bytesCached = 0
        self.raw         = "status=QUEUED;requestId=\(requestId)"
    }
}

// MARK: - Manager

/// Phase4C6H native iOS streaming cache and prewarm manager.
///
/// All public methods accept a `result` closure called exactly once on the main thread.
final class VGStreamingCacheManager: NSObject {

    // MARK: Singleton

    static let shared = VGStreamingCacheManager()

    // MARK: Constants

    private static let sessionIdentifier  = "com.connects.vanguard.streamingcache"
    private static let workerQueueLabel   = "com.connects.vanguard.cache.worker"
    private static let delegateQueueLabel = "com.connects.vanguard.cache.delegateQueue"

    // Maximum number of terminal job records retained for status polling.
    // Bounded to prevent unbounded growth; oldest are evicted when over limit.
    private static let maxTerminalRetained = 64

    // MARK: Private state — all access on workerQueue

    private let workerQueue = DispatchQueue(
        label: VGStreamingCacheManager.workerQueueLabel,
        qos: .utility
    )

    private let delegateOperationQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = VGStreamingCacheManager.delegateQueueLabel
        q.maxConcurrentOperationCount = 1
        return q
    }()

    private var _session: AVAssetDownloadURLSession?

    /// In-flight jobs keyed by requestId.
    private var activeJobs: [String: VGPrewarmJob] = [:]

    /// Fix 2: Bounded terminal job records retained for status polling.
    /// Keyed by requestId; evicted FIFO when maxTerminalRetained is exceeded.
    private var terminalJobs: [String: VGPrewarmJob] = [:]
    private var terminalOrder: [String] = []   // insertion order for eviction

    /// Fix 3: OS-managed asset locations delivered by didFinishDownloadingTo,
    /// tracked by requestId so clearCache can remove them.
    private var finishedLocations: [String: URL] = [:]

    // MARK: - Init

    override private init() {
        super.init()
    }

    // MARK: - Session

    /// Returns (or lazily creates) the background AVAssetDownloadURLSession.
    /// Must be called on workerQueue.
    private func session() -> AVAssetDownloadURLSession {
        if let s = _session { return s }
        let config = URLSessionConfiguration.background(
            withIdentifier: VGStreamingCacheManager.sessionIdentifier
        )
        let s = AVAssetDownloadURLSession(
            configuration: config,
            assetDownloadDelegate: self,
            delegateQueue: delegateOperationQueue
        )
        _session = s
        return s
    }

    // MARK: - Cache directory

    /// Vanguard package cache subdirectory within the app Caches directory.
    /// May not exist yet before any download completes.
    private func cacheDirURL() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("vanguard_streaming_cache", isDirectory: true)
    }

    // MARK: - Disk size helpers

    private func directoryBytes(at url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        while let fileURL = enumerator?.nextObject() as? URL {
            let size = (try? fileURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey]
            ).totalFileAllocatedSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    private func fileCount(at url: URL) -> Int {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var count = 0
        while let fileURL = enumerator?.nextObject() as? URL {
            let isFile = (try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey]
            ).isRegularFile) ?? false
            if isFile { count += 1 }
        }
        return count
    }

    // MARK: - Fix 2: Terminal job retention helpers (workerQueue only)

    private func retainTerminal(_ job: VGPrewarmJob) {
        let reqId = job.requestId
        if terminalJobs[reqId] == nil {
            terminalOrder.append(reqId)
        }
        terminalJobs[reqId] = job
        // Evict oldest if over cap.
        while terminalOrder.count > VGStreamingCacheManager.maxTerminalRetained {
            let oldest = terminalOrder.removeFirst()
            terminalJobs.removeValue(forKey: oldest)
        }
    }

    // MARK: - getPlaybackCacheStatus

    func getStatus(
        cacheEnabled: Bool,
        result: @escaping (Any?) -> Void
    ) {
        workerQueue.async { [weak self] in
            guard let self = self else { return }
            let dirURL = self.cacheDirURL()
            // Fix 4: include tracked finished download locations in metrics.
            var spaceBytes = self.directoryBytes(at: dirURL)
            var resCount   = self.fileCount(at: dirURL)
            for (_, locURL) in self.finishedLocations {
                spaceBytes += self.directoryBytes(at: locURL)
                resCount   += self.fileCount(at: locURL)
            }
            let map: [String: Any] = [
                "phase":           "Phase4C6E",
                "metricsPhase":    "Phase4C6F2",
                "pass":            true,
                "state":           "available",
                "cacheAvailable":  true,
                "cacheEnabled":    cacheEnabled,
                "cacheDir":        dirURL.path,
                "cacheSpaceBytes": spaceBytes,
                "resourceCount":   resCount,
                "raw":             "status=OK;cacheEnabled=\(cacheEnabled)" +
                                   ";cacheSpaceBytes=\(spaceBytes);resourceCount=\(resCount)",
            ]
            DispatchQueue.main.async { result(map) }
        }
    }

    // MARK: - startPlaybackCachePrewarm

    func startPrewarm(
        requestId: String,
        uri: String,
        maxBytes: Int64,
        minimumFreeBytesAfterPrewarm: Int64,
        cacheEnabled: Bool,
        result: @escaping (Any?) -> Void
    ) {
        guard !requestId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // Fix 4: include cacheEnabled.
            let map: [String: Any] = [
                "phase": "Phase4C6E", "pass": false,
                "requestId": requestId, "state": "invalid",
                "cacheAvailable": false, "cacheEnabled": cacheEnabled,
                "raw": "status=FAIL;reason=blank_requestId",
            ]
            result(map); return
        }
        let trimmedURI = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURI.isEmpty else {
            let map: [String: Any] = [
                "phase": "Phase4C6E", "pass": false,
                "requestId": requestId, "state": "invalid",
                "cacheAvailable": false, "cacheEnabled": cacheEnabled,
                "raw": "status=FAIL;reason=blank_uri",
            ]
            result(map); return
        }
        guard cacheEnabled else {
            let map: [String: Any] = [
                "phase": "Phase4C6E", "pass": false,
                "requestId": requestId, "state": "invalid",
                "cacheAvailable": false, "cacheEnabled": cacheEnabled,
                "raw": "status=FAIL;reason=cache_disabled_for_prewarm",
            ]
            result(map); return
        }

        workerQueue.async { [weak self] in
            guard let self = self else { return }
            self._startPrewarmOnWorker(
                requestId: requestId,
                trimmedURI: trimmedURI,
                maxBytes: maxBytes,
                minimumFreeBytesAfterPrewarm: minimumFreeBytesAfterPrewarm,
                cacheEnabled: cacheEnabled,
                result: result
            )
        }
    }

    /// Must be called on workerQueue.
    private func _startPrewarmOnWorker(
        requestId: String,
        trimmedURI: String,
        maxBytes: Int64,
        minimumFreeBytesAfterPrewarm: Int64,
        cacheEnabled: Bool,
        result: @escaping (Any?) -> Void
    ) {
        // Scheme validation: accept only http / https HLS-like URLs. Reject DASH.
        guard let parsedURL = URL(string: trimmedURI),
              let scheme = parsedURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            let map: [String: Any] = [
                "phase": "Phase4C6E", "pass": false,
                "requestId": requestId, "state": "invalid",
                "cacheAvailable": false, "cacheEnabled": cacheEnabled,
                "raw": "status=FAIL;reason=invalid_scheme_or_url",
            ]
            DispatchQueue.main.async { result(map) }
            return
        }

        // Reject MPEG-DASH .mpd URLs.
        if parsedURL.path.lowercased().hasSuffix(".mpd") {
            let map: [String: Any] = [
                "phase": "Phase4C6E", "pass": false,
                "requestId": requestId, "state": "invalid",
                "cacheAvailable": false, "cacheEnabled": cacheEnabled,
                "raw": "status=FAIL;reason=dash_not_supported_on_ios",
            ]
            DispatchQueue.main.async { result(map) }
            return
        }

        // Fix 2: duplicate check applies only to ACTIVE jobs, not terminal records.
        if activeJobs[requestId] != nil {
            let map: [String: Any] = [
                "phase": "Phase4C6E", "pass": false,
                "requestId": requestId, "state": "duplicate",
                "cacheAvailable": false, "cacheEnabled": cacheEnabled,
                "raw": "status=FAIL;reason=duplicate_requestId",
            ]
            DispatchQueue.main.async { result(map) }
            return
        }

        // ── Phase4C6F3: Storage headroom guard ──────────────────────────────
        let dirURL = self.cacheDirURL()

        // Normalise reserve: negative → defaultMinFreeBytes; 0 → disabled.
        let reserve: Int64 = minimumFreeBytesAfterPrewarm < 0
            ? VGStorageHeadroomGuard.defaultMinFreeBytes
            : minimumFreeBytesAfterPrewarm

        // Fix 1: guard passes cacheDirURL to evaluate(); evaluate() walks to
        // nearest existing ancestor internally, so the directory need not exist.
        let guardResult = VGStorageHeadroomGuard.evaluate(
            cacheDirURL: dirURL,
            requestedBytes: maxBytes,
            minimumFreeBytesAfterPrewarm: reserve
        )

        switch guardResult {
        case .storageGuardError(let reason):
            var map: [String: Any] = [
                "phase": "Phase4C6F3", "pass": false,
                "requestId": requestId,
                "state": "storage_guard_error",
                "cacheAvailable": false, "cacheEnabled": cacheEnabled,
                "storageGuardPhase": "Phase4C6F3", "storageGuardPass": false,
                "raw": "status=FAIL;reason=storage_guard_error;requestId=\(requestId);guardReason=\(reason)",
            ]
            map.merge(VGStorageHeadroomGuard.diagnosticMap(for: guardResult)) { _, new in new }
            DispatchQueue.main.async { result(map) }
            return

        case .blockedLowStorage:
            var map: [String: Any] = [
                "phase": "Phase4C6F3", "pass": false,
                "requestId": requestId,
                "state": "blocked_low_storage",
                "cacheAvailable": false, "cacheEnabled": cacheEnabled,
                "storageGuardPhase": "Phase4C6F3", "storageGuardPass": false,
            ]
            map.merge(VGStorageHeadroomGuard.diagnosticMap(for: guardResult)) { _, new in new }
            if case let .blockedLowStorage(avail, req, minFree, proj) = guardResult {
                map["raw"] = "status=BLOCKED;reason=low_storage;requestId=\(requestId)" +
                             ";available=\(avail);requested=\(req);projected=\(proj);reserve=\(minFree)"
            }
            DispatchQueue.main.async { result(map) }
            return

        case .pass:
            break  // Fall through to task creation.
        }

        // ── Create AVAssetDownloadTask ────────────────────────────────────────
        // maxBytes informs the storage admission estimate; AVFoundation offline
        // tasks are not byte-limited downloads — they cache at OS discretion.
        let asset = AVURLAsset(url: parsedURL)
        let dlSession = self.session()
        guard let task = dlSession.makeAssetDownloadTask(
            asset: asset,
            assetTitle: requestId,
            assetArtworkData: nil,
            options: nil
        ) else {
            let map: [String: Any] = [
                "phase": "Phase4C6E", "pass": false,
                "requestId": requestId, "state": "invalid",
                "cacheAvailable": false, "cacheEnabled": cacheEnabled,
                "raw": "status=FAIL;reason=avfoundation_task_creation_failed",
            ]
            DispatchQueue.main.async { result(map) }
            return
        }

        let job = VGPrewarmJob(requestId: requestId, task: task)
        self.activeJobs[requestId] = job
        task.resume()

        // Build accepted response with storage diagnostics.
        // Fix 4: include cacheEnabled and cacheDir.
        var acceptedMap: [String: Any] = [
            "phase": "Phase4C6E", "pass": true,
            "requestId": requestId,
            "state": "accepted",
            "cacheAvailable": true,
            "cacheEnabled": cacheEnabled,
            "cacheDir": dirURL.path,
            "storageGuardPhase": "Phase4C6F3",
            "storageGuardPass": true,
            "raw": "status=OK;accepted=true;state=accepted;requestId=\(requestId)",
        ]
        acceptedMap.merge(VGStorageHeadroomGuard.diagnosticMap(for: guardResult)) { _, new in new }
        DispatchQueue.main.async { result(acceptedMap) }
    }

    // MARK: - getPlaybackCachePrewarmStatus

    func getPrewarmStatus(
        requestId: String,
        result: @escaping (Any?) -> Void
    ) {
        workerQueue.async { [weak self] in
            guard let self = self else { return }
            // Fix 3: blank requestId returns invalid, matching Android parity.
            guard !requestId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                let map: [String: Any] = [
                    "phase": "Phase4C6E", "pass": false,
                    "requestId": requestId, "state": "invalid",
                    "cacheAvailable": false,
                    "raw": "status=FAIL;reason=blank_requestId",
                ]
                DispatchQueue.main.async { result(map) }
                return
            }
            // Fix 2: look in activeJobs first, then terminalJobs.
            let job = self.activeJobs[requestId] ?? self.terminalJobs[requestId]
            guard let job = job else {
                let map: [String: Any] = [
                    "phase": "Phase4C6E", "pass": true,
                    "requestId": requestId,
                    "state": "not_found",
                    "cacheAvailable": true,
                    "bytesCached": 0, "newBytesCached": 0,
                    "raw": "status=NOT_FOUND;requestId=\(requestId)",
                ]
                DispatchQueue.main.async { result(map) }
                return
            }
            let state  = job.state
            let bytes  = job.bytesCached
            let rawStr = job.raw
            // Fix 2: pass=false only for "failed"; cancelled is pass=true (Android parity).
            let pass = state != "failed"
            let map: [String: Any] = [
                "phase": "Phase4C6E",
                "pass": pass,
                "requestId": requestId,
                "state": state,
                "cacheAvailable": true,
                "bytesCached": bytes,
                "newBytesCached": bytes,
                "raw": rawStr,
            ]
            DispatchQueue.main.async { result(map) }
        }
    }

    // MARK: - cancelPlaybackCachePrewarm

    func cancelPrewarm(
        requestId: String,
        result: @escaping (Any?) -> Void
    ) {
        workerQueue.async { [weak self] in
            guard let self = self else { return }
            // Fix 3: blank requestId returns invalid, matching Android parity.
            guard !requestId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                let map: [String: Any] = [
                    "phase": "Phase4C6E", "pass": false,
                    "requestId": requestId, "state": "invalid",
                    "cacheAvailable": false,
                    "raw": "status=FAIL;reason=blank_requestId",
                ]
                DispatchQueue.main.async { result(map) }
                return
            }
            // Fix 2: cancel only operates on active jobs; terminal records are not re-cancelled.
            if let job = self.activeJobs[requestId] {
                job.task.cancel()
                // Fix 1: set terminal state before moving to terminal map so that
                // subsequent delegate callbacks see state="cancelled" already set
                // and do not overwrite it with a duplicate cancelled record.
                job.state = "cancelled"
                job.raw   = "status=CANCELLED;requestId=\(requestId);reason=caller_cancel"
                self.activeJobs.removeValue(forKey: requestId)
                self.retainTerminal(job)
                let map: [String: Any] = [
                    "phase": "Phase4C6E", "pass": true,
                    "requestId": requestId,
                    "state": "cancel_requested",
                    "raw": "status=OK;cancelled=true;requestId=\(requestId)",
                ]
                DispatchQueue.main.async { result(map) }
            } else {
                let map: [String: Any] = [
                    "phase": "Phase4C6E", "pass": true,
                    "requestId": requestId,
                    "state": "not_found_or_terminal",
                    "raw": "status=OK;cancelled=false;requestId=\(requestId)",
                ]
                DispatchQueue.main.async { result(map) }
            }
        }
    }

    // MARK: - clearPlaybackCache

    func clearCache(result: @escaping (Any?) -> Void) {
        workerQueue.async { [weak self] in
            guard let self = self else { return }

            // Cancel all active tasks.
            for job in self.activeJobs.values { job.task.cancel() }
            self.activeJobs.removeAll()
            self.terminalJobs.removeAll()
            self.terminalOrder.removeAll()

            let dirURL      = self.cacheDirURL()
            var beforeBytes = self.directoryBytes(at: dirURL)
            var beforeCount = self.fileCount(at: dirURL)

            var removedCount = 0
            var failedCount  = 0

            // Fix 5: Remove OS-managed asset locations tracked by didFinishDownloadingTo.
            // Do NOT pre-clear finishedLocations; remove successful ones only so that
            // failed-removal entries remain tracked and appear in afterBytes.
            var removedLocationKeys: [String] = []
            for (reqId, locURL) in self.finishedLocations {
                let locBytes = self.directoryBytes(at: locURL)
                beforeBytes += locBytes
                let locFiles = self.fileCount(at: locURL)
                beforeCount += locFiles

                do {
                    try FileManager.default.removeItem(at: locURL)
                    removedCount += 1
                    removedLocationKeys.append(reqId)
                } catch {
                    failedCount += 1
                    // Leave in finishedLocations so afterBytes accounts for it.
                }
            }
            for key in removedLocationKeys {
                self.finishedLocations.removeValue(forKey: key)
            }

            // Remove package cache directory children.
            if FileManager.default.fileExists(atPath: dirURL.path) {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: dirURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                for childURL in children {
                    do {
                        try FileManager.default.removeItem(at: childURL)
                        removedCount += 1
                    } catch {
                        failedCount += 1
                    }
                }
            }

            // Fix 5: afterBytes includes package cache dir + any remaining failed tracked locations.
            var afterBytes = self.directoryBytes(at: dirURL)
            for (_, locURL) in self.finishedLocations {
                afterBytes += self.directoryBytes(at: locURL)
            }

            let map: [String: Any] = [
                "phase":                "Phase4C6F",
                "pass":                 true,
                "state":                "cleared",
                "cacheAvailable":       true,
                "cacheDir":             dirURL.path,
                "beforeBytes":          beforeBytes,
                "afterBytes":           afterBytes,
                "resourceCountBefore":  beforeCount,
                "removedResourceCount": removedCount,
                "failedResourceCount":  failedCount,
                "raw":                  "status=OK;removed=\(removedCount);failed=\(failedCount)" +
                                        ";beforeBytes=\(beforeBytes);afterBytes=\(afterBytes)",
            ]
            DispatchQueue.main.async { result(map) }
        }
    }

    // MARK: - Dispose / shutdown

    func invalidateAndCancel() {
        workerQueue.async { [weak self] in
            guard let self = self else { return }
            for job in self.activeJobs.values { job.task.cancel() }
            self.activeJobs.removeAll()
            self.terminalJobs.removeAll()
            self.terminalOrder.removeAll()
            self.finishedLocations.removeAll()
            self._session?.invalidateAndCancel()
            self._session = nil
        }
    }
}

// MARK: - AVAssetDownloadDelegate

extension VGStreamingCacheManager: AVAssetDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didLoad timeRange: CMTimeRange,
        totalTimeRangesLoaded loadedTimeRanges: [NSValue],
        timeRangeExpectedToLoad: CMTimeRange
    ) {
        let expectedSec = CMTimeGetSeconds(timeRangeExpectedToLoad.duration)
        guard expectedSec > 0 else { return }

        var loadedSec: Double = 0
        for value in loadedTimeRanges {
            loadedSec += CMTimeGetSeconds(value.timeRangeValue.duration)
        }
        let fraction = min(loadedSec / expectedSec, 1.0)

        workerQueue.async { [weak self] in
            guard let self = self else { return }
            for (_, job) in self.activeJobs where job.task === assetDownloadTask {
                job.bytesCached = Int64(fraction * 1_000_000)
                job.state       = "running"
                job.raw         = "status=RUNNING;requestId=\(job.requestId)" +
                                  ";fraction=\(String(format: "%.3f", fraction))"
                break
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        workerQueue.async { [weak self] in
            guard let self = self else { return }
            for (reqId, job) in self.activeJobs where job.task === task {
                if let error = error {
                    let cancelled = (error as NSError).code == NSURLErrorCancelled
                    job.state = cancelled ? "cancelled" : "failed"
                    job.raw   = "status=\(job.state.uppercased());requestId=\(reqId)" +
                                ";error=\(error.localizedDescription)"
                } else {
                    job.state = "succeeded"
                    job.raw   = "status=SUCCEEDED;requestId=\(reqId)"
                }
                // Fix 2: Move to terminal map so callers can poll the final state.
                // Active map no longer holds this job; duplicate detection is unaffected.
                self.activeJobs.removeValue(forKey: reqId)
                self.retainTerminal(job)
                break
            }
        }
    }

    // Fix 3: Track OS-managed asset location delivered after successful download.
    @available(iOS 10.0, *)
    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        workerQueue.async { [weak self] in
            guard let self = self else { return }
            // Match by task identity across active and terminal maps.
            let reqId: String? = self.activeJobs.first(where: { $0.value.task === assetDownloadTask })?.key
                ?? self.terminalJobs.first(where: { $0.value.task === assetDownloadTask })?.key
            if let reqId = reqId {
                self.finishedLocations[reqId] = location
            }
        }
    }
}
