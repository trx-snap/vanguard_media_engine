// VGStreamingOfflineAssetManager.swift
// Phase 4C6H3B — iOS Native Offline HLS Foreground Lifecycle Backend
//
// Singleton that owns AVAssetDownloadURLSession and all foreground offline
// HLS acquisition lifecycle state for the six VGStreamingOfflineAssetClient
// MethodChannel routes: start/status/cancel/delete/clear/query.
//
// Threading model (mirrors VGStreamingCacheManager, Phase 4C6H):
//   workerQueue   (com.connects.vanguard.offlinehls.worker, serial)  — all state mutations
//   delegateQueue (com.connects.vanguard.offlinehls.delegateQueue, serial OperationQueue)
//                                                                     — AVAssetDownloadDelegate
//   MainThread    — result callbacks posted via DispatchQueue.main
//
// AVAssetDownloadURLSession deterministic identifier: com.connects.vanguard.offlinehls
//
// Phase 4C6H3F additions: best-effort catalog persistence (see
// VGStreamingOfflineAssetCatalog) and background-relaunch reconciliation
// (see wakeForBackgroundRelaunch / urlSessionDidFinishEvents below), wired to
// the app delegate via VGStreamingOfflineBackgroundSessionHandler. Terminal
// and succeeded records now survive process death on a best-effort,
// credential-free basis. Does NOT force ABR, add DASH support, or touch
// Media3/Android/ConnectsApp.

import AVFoundation
import Foundation

/// Phase4C6H3B native iOS offline HLS foreground lifecycle manager.
///
/// All public methods accept a `result` closure called exactly once on the main thread.
final class VGStreamingOfflineAssetManager: NSObject {

    // MARK: Singleton

    static let shared = VGStreamingOfflineAssetManager()

    // MARK: Constants

    private static let phase = "Phase4C6H3B"
    private static let sessionIdentifier  = "com.connects.vanguard.offlinehls"
    private static let workerQueueLabel   = "com.connects.vanguard.offlinehls.worker"
    private static let delegateQueueLabel = "com.connects.vanguard.offlinehls.delegateQueue"

    /// Maximum number of terminal records retained for status/query polling.
    /// Bounded to prevent unbounded growth; oldest are evicted when over limit.
    private static let maxTerminalRetained = 128

    /// Conservative estimate used for the storage headroom guard when the
    /// caller supplies a non-positive `estimatedBytes`.
    private static let defaultEstimatedBytes: Int64 = 8 * 1024 * 1024

    // MARK: Private state — all access on workerQueue

    private let workerQueue = DispatchQueue(
        label: VGStreamingOfflineAssetManager.workerQueueLabel,
        qos: .utility
    )

