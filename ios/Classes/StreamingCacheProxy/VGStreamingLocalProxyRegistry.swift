// VGStreamingLocalProxyRegistry.swift
// Phase 4C6H2A — iOS hardened local loopback streaming proxy substrate
//
// Inspired by KTVHTTPCache local media proxy/cache architecture.
// Rewritten and hardened for Vanguard; no external Pod dependency.
//
// Registry contract:
//   - Tokens are high-entropy UUIDs; the original URL never appears in the proxy path.
//   - Thread-safe: all mutations serialised on `queue`.
//   - Unknown / released tokens respond 404.
//
// LL-HLS stable-token contract (Phase 4C6H2A fix):
//   - Each root route owns itself (ownerRouteId == routeId).
//   - Child routes created while rewriting a manifest inherit the root's ownerRouteId.
//   - Re-inserting the same (ownerRouteId, originalURL) pair returns the existing token,
//     so AVPlayer sees the same local-proxy path for the same segment/part URL across
//     successive LL-HLS playlist reloads (fixing -12312 Media Entry URL mismatch).
//   - Releasing a root route atomically removes the root and all child routes in that group.

import Foundation

// MARK: - Route record

/// Per-route data stored in the registry.
struct VGStreamingLocalProxyRouteRecord {
    let routeId:        String            // opaque UUID
    let ownerRouteId:   String            // root of this group; equals routeId for root routes
    let originalURL:    URL
    let httpHeaders:    [String: String]? // caller auth/cookie headers — never logged
    let formatHint:     String            // "AUTO" | "HLS"
    let networkProfile: String            // normalised profile string
    let createdAt:      Date

    var requestCount:   Int = 0
    var bytesFetched:   Int = 0           // upstream bytes received (pass-through slice)
    // Phase 4C6H2B — disk cache counters
    var cacheHitCount:   Int = 0          // responses served from disk cache
    var cacheMissCount:  Int = 0          // eligible upstream fetches stored to disk cache
    var cacheBytesRead:  Int = 0          // body bytes served from disk cache
    var cacheStoreBytes: Int = 0          // body bytes written to disk cache
}

/// Route handle returned to callers.
struct VGStreamingLocalProxyRoute {
    let routeId:  String
    let proxyURL: URL
}

// MARK: - Registry

/// Package-internal singleton.  All entry points are thread-safe.
final class VGStreamingLocalProxyRegistry {

    static let shared = VGStreamingLocalProxyRegistry()
    private init() {}

    private let queue = DispatchQueue(label: "vg.proxy.registry", attributes: .concurrent)

    /// Primary route storage keyed by token.
    private var routes: [String: VGStreamingLocalProxyRouteRecord] = [:]

    /// Stable-token index for child routes.
    /// Key format: "<ownerRouteId>\u{1E}<originalURL.absoluteString>"
    /// U+001E (Record Separator) is not a valid URL character and cannot collide with URL content.
    private var stableIndex: [String: String] = [:]

    // MARK: Insert (root)

    /// Insert a new **root** route.  Always allocates a fresh token.
    ///
    /// The root route owns itself (`ownerRouteId == routeId`).
    /// Call this once per playback open from `VGStreamingLocalProxyServer.proxiedURL`.
    func insert(
        originalURL:    URL,
        httpHeaders:    [String: String]?,
        formatHint:     String,
        networkProfile: String
    ) -> String {
        let token = UUID().uuidString
        let record = VGStreamingLocalProxyRouteRecord(
            routeId:        token,
            ownerRouteId:   token,          // root owns itself
            originalURL:    originalURL,
            httpHeaders:    httpHeaders,
            formatHint:     formatHint,
            networkProfile: networkProfile,
            createdAt:      Date()
        )
        queue.sync(flags: .barrier) {
            self.routes[token] = record
            // Root routes are not entered in stableIndex — each playback open is unique.
        }
        return token
    }

    // MARK: Insert (child – stable dedup)

    /// Insert (or look up) a **child** route for `originalURL` under `ownerRouteId`.
    ///
    /// If a child with the same `(ownerRouteId, originalURL)` was already registered,
    /// the existing token is returned without creating a new record.  This guarantees
    /// that AVPlayer sees the same local-proxy path for the same segment/part URL across
    /// successive LL-HLS playlist reloads.
    ///
    /// Signed query strings are included verbatim in the identity key; no stripping occurs.
    ///
    /// - Parameters:
    ///   - originalURL:    The upstream URL to proxy.
    ///   - httpHeaders:    Auth/cookie headers — stored but never logged.
    ///   - formatHint:     Forwarded from the parent route.
    ///   - networkProfile: Forwarded from the parent route.
    ///   - ownerRouteId:   The root route's token.
    /// - Returns: The (possibly reused) proxy token for `originalURL`.
    func insertChild(
        originalURL:    URL,
        httpHeaders:    [String: String]?,
        formatHint:     String,
        networkProfile: String,
        ownerRouteId:   String
    ) -> String {
        let indexKey = ownerRouteId + "\u{1E}" + originalURL.absoluteString

        // Fast path — no barrier needed for a read.
        var existing: String?
        queue.sync { existing = self.stableIndex[indexKey] }
        if let token = existing { return token }

        // Slow path — allocate then commit under barrier (double-checked).
        let token = UUID().uuidString
        let record = VGStreamingLocalProxyRouteRecord(
            routeId:        token,
            ownerRouteId:   ownerRouteId,
            originalURL:    originalURL,
            httpHeaders:    httpHeaders,
            formatHint:     formatHint,
            networkProfile: networkProfile,
            createdAt:      Date()
        )
        queue.sync(flags: .barrier) {
            // Another writer may have raced us; honour theirs if present.
            if let raced = self.stableIndex[indexKey] {
                existing = raced
                return
            }
            self.routes[token] = record
            self.stableIndex[indexKey] = token
        }
        return existing ?? token
    }

