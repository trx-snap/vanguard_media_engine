// VGStreamingOfflineAssetCatalog.swift
// Phase 4C6H3F — iOS Offline HLS Package Background URLSession Recovery Substrate
//
// Best-effort, credential-safe persistence of minimal offline HLS
// acquisition bookkeeping so VGStreamingOfflineAssetManager can restore
// terminal/succeeded state and reconcile in-flight state across process
// relaunch (background URLSession relaunch, or a cold foreground launch
// after prior termination).
//
// Storage: <ApplicationSupport|Caches>/vanguard_streaming_offline_assets/catalog.json
// Writes are atomic: encode to a temp file in the same directory, then
// FileManager.replaceItemAt/moveItem into place — a crash or termination
// mid-write never leaves a truncated/corrupt catalog.json.
//
// P0 SECURITY INVARIANT: this catalog NEVER persists HTTP headers, cookies,
// bearer tokens, signed query strings, or raw authenticated URLs. Only a
// sanitized diagnostic source string (scheme + host + path; query and
// fragment always stripped) is stored. `sanitizedSourceOrigin(fromURI:)` is
// the sole sanctioned way to derive that string — callers MUST route the
// original request URI through it before constructing an entry.
//
// All I/O here runs synchronously on the caller's queue
// (VGStreamingOfflineAssetManager's workerQueue) — this type owns no queue
// of its own. Every method is non-throwing; failures are diagnostic-only
// and never propagate, per the "best-effort" contract — a persistence
// failure must never fail a foreground offline HLS operation.

import Foundation

/// One minimal, credential-safe, JSON-codable catalog entry.
struct VGStreamingOfflineAssetCatalogEntry: Codable, Equatable {
    let requestId: String
    let sourceKey: String
    /// Sanitized diagnostic source string only — see the P0 invariant above.
    /// Never the original (possibly authenticated) request URI.
    let sanitizedSourceOrigin: String
    var state: String
    var bytesDownloaded: Int64
    var totalBytes: Int64?
    let createdAtUnixMs: Int64
    var updatedAtUnixMs: Int64
    /// Local asset pointer stored as a path relative to the app's home
    /// directory (see VGStreamingOfflineAssetRecord.relativePath), so it
    /// remains resolvable even if the app container's absolute path changes
    /// across relaunch. `nil` until the OS has delivered a finished-download
    /// location for this request.
    var localAssetPointer: String?
}

private struct VGStreamingOfflineAssetCatalogFile: Codable {
    var entries: [VGStreamingOfflineAssetCatalogEntry]
}

final class VGStreamingOfflineAssetCatalog {

    static let shared = VGStreamingOfflineAssetCatalog()

    private static let directoryName = "vanguard_streaming_offline_assets"
    private static let fileName = "catalog.json"

    private init() {}

    // MARK: - Sanitization

    /// Strips scheme userinfo, query, and fragment, returning only
    /// `scheme://host/path`. Never returns the original (possibly
    /// authenticated) URL. Falls back to a fixed diagnostic placeholder for
    /// strings that cannot be parsed as a URL with a host.
    static func sanitizedSourceOrigin(fromURI uri: String) -> String {
        guard let url = URL(string: uri), let scheme = url.scheme, let host = url.host else {
            return "unparsed_source"
        }
        return "\(scheme)://\(host)\(url.path)"
    }

    // MARK: - Location

    private func catalogDirectoryURL() -> URL? {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let base = base else { return nil }
        return base.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    private func catalogFileURL() -> URL? {
        catalogDirectoryURL()?.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    // MARK: - Load

    /// Best-effort load. Returns an empty array on any failure (missing
    /// directory/file, corrupt JSON) — never throws.
    func load() -> [VGStreamingOfflineAssetCatalogEntry] {
        guard let fileURL = catalogFileURL(),
              FileManager.default.fileExists(atPath: fileURL.path)
        else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let file = try JSONDecoder().decode(VGStreamingOfflineAssetCatalogFile.self, from: data)
            return file.entries
        } catch {
            return []
        }
    }

    // MARK: - Save (atomic, full-replace)

    /// Best-effort atomic save of the full entry set. Failures are swallowed
    /// (diagnostic-only) per the best-effort contract.
    @discardableResult
    func save(_ entries: [VGStreamingOfflineAssetCatalogEntry]) -> Bool {
        guard let dirURL = catalogDirectoryURL(), let fileURL = catalogFileURL() else { return false }
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            let file = VGStreamingOfflineAssetCatalogFile(entries: entries)
            let data = try JSONEncoder().encode(file)

            let tempURL = dirURL.appendingPathComponent(".catalog-\(UUID().uuidString).tmp", isDirectory: false)
            try data.write(to: tempURL, options: .atomic)

            if FileManager.default.fileExists(atPath: fileURL.path) {
                _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: fileURL)
            }
            return true
        } catch {
            return false
        }
    }

    /// Best-effort upsert-by-requestId: loads the current catalog, replaces
    /// (or appends) the entry with matching `requestId`, and atomically
    /// saves the result. Intended for individual lifecycle transitions
    /// (queued/progress/finish/succeeded/failed/cancelled), not high-rate
    /// polling.
    @discardableResult
    func upsert(_ entry: VGStreamingOfflineAssetCatalogEntry) -> Bool {
        var entries = load()
        if let idx = entries.firstIndex(where: { $0.requestId == entry.requestId }) {
            entries[idx] = entry
        } else {
            entries.append(entry)
        }
        return save(entries)
    }

    /// Best-effort removal of the given requestIds from the persisted
    /// catalog. A no-op (returns `true`) if none of the ids are present.
    @discardableResult
    func remove(requestIds: Set<String>) -> Bool {
        guard !requestIds.isEmpty else { return true }
        var entries = load()
        let originalCount = entries.count
        entries.removeAll { requestIds.contains($0.requestId) }
        guard entries.count != originalCount else { return true }
        return save(entries)
    }

    /// Best-effort full clear — removes the catalog file entirely.
    @discardableResult
    func clearAll() -> Bool {
        guard let fileURL = catalogFileURL() else { return false }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            return false
        }
    }
}