    private let delegateOperationQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = VGStreamingOfflineAssetManager.delegateQueueLabel
        q.maxConcurrentOperationCount = 1
        return q
    }()

    private var _session: AVAssetDownloadURLSession?

    /// In-flight acquisition records keyed by requestId.
    private var activeRecords: [String: VGStreamingOfflineAssetRecord] = [:]

    /// Bounded terminal record retention keyed by requestId; evicted FIFO
    /// when maxTerminalRetained is exceeded.
    private var terminalRecords: [String: VGStreamingOfflineAssetRecord] = [:]
    private var terminalOrder: [String] = []   // insertion order for eviction

    /// OS-managed asset locations delivered by didFinishDownloadingTo,
    /// tracked by requestId so delete/clear can remove them from disk.
    private var finishedLocations: [String: URL] = [:]

    /// Catalog of the most recent successful requestId for a given sourceKey,
    /// used by queryAvailability and delete-by-sourceKey lookups.
    private var succeededRequestIdBySourceKey: [String: String] = [:]

    /// Best-effort on-disk persistence (Phase 4C6H3F). All access is on
    /// workerQueue; failures are diagnostic-only and never fail a foreground
    /// operation.
    private let catalog = VGStreamingOfflineAssetCatalog.shared

    // MARK: - Init

    override private init() {
        super.init()
        // Best-effort restore of terminal/succeeded state from a prior
        // process, so a plain cold foreground launch (not just a background
        // URLSession relaunch) can still answer status/availability queries
        // for previously-completed downloads.
        workerQueue.async { [weak self] in
            self?.loadPersistedCatalogOnWorker()
        }
    }

    /// Must be called on workerQueue. Restores only terminal/succeeded
    /// entries — active (queued/running) entries require live-task
    /// reconciliation and are handled exclusively by
    /// `wakeForBackgroundRelaunch()`.
    private func loadPersistedCatalogOnWorker() {
        let entries = catalog.load()
        for entry in entries {
            guard entry.state == "succeeded" || entry.state == "failed" || entry.state == "cancelled" else { continue }
            let record = VGStreamingOfflineAssetRecord.restoringFromCatalog(entry)
            retainTerminal(record)
            if entry.state == "succeeded" {
                succeededRequestIdBySourceKey[entry.sourceKey] = entry.requestId
                if let assetUri = record.assetUri {
                    finishedLocations[entry.requestId] = assetUri
                }
            }
        }
    }

    /// Must be called on workerQueue. Best-effort persist of a single
    /// record's current state to the catalog, stripping the original
    /// (possibly authenticated) `uri` down to a sanitized diagnostic origin
    /// before it ever reaches disk. Never throws; a persistence failure is
    /// diagnostic-only and must not fail the caller's foreground operation.
    private func persistRecord(_ record: VGStreamingOfflineAssetRecord) {
        record.updatedAtUnixMs = VGStreamingOfflineAssetRecord.nowUnixMs()
        let sanitizedOrigin = VGStreamingOfflineAssetCatalog.sanitizedSourceOrigin(fromURI: record.uri)
        catalog.upsert(record.toCatalogEntry(sanitizedSourceOrigin: sanitizedOrigin))
    }

    // MARK: - Session

    /// Returns (or lazily creates) the background AVAssetDownloadURLSession.
    /// Must be called on workerQueue.
    private func session() -> AVAssetDownloadURLSession {
        if let s = _session { return s }
        let config = URLSessionConfiguration.background(
            withIdentifier: VGStreamingOfflineAssetManager.sessionIdentifier
        )
        let s = AVAssetDownloadURLSession(
            configuration: config,
            assetDownloadDelegate: self,
            delegateQueue: delegateOperationQueue
        )
        _session = s
        return s
    }

    // MARK: - Offline asset root

    /// Dedicated offline asset root directory used only as a volume probe
    /// target for the storage headroom guard and as a clear-all target for
    /// any future locally-tracked files. AVAssetDownloadTask locations
    /// delivered by the OS live outside this root and are tracked separately
    /// via `finishedLocations`.
    private func offlineAssetRootURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("vanguard_streaming_offline_assets", isDirectory: true)
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

    // MARK: - Terminal record retention helpers (workerQueue only)

    private func retainTerminal(_ record: VGStreamingOfflineAssetRecord) {
        let reqId = record.requestId
        if terminalRecords[reqId] == nil {
            terminalOrder.append(reqId)
        }
        terminalRecords[reqId] = record
        while terminalOrder.count > VGStreamingOfflineAssetManager.maxTerminalRetained {
            let oldest = terminalOrder.removeFirst()
            terminalRecords.removeValue(forKey: oldest)
        }
    }

    // MARK: - Response builders

    private static func invalidStartMap(requestId: String, sourceKey: String, reason: String) -> [String: Any] {
        [
            "phase": phase, "pass": false,
            "requestId": requestId, "sourceKey": sourceKey,
            "state": "invalid",
            "raw": "status=FAIL;reason=\(reason)",
        ]
    }

    private static func unsupportedStartMap(requestId: String, sourceKey: String, raw: String) -> [String: Any] {
        [
            "phase": phase, "pass": false,
            "requestId": requestId, "sourceKey": sourceKey,
            "state": "unsupported",
            "raw": raw,
        ]
    }

    // MARK: - startStreamingOfflineAssetAcquisition

    func startAcquisition(
        requestId: String,
        sourceKey: String,
        uri: String,
        httpHeaders: [String: String]?,
        formatHint: String?,
        requireLlHlsTags: Bool,
        estimatedBytes: Int64,
        minimumFreeBytes: Int64,
        result: @escaping (Any?) -> Void
    ) {
        let trimmedRequestId = requestId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSourceKey = sourceKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURI = uri.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedRequestId.isEmpty else {
            result(Self.invalidStartMap(requestId: requestId, sourceKey: sourceKey, reason: "blank_requestId"))
            return
        }
        guard !trimmedSourceKey.isEmpty else {
            result(Self.invalidStartMap(requestId: trimmedRequestId, sourceKey: sourceKey, reason: "blank_sourceKey"))
            return
        }
        guard !trimmedURI.isEmpty,
              let parsedURL = URL(string: trimmedURI),
              let scheme = parsedURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            result(Self.invalidStartMap(requestId: trimmedRequestId, sourceKey: trimmedSourceKey, reason: "invalid_scheme_or_uri"))
            return
        }

        let normalizedFormatHint = (formatHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isDashHint = normalizedFormatHint == "dash"
        let isMpdPath = parsedURL.path.lowercased().hasSuffix(".mpd")
        if isDashHint || isMpdPath {
            result(Self.unsupportedStartMap(requestId: trimmedRequestId, sourceKey: trimmedSourceKey, raw: "dash_offline_deferred"))
            return
        }

        if requireLlHlsTags {
            result(Self.unsupportedStartMap(requestId: trimmedRequestId, sourceKey: trimmedSourceKey, raw: "low_latency_offline_constrained"))
            return
        }

        workerQueue.async { [weak self] in
            guard let self = self else { return }
            self._startAcquisitionOnWorker(
                requestId: trimmedRequestId,
                sourceKey: trimmedSourceKey,
                parsedURL: parsedURL,
                httpHeaders: httpHeaders,
                estimatedBytes: estimatedBytes,
                minimumFreeBytes: minimumFreeBytes,
                result: result
            )
        }
    }

    /// Must be called on workerQueue.
    private func _startAcquisitionOnWorker(
        requestId: String,
        sourceKey: String,
        parsedURL: URL,
        httpHeaders: [String: String]?,
        estimatedBytes: Int64,
        minimumFreeBytes: Int64,
        result: @escaping (Any?) -> Void
    ) {
        // Duplicate check applies only to ACTIVE requests, not terminal records,
        // so a previously-failed/cancelled requestId can be retried.
        if activeRecords[requestId] != nil {
            let map: [String: Any] = [
                "phase": Self.phase, "pass": false,
                "requestId": requestId, "sourceKey": sourceKey,
                "state": "duplicate",
                "raw": "status=FAIL;reason=duplicate_requestId",
            ]
            DispatchQueue.main.async { result(map) }
            return
        }

        // ── Storage headroom guard ──────────────────────────────────────────
        let rootURL = self.offlineAssetRootURL()
        let effectiveEstimate: Int64 = estimatedBytes > 0
            ? estimatedBytes
            : VGStreamingOfflineAssetManager.defaultEstimatedBytes
        let reserve: Int64 = minimumFreeBytes < 0
            ? VGStorageHeadroomGuard.defaultMinFreeBytes
            : minimumFreeBytes

        let guardResult = VGStorageHeadroomGuard.evaluate(
            cacheDirURL: rootURL,
            requestedBytes: effectiveEstimate,
            minimumFreeBytesAfterPrewarm: reserve
        )

        switch guardResult {
        case .storageGuardError(let reason):
            var map: [String: Any] = [
                "phase": Self.phase, "pass": false,
                "requestId": requestId, "sourceKey": sourceKey,
                "state": "storageGuardError",
                "raw": "status=FAIL;reason=storage_guard_error;requestId=\(requestId);guardReason=\(reason)",
            ]
            map.merge(VGStorageHeadroomGuard.diagnosticMap(for: guardResult)) { _, new in new }
            DispatchQueue.main.async { result(map) }
            return

        case .blockedLowStorage:
            var map: [String: Any] = [
                "phase": Self.phase, "pass": false,
                "requestId": requestId, "sourceKey": sourceKey,
                "state": "blockedLowStorage",
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
        // "AVURLAssetHTTPHeaderFieldsKey" is only attached when the caller
        // explicitly supplies headers; Apple discourages this option for
        // general HLS playback but it remains the supported mechanism for
        // authenticated manifest/segment fetches on AVAssetDownloadTask.
        // Referenced by its literal string (mirrors
        // VGStreamingPlaybackCoordinator.swift) since the symbol is not
        // exposed to Swift.
        var assetOptions: [String: Any]?
        if let headers = httpHeaders, !headers.isEmpty {
            assetOptions = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        }
        let asset = AVURLAsset(url: parsedURL, options: assetOptions)

        let dlSession = self.session()
        guard let task = dlSession.makeAssetDownloadTask(
            asset: asset,
            assetTitle: requestId,
            assetArtworkData: nil,
            options: nil
        ) else {
            let map: [String: Any] = [
                "phase": Self.phase, "pass": false,
                "requestId": requestId, "sourceKey": sourceKey,
                "state": "invalid",
                "raw": "status=FAIL;reason=avfoundation_task_creation_failed",
            ]
            DispatchQueue.main.async { result(map) }
            return
        }

        // taskDescription carries requestId across process relaunch — it is
        // the only way to re-associate an OS-retained AVAssetDownloadTask
        // (from URLSession.getAllTasks) back to its record, since the task
        // object itself cannot be reconstructed. Must be set before resume.
        task.taskDescription = requestId

        // Register state "queued" before resume so a status poll racing the
        // resume call always observes a tracked record.
        let record = VGStreamingOfflineAssetRecord(
            requestId: requestId, sourceKey: sourceKey,
            uri: parsedURL.absoluteString, task: task
        )
        self.activeRecords[requestId] = record
        self.persistRecord(record)
        task.resume()

        var acceptedMap: [String: Any] = [
            "phase": Self.phase, "pass": true,
            "requestId": requestId, "sourceKey": sourceKey,
            "state": "accepted",
            "raw": "status=OK;accepted=true;state=accepted;requestId=\(requestId)",
        ]
        acceptedMap.merge(VGStorageHeadroomGuard.diagnosticMap(for: guardResult)) { _, new in new }
        DispatchQueue.main.async { result(acceptedMap) }
    }

    // MARK: - getStreamingOfflineAssetStatus

    func getStatus(
        requestId: String,
        sourceKey: String?,
        result: @escaping (Any?) -> Void
    ) {
        let trimmedRequestId = requestId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSourceKey = sourceKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        workerQueue.async { [weak self] in
            guard let self = self else { return }
            if let record = self.activeRecords[trimmedRequestId] ?? self.terminalRecords[trimmedRequestId] {
                let map = self.statusMap(record: record)
                DispatchQueue.main.async { result(map) }
                return
            }

            // requestId lookup missed — fall back to sourceKey when supplied,
            // per the readiness contract allowing status queries by either key.
            if let key = trimmedSourceKey, !key.isEmpty {
                if let rid = self.succeededRequestIdBySourceKey[key],
                   let record = self.activeRecords[rid] ?? self.terminalRecords[rid] {
                    let map = self.statusMap(record: record)
                    DispatchQueue.main.async { result(map) }
                    return
                }
                if let record = self.activeRecords.values.first(where: { $0.sourceKey == key })
                    ?? self.terminalRecords.values.first(where: { $0.sourceKey == key }) {
                    let map = self.statusMap(record: record)
                    DispatchQueue.main.async { result(map) }
                    return
                }
            }

            let map = self.statusMap(
                requestId: trimmedRequestId,
                sourceKey: sourceKey ?? "unknown_source",
                state: "notFound",
                raw: "status=NOT_FOUND;requestId=\(trimmedRequestId)"
            )
            DispatchQueue.main.async { result(map) }
        }
    }

    private func statusMap(record: VGStreamingOfflineAssetRecord) -> [String: Any] {
        var map: [String: Any] = [
            "phase": Self.phase,
            "pass": record.state != "failed",
            "requestId": record.requestId,
            "sourceKey": record.sourceKey,
            "state": record.state,
            "bytesDownloaded": record.bytesDownloaded,
            "raw": record.raw,
            "diagnostics": [
                "phase": Self.phase,
                "state": record.state,
            ] as [String: Any],
        ]
        if let total = record.totalBytes { map["totalBytes"] = total }
        if record.state == "succeeded", let assetUri = record.assetUri {
            map["assetUri"] = assetUri.absoluteString
        }
        if let code = record.errorCode { map["errorCode"] = code }
        if let msg = record.errorMessage { map["errorMessage"] = msg }
        return map
    }

    private func statusMap(requestId: String, sourceKey: String, state: String, raw: String) -> [String: Any] {
        [
            "phase": Self.phase,
            "pass": true,
            "requestId": requestId,
            "sourceKey": sourceKey,
            "state": state,
            "bytesDownloaded": 0,
            "raw": raw,
            "diagnostics": [
                "phase": Self.phase,
                "state": state,
            ] as [String: Any],
        ]
    }

    // MARK: - cancelStreamingOfflineAssetAcquisition

    func cancelAcquisition(requestId: String, result: @escaping (Any?) -> Void) {
        let trimmedRequestId = requestId.trimmingCharacters(in: .whitespacesAndNewlines)
        workerQueue.async { [weak self] in
            guard let self = self else { return }
            guard !trimmedRequestId.isEmpty, let record = self.activeRecords[trimmedRequestId] else {
                let map: [String: Any] = [
                    "phase": Self.phase, "pass": true,
                    "requestId": trimmedRequestId,
                    "state": "not_found_or_terminal",
                    "raw": "status=OK;cancelled=false;requestId=\(trimmedRequestId)",
                ]
                DispatchQueue.main.async { result(map) }
                return
            }

            // Set terminal state before moving to terminal map so that a
            // subsequent didCompleteWithError delegate callback (which no
            // longer finds this requestId in activeRecords) does not
            // overwrite this cancellation with a duplicate record.
            record.task?.cancel()
            record.state = "cancelled"
            record.raw = "status=CANCELLED;requestId=\(trimmedRequestId);reason=caller_cancel"
            self.activeRecords.removeValue(forKey: trimmedRequestId)
            self.retainTerminal(record)
            self.persistRecord(record)

            let map: [String: Any] = [
                "phase": Self.phase, "pass": true,
                "requestId": trimmedRequestId, "sourceKey": record.sourceKey,
                "state": "cancel_requested",
                "raw": "status=OK;cancelled=true;requestId=\(trimmedRequestId)",
            ]
            DispatchQueue.main.async { result(map) }
        }
    }

    // MARK: - deleteStreamingOfflineAsset

    func deleteAsset(requestId: String?, sourceKey: String?, result: @escaping (Any?) -> Void) {
        let trimmedRequestId = requestId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSourceKey = sourceKey?.trimmingCharacters(in: .whitespacesAndNewlines)

        workerQueue.async { [weak self] in
            guard let self = self else { return }

            var targetRequestIds = Set<String>()
            if let rid = trimmedRequestId, !rid.isEmpty,
               (self.activeRecords[rid] != nil || self.terminalRecords[rid] != nil) {
                targetRequestIds.insert(rid)
            }
            if let key = trimmedSourceKey, !key.isEmpty {
                for (rid, rec) in self.activeRecords where rec.sourceKey == key { targetRequestIds.insert(rid) }
                for (rid, rec) in self.terminalRecords where rec.sourceKey == key { targetRequestIds.insert(rid) }
            }

            guard !targetRequestIds.isEmpty else {
                var map: [String: Any] = [
                    "phase": Self.phase, "pass": true,
                    "state": "not_found_or_terminal",
                    "raw": "status=OK;deleted=false",
                ]
                if let rid = trimmedRequestId, !rid.isEmpty { map["requestId"] = rid }
                if let key = trimmedSourceKey, !key.isEmpty { map["sourceKey"] = key }
                DispatchQueue.main.async { result(map) }
                return
            }

            var removedCount = 0
            var freedBytes: Int64 = 0
            var lastSourceKey = trimmedSourceKey
            var lastRequestId = trimmedRequestId

            for rid in targetRequestIds {
                if let rec = self.activeRecords[rid] {
                    rec.task?.cancel()
                    lastSourceKey = rec.sourceKey
                    self.activeRecords.removeValue(forKey: rid)
                }
                if let rec = self.terminalRecords[rid] {
                    lastSourceKey = rec.sourceKey
                    self.terminalRecords.removeValue(forKey: rid)
                    self.terminalOrder.removeAll { $0 == rid }
                }
                if let key = lastSourceKey, self.succeededRequestIdBySourceKey[key] == rid {
                    self.succeededRequestIdBySourceKey.removeValue(forKey: key)
                }
                if let loc = self.finishedLocations[rid] {
                    freedBytes += self.directoryBytes(at: loc)
                    try? FileManager.default.removeItem(at: loc)
                    self.finishedLocations.removeValue(forKey: rid)
                }
                removedCount += 1
                lastRequestId = rid
            }

            self.catalog.remove(requestIds: targetRequestIds)

            var map: [String: Any] = [
                "phase": Self.phase, "pass": true,
                "state": "deleted",
                "removedCount": removedCount,
                "removedResourceCount": removedCount,
                "freedBytes": freedBytes,
                "raw": "status=OK;deleted=true;removedCount=\(removedCount);freedBytes=\(freedBytes)",
            ]
            if let rid = lastRequestId, !rid.isEmpty { map["requestId"] = rid }
            if let key = lastSourceKey, !key.isEmpty { map["sourceKey"] = key }
            DispatchQueue.main.async { result(map) }
        }
    }

    // MARK: - clearStreamingOfflineAssets

    func clearAssets(result: @escaping (Any?) -> Void) {
        workerQueue.async { [weak self] in
            guard let self = self else { return }

            for record in self.activeRecords.values { record.task?.cancel() }
            self.activeRecords.removeAll()
            self.terminalRecords.removeAll()
            self.terminalOrder.removeAll()
            self.succeededRequestIdBySourceKey.removeAll()

            var removedCount = 0
            var failedCount = 0
            var freedBytes: Int64 = 0

            for (_, location) in self.finishedLocations {
                freedBytes += self.directoryBytes(at: location)
                do {
                    try FileManager.default.removeItem(at: location)
                    removedCount += 1
                } catch {
                    failedCount += 1
                }
            }
            self.finishedLocations.removeAll()
            self.catalog.clearAll()

            let rootURL = self.offlineAssetRootURL()
            if FileManager.default.fileExists(atPath: rootURL.path) {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: rootURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                for childURL in children {
                    freedBytes += self.directoryBytes(at: childURL)
                    do {
                        try FileManager.default.removeItem(at: childURL)
                        removedCount += 1
                    } catch {
                        failedCount += 1
                    }
                }
            }

            let map: [String: Any] = [
                "phase": Self.phase,
                "pass": true,
                "state": "cleared",
                "removedResourceCount": removedCount,
                "failedResourceCount": failedCount,
                "freedBytes": freedBytes,
                "raw": "status=OK;removed=\(removedCount);failed=\(failedCount);freedBytes=\(freedBytes)",
            ]
            DispatchQueue.main.async { result(map) }
        }
    }

    // MARK: - queryStreamingOfflineAssetAvailability

    func queryAvailability(sourceKeys: [String]?, result: @escaping (Any?) -> Void) {
        workerQueue.async { [weak self] in
            guard let self = self else { return }
            var assets: [[String: Any]] = []

            if let keys = sourceKeys, !keys.isEmpty {
                for rawKey in keys {
                    let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { continue }
                    if let rid = self.succeededRequestIdBySourceKey[key],
                       let record = self.terminalRecords[rid],
                       record.state == "succeeded" {
                        assets.append(self.availableAssetMap(record: record))
                    } else {
                        assets.append([
                            "sourceKey": key,
                            "state": "unavailable",
                            "isPlayableOffline": false,
                            "reason": "not_downloaded",
                        ])
                    }
                }
            } else {
                for (_, record) in self.terminalRecords where record.state == "succeeded" {
                    assets.append(self.availableAssetMap(record: record))
                }
            }

            let map: [String: Any] = [
                "phase": Self.phase,
                "pass": true,
                "assets": assets,
                "raw": "status=OK;assetCount=\(assets.count)",
            ]
            DispatchQueue.main.async { result(map) }
        }
    }

    /// Field names include both `bytesDownloaded` (per this phase's stated
    /// native contract) and `downloadedBytes` (consumed by the current
    /// VGStreamingOfflineAssetAvailability.fromMap parser) so the map is
    /// correctly picked up by the existing public Dart model.
    private func availableAssetMap(record: VGStreamingOfflineAssetRecord) -> [String: Any] {
        var map: [String: Any] = [
            "sourceKey": record.sourceKey,
            "requestId": record.requestId,
            "isPlayableOffline": true,
            "state": "available",
            "bytesDownloaded": record.bytesDownloaded,
            "downloadedBytes": record.bytesDownloaded,
        ]
        if let assetUri = record.assetUri { map["assetUri"] = assetUri.absoluteString }
        if let total = record.totalBytes { map["totalBytes"] = total }
        return map
    }

    // MARK: - Dispose / shutdown

    func invalidateAndCancel() {
        workerQueue.async { [weak self] in
            guard let self = self else { return }
            for record in self.activeRecords.values {
                record.task?.cancel()
                record.state = "cancelled"
                record.errorMessage = "manager_shutdown"
                record.raw = "status=CANCELLED;requestId=\(record.requestId);reason=manager_shutdown"
                self.persistRecord(record)
            }
            self.activeRecords.removeAll()
            self.terminalRecords.removeAll()
            self.terminalOrder.removeAll()
            self.finishedLocations.removeAll()
            self.succeededRequestIdBySourceKey.removeAll()
            self._session?.invalidateAndCancel()
            self._session = nil
        }
    }

    // MARK: - Background relaunch reconciliation (Phase 4C6H3F)

    /// Package-internal wake/reconcile entrypoint for background relaunch.
    /// Called by VGStreamingOfflineBackgroundSessionHandler from
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    ///
    /// Non-blocking: all work is dispatched onto workerQueue, so this call
    /// never blocks the main thread. Ensures the background
    /// AVAssetDownloadURLSession exists (which reconnects this process to any
    /// tasks the OS retained across relaunch), then reconciles OS task state
    /// against in-memory + persisted records. Idempotent — safe to call more
    /// than once (e.g. if the OS relaunches the app again before the first
    /// reconciliation drains).
    func wakeForBackgroundRelaunch() {
        workerQueue.async { [weak self] in
            guard let self = self else { return }
            let dlSession = self.session()
            dlSession.getAllTasks { [weak self] tasks in
                guard let self = self else { return }
                self.workerQueue.async {
                    self.reconcileOnWorker(withOSTasks: tasks)
                }
            }
        }
    }

    /// Must be called on workerQueue. Maps OS-reported tasks (from
    /// `getAllTasks`) by `taskDescription` (== requestId, set at task-start
    /// time) and reconciles them against in-memory active records and the
    /// persisted catalog:
    ///   - a known active record whose OS task still exists is reattached;
    ///   - a persisted active (queued/running) entry not yet in memory is
    ///     reattached if its OS task exists, otherwise marked terminal
    ///     failed with a clear diagnostic reason;
    ///   - an in-memory active record with no matching OS task is stale and
    ///     is marked terminal failed rather than left stuck;
    ///   - succeeded/failed/cancelled records already loaded are untouched.
    private func reconcileOnWorker(withOSTasks tasks: [URLSessionTask]) {
        var taskByRequestId: [String: AVAssetDownloadTask] = [:]
        for task in tasks {
            guard let assetTask = task as? AVAssetDownloadTask,
                  let reqId = assetTask.taskDescription, !reqId.isEmpty
            else { continue }
            taskByRequestId[reqId] = assetTask
        }

        for (reqId, record) in activeRecords {
            if let task = taskByRequestId[reqId] {
                record.task = task
            }
        }

        let persistedEntries = catalog.load()
        for entry in persistedEntries {
            guard activeRecords[entry.requestId] == nil, terminalRecords[entry.requestId] == nil else { continue }
            guard entry.state == "queued" || entry.state == "running" else { continue }

            let record = VGStreamingOfflineAssetRecord.restoringFromCatalog(entry)
            if let task = taskByRequestId[entry.requestId] {
                record.task = task
                activeRecords[entry.requestId] = record
            } else {
                record.task = nil
                record.state = "failed"
                record.errorMessage = "interrupted_no_os_task_on_relaunch"
                record.raw = "status=FAILED;requestId=\(entry.requestId)" +
                             ";reason=interrupted_no_os_task_on_relaunch;source=background_relaunch_reconcile"
                retainTerminal(record)
                persistRecord(record)
            }
        }

        // Collect stale ids first — mutating `activeRecords` while iterating
        // over it is unsafe under Swift's exclusivity rules.
        var staleRequestIds: [String] = []
        for (reqId, record) in activeRecords where taskByRequestId[reqId] == nil {
            record.state = "failed"
            record.errorMessage = "interrupted_no_os_task_on_relaunch"
            record.raw = "status=FAILED;requestId=\(reqId)" +
                         ";reason=interrupted_no_os_task_on_relaunch;source=background_relaunch_reconcile"
            record.task = nil
            retainTerminal(record)
            persistRecord(record)
            staleRequestIds.append(reqId)
        }
        for reqId in staleRequestIds {
            activeRecords.removeValue(forKey: reqId)
        }
    }
}

// MARK: - AVAssetDownloadDelegate

extension VGStreamingOfflineAssetManager: AVAssetDownloadDelegate {

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
            for (_, record) in self.activeRecords where record.task === assetDownloadTask {
                // AVAssetDownloadTask reports time-range progress, not raw
                // byte counts; project onto a synthetic 0..1_000_000 scale
                // (mirrors VGStreamingCacheManager's prewarm progress model)
                // so bytesDownloaded/totalBytes still express a fraction.
                record.bytesDownloaded = Int64(fraction * 1_000_000)
                record.totalBytes = 1_000_000
                record.state = "running"
                record.raw = "status=RUNNING;requestId=\(record.requestId)" +
                             ";fraction=\(String(format: "%.3f", fraction))"
                self.persistRecord(record)
                break
            }
        }
    }

    @available(iOS 10.0, *)
    func urlSession(
        _ session: URLSession,
        assetDownloadTask: AVAssetDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        workerQueue.async { [weak self] in
            guard let self = self else { return }
            let reqId = self.activeRecords.first(where: { $0.value.task === assetDownloadTask })?.key
                ?? self.terminalRecords.first(where: { $0.value.task === assetDownloadTask })?.key
            guard let reqId = reqId else { return }
            self.finishedLocations[reqId] = location
            if let record = self.activeRecords[reqId] {
                record.assetUri = location
                self.persistRecord(record)
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
            for (reqId, record) in self.activeRecords where record.task === task {
                if let error = error {
                    let cancelled = (error as NSError).code == NSURLErrorCancelled
                    record.state = cancelled ? "cancelled" : "failed"
                    record.errorCode = String((error as NSError).code)
                    record.errorMessage = error.localizedDescription
                    record.raw = "status=\(record.state.uppercased());requestId=\(reqId)" +
                                 ";error=\(error.localizedDescription)"
                } else if let location = self.finishedLocations[reqId] ?? record.assetUri {
                    record.assetUri = location
                    record.state = "succeeded"
                    record.raw = "status=SUCCEEDED;requestId=\(reqId)"
                    self.succeededRequestIdBySourceKey[record.sourceKey] = reqId
                } else {
                    record.state = "failed"
                    record.errorMessage = "no_location_delivered"
                    record.raw = "status=FAILED;requestId=\(reqId);reason=no_location_delivered"
                }
                record.task = nil
                self.activeRecords.removeValue(forKey: reqId)
                self.retainTerminal(record)
                self.persistRecord(record)
                break
            }
        }
    }

    /// Called by the OS once all queued background session events (task
    /// completions, progress) have been delivered to the app following a
    /// background-relaunch invocation of
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    /// Drains the stored completion handler exactly once, on main, per
    /// Apple's documented contract. Ignores any session other than the
    /// package-owned offline HLS identifier.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard session.configuration.identifier == VGStreamingOfflineBackgroundSessionHandler.offlineHlsIdentifier else {
            return
        }
        // Hop through workerQueue first so every state/catalog mutation already
        // enqueued by prior delegate callbacks (didLoad/didFinishDownloadingTo/
        // didCompleteWithError) has run before we tell iOS events are drained.
        workerQueue.async {
            DispatchQueue.main.async {
                VGStreamingOfflineBackgroundSessionHandler.shared.drainCompletionHandler(
                    forIdentifier: VGStreamingOfflineBackgroundSessionHandler.offlineHlsIdentifier
                )
            }
        }
    }
}
