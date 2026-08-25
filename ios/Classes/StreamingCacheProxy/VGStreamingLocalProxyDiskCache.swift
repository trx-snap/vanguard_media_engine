// VGStreamingLocalProxyDiskCache.swift
// Phase 4C6H2B — iOS local proxy disk read-through cache storage & cache-hit substrate
//
// Design contract:
//   - Cache key: SHA-256 hex of the originalURL.absoluteString (full URL, no stripping).
//   - File layout: <sha256>.data  (raw body bytes)
//                  <sha256>.meta  (JSON, no URLs/headers/tokens/hosts — see VGDiskCacheMeta)
//   - Write path: body → temp file → atomic rename → then write meta.
//   - Read path:  read meta → read data → serve; metadata drives Content-Type / Content-Length.
//   - Only eligible if: GET, HTTP 200, no client Range header, non-manifest, body > 0,
//     body.count == upstream Content-Length (when present), body.count <= kMaxBodyBytes.
//   - Cache directory excluded from iCloud backup via resource value.
//   - All internal state protected by a serial DispatchQueue.
//   - Package-internal; no public Dart surface.

import CryptoKit
import Foundation

// MARK: - Constants

private let kMaxBodyBytes = 16 * 1024 * 1024   // 16 MiB conservative ceiling

// MARK: - Metadata (privacy-safe)

/// On-disk JSON blob stored alongside each cached body.
/// Must NOT contain: URLs, headers, cookies, tokens, hostnames, or filesystem paths.
private struct VGDiskCacheMeta: Codable {
    /// HTTP status code from upstream (always 200 in this slice).
    let statusCode: Int
    /// Upstream Content-Type value.  Only the MIME token is stored; no host data.
    let contentType: String
    /// Body length in bytes as verified at write time.
    let contentLength: Int
    /// Unix milliseconds at which this entry was written.
    let storedAtUnixMs: Int64
}

// MARK: - DiskCache

/// Package-internal singleton.  Thread-safe via serial queue.
final class VGStreamingLocalProxyDiskCache {

    static let shared = VGStreamingLocalProxyDiskCache()
    private init() {}

    // Serial queue — all FS operations run here; prevents torn reads/writes.
    private let queue = DispatchQueue(label: "vg.proxy.diskcache", qos: .utility)

    // Lazy-initialised cache directory.  Nil if creation fails (silently degrades to pass-through).
    private var _cacheDir: URL?
    private var _cacheDirResolved = false

    // MARK: - Cache directory

    private func cacheDirectory() -> URL? {
        // Already resolved (may be nil if setup failed).
        if _cacheDirResolved { return _cacheDir }
        _cacheDirResolved = true

        guard let cachesBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = cachesBase.appendingPathComponent("vanguard_playback_proxy_cache", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            // Exclude from iCloud backup.
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableDir = dir
            try? mutableDir.setResourceValues(resourceValues)
        } catch {
            return nil
        }
        _cacheDir = dir
        return dir
    }

    // MARK: - Key derivation