    // MARK: Lookup

    func lookup(routeId: String) -> VGStreamingLocalProxyRouteRecord? {
        var result: VGStreamingLocalProxyRouteRecord?
        queue.sync { result = self.routes[routeId] }
        return result
    }

    // MARK: Metrics update

    func recordFetch(routeId: String, bytes: Int) {
        queue.async(flags: .barrier) {
            guard var r = self.routes[routeId] else { return }
            r.requestCount += 1
            r.bytesFetched += bytes
            self.routes[routeId] = r
        }
    }

    /// Record a disk cache hit for `routeId`.
    func recordCacheHit(routeId: String, bytes: Int) {
        queue.async(flags: .barrier) {
            guard var r = self.routes[routeId] else { return }
            r.cacheHitCount  += 1
            r.cacheBytesRead += bytes
            self.routes[routeId] = r
        }
    }

    /// Record a successful disk cache store for `routeId`.
    func recordCacheStore(routeId: String, bytes: Int) {
        queue.async(flags: .barrier) {
            guard var r = self.routes[routeId] else { return }
            r.cacheMissCount  += 1
            r.cacheStoreBytes += bytes
            self.routes[routeId] = r
        }
    }

    // MARK: Release

    /// Release a root route and **all child routes in its group** synchronously.
    ///
    /// Idempotent: releasing an unknown or already-released route is a no-op.
    func release(routeId: String) {
        queue.sync(flags: .barrier) {
            guard let root = self.routes[routeId] else { return }
            let ownerRouteId = root.ownerRouteId

            // Remove all route records belonging to this group.
            let memberTokens = self.routes.compactMap { (token, record) -> String? in
                record.ownerRouteId == ownerRouteId ? token : nil
            }
            for token in memberTokens {
                self.routes.removeValue(forKey: token)
            }

            // Remove all stable-index entries for this owner.
            let prefix = ownerRouteId + "\u{1E}"
            let staleKeys = self.stableIndex.keys.filter { $0.hasPrefix(prefix) }
            for key in staleKeys {
                self.stableIndex.removeValue(forKey: key)
            }
        }
    }

    // MARK: Metrics snapshot

    /// Returns metrics **aggregated over the root route and all its child routes**.
    ///
    /// `requestCount` and `bytesFetched` sum over every record whose
    /// `ownerRouteId == routeId`, so existing playback telemetry automatically
    /// reflects child playlist/segment reads without caller changes.
    /// `routeCount` is the total number of routes in the group (root + children).
    func metrics(routeId: String) -> [String: Any] {
        var root: VGStreamingLocalProxyRouteRecord?
        var totalRequests    = 0
        var totalBytes       = 0
        var routeCount       = 0
        var cacheHitCount    = 0
        var cacheMissCount   = 0
        var cacheBytesRead   = 0
        var cacheStoreBytes  = 0

        queue.sync {
            guard let r = self.routes[routeId] else { return }
            root = r
            let ownerRouteId = r.ownerRouteId
            for record in self.routes.values where record.ownerRouteId == ownerRouteId {
                totalRequests   += record.requestCount
                totalBytes      += record.bytesFetched
                routeCount      += 1
                cacheHitCount   += record.cacheHitCount
                cacheMissCount  += record.cacheMissCount
                cacheBytesRead  += record.cacheBytesRead
                cacheStoreBytes += record.cacheStoreBytes
            }
        }

        guard let r = root else {
            return ["routeId": routeId, "active": false]
        }
        return [
            "routeId":        r.routeId,
            "active":         true,
            "formatHint":     r.formatHint,
            "networkProfile": r.networkProfile,
            "requestCount":   totalRequests,
            "bytesFetched":   totalBytes,
            "routeCount":     routeCount,
            "ageSeconds":     -r.createdAt.timeIntervalSinceNow,
            // Phase 4C6H2B disk cache counters
            "cacheHitCount":   cacheHitCount,
            "cacheMissCount":  cacheMissCount,
            "cacheBytesRead":  cacheBytesRead,
            "cacheStoreBytes": cacheStoreBytes
        ]
    }
}