    /// Returns the SHA-256 hex string of the URL's absolute string.
    func cacheKey(for url: URL) -> String {
        let data = Data(url.absoluteString.utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Cache eligibility

    /// Returns true if this response is eligible to be cached.
    ///
    /// Rules (frozen):
    ///  - method == GET
    ///  - clientHasRange == false (no Range header from client)
    ///  - statusCode == 200
    ///  - not a HLS manifest (content type or path extension)
    ///  - body.count > 0
    ///  - body.count <= kMaxBodyBytes
    ///  - if upstream Content-Length was present, body.count must match it exactly
    func isCacheable(
        method: String,
        clientHasRange: Bool,
        statusCode: Int,
        contentType: String,
        originalURL: URL,
        body: Data,
        upstreamContentLength: Int?
    ) -> Bool {
        guard method == "GET" else { return false }
        guard !clientHasRange else { return false }
        guard statusCode == 200 else { return false }

        // Never cache HLS manifests.
        let isManifest = vgIsHLSContentType(contentType) ||
            originalURL.lastPathComponent.hasSuffix(".m3u8") ||
            originalURL.lastPathComponent.hasSuffix(".m3u")
        guard !isManifest else { return false }

        guard body.count > 0 else { return false }
        guard body.count <= kMaxBodyBytes else { return false }

        // If upstream stated a Content-Length, the body must exactly match.
        if let expectedLength = upstreamContentLength {
            guard body.count == expectedLength else { return false }
        }

        return true
    }

    // MARK: - Read (cache hit)

    /// Returns cached body data and content-type on a hit; nil on a miss.
    ///
    /// Runs synchronously; uses an internal serial queue for exclusivity.
    func read(for url: URL) -> (body: Data, contentType: String)? {
        var result: (Data, String)?
        queue.sync {
            result = self._read(for: url)
        }
        return result
    }

    private func _read(for url: URL) -> (Data, String)? {
        guard let dir = cacheDirectory() else { return nil }
        let key = cacheKey(for: url)
        let dataURL = dir.appendingPathComponent("\(key).data")
        let metaURL = dir.appendingPathComponent("\(key).meta")

        guard FileManager.default.fileExists(atPath: dataURL.path),
              FileManager.default.fileExists(atPath: metaURL.path) else {
            return nil
        }

        guard let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(VGDiskCacheMeta.self, from: metaData) else {
            return nil
        }

        guard let body = try? Data(contentsOf: dataURL) else {
            return nil
        }

        // Integrity check: stored contentLength must match actual file size.
        guard body.count == meta.contentLength, body.count > 0 else {
            return nil
        }

        return (body, meta.contentType)
    }

    // MARK: - Write (cache store)

    /// Atomically stores a cacheable response body.
    ///
    /// Write strategy:
    ///  1. Write body to a temp file in the same directory (same filesystem → atomic rename).
    ///  2. Replace .data file atomically.
    ///  3. Write .meta file (plain replacement; harmless if partial since .data integrity wins).
    ///  4. On any failure, remove the temp file.
    ///
    /// - Returns: true if the entry was successfully stored.
    @discardableResult
    func store(body: Data, contentType: String, statusCode: Int, for url: URL) -> Bool {
        var stored = false
        queue.sync {
            stored = self._store(body: body, contentType: contentType, statusCode: statusCode, for: url)
        }
        return stored
    }

    private func _store(body: Data, contentType: String, statusCode: Int, for url: URL) -> Bool {
        guard let dir = cacheDirectory() else { return false }
        guard body.count > 0, body.count <= kMaxBodyBytes else { return false }

        let key = cacheKey(for: url)
        let dataURL = dir.appendingPathComponent("\(key).data")
        let metaURL = dir.appendingPathComponent("\(key).meta")
        // Use a UUID suffix so concurrent stores for the same key never share a temp file.
        let tempURL = dir.appendingPathComponent("\(key).tmp.\(UUID().uuidString)")

        // 1. Write to temp.
        do {
            try body.write(to: tempURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }

        // 2. Atomic replace .data.
        do {
            _ = try FileManager.default.replaceItemAt(
                dataURL,
                withItemAt: tempURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } catch {
            // replaceItemAt may fail when destination doesn't exist yet; fall back to move.
            do {
                if FileManager.default.fileExists(atPath: dataURL.path) {
                    try FileManager.default.removeItem(at: dataURL)
                }
                try FileManager.default.moveItem(at: tempURL, to: dataURL)
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                return false
            }
        }

        // 3. Write metadata.  Failure here is treated as a store failure: the .data file is
        //    removed so it cannot inflate totalCacheSizeBytes or produce a broken cache hit
        //    (read() requires both .data and .meta to exist and be valid).
        let meta = VGDiskCacheMeta(
            statusCode: statusCode,
            contentType: contentType,
            contentLength: body.count,
            storedAtUnixMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        guard let metaBytes = try? JSONEncoder().encode(meta) else {
            try? FileManager.default.removeItem(at: dataURL)
            return false
        }
        do {
            try metaBytes.write(to: metaURL, options: .atomic)
        } catch {
            // Meta write failed: roll back the committed .data file to keep the pair consistent.
            try? FileManager.default.removeItem(at: dataURL)
            return false
        }

        return true
    }

    // MARK: - Disk size

    /// Returns the total bytes used by cached .data files.  Synchronous.
    func totalCacheSizeBytes() -> Int {
        var total = 0
        queue.sync {
            total = self._totalCacheSizeBytes()
        }
        return total
    }

    private func _totalCacheSizeBytes() -> Int {
        guard let dir = cacheDirectory() else { return 0 }
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total = 0
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "data" else { continue }
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += size
            }
        }
        return total
    }

    // MARK: - Clear (package-internal)

    /// Removes all entries from the proxy disk-cache directory.
    ///
    /// Runs synchronously on the disk-cache serial queue.
    /// Only direct children of the managed cache directory are removed — broad filesystem
    /// paths are never touched.
    ///
    /// - Returns: Privacy-safe numeric stats only.  No URLs, hostnames, headers, tokens,
    ///   query strings, or filesystem paths are included.
    func clearProxyDiskCache() -> (beforeBytes: Int, afterBytes: Int, removedResourceCount: Int, failedResourceCount: Int) {
        var result = (beforeBytes: 0, afterBytes: 0, removedResourceCount: 0, failedResourceCount: 0)
        queue.sync {
            result = self._clearProxyDiskCache()
        }
        return result
    }

    /// Must be called on `queue`.
    private func _clearProxyDiskCache() -> (beforeBytes: Int, afterBytes: Int, removedResourceCount: Int, failedResourceCount: Int) {
        // Measure before-bytes (data files only, matching _totalCacheSizeBytes convention).
        let before = _totalCacheSizeBytes()

        guard let dir = cacheDirectory() else {
            // Cache directory never existed or failed to create — nothing to remove.
            return (beforeBytes: 0, afterBytes: 0, removedResourceCount: 0, failedResourceCount: 0)
        }

        // Enumerate only direct children of the managed cache directory.
        // skipsSubdirectoryDescendants ensures we only touch top-level entries and
        // never accidentally walk into unexpected nested trees.
        let children = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []

        var removed = 0
        var failed  = 0
        for childURL in children {
            do {
                try FileManager.default.removeItem(at: childURL)
                removed += 1
            } catch {
                failed += 1
            }
        }

        // Reset resolved-directory flag so that a subsequent read or write
        // re-creates the directory cleanly if needed.
        _cacheDirResolved = false
        _cacheDir = nil

        let after = _totalCacheSizeBytes()
        return (beforeBytes: before, afterBytes: after, removedResourceCount: removed, failedResourceCount: failed)
    }
}

// MARK: - HLS type helper (package-internal; matches VGStreamingLocalProxyConnection)

func vgIsHLSContentType(_ ct: String) -> Bool {
    let lower = ct.lowercased()
    return lower.contains("mpegurl") || lower.contains("m3u")
}
