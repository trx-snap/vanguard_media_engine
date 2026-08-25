// VGStreamingLocalProxyConnection.swift
// Phase 4C6H2B — iOS local proxy disk read-through cache storage & cache-hit substrate
//
// Inspired by KTVHTTPCache local media proxy/cache architecture.
// Rewritten and hardened for Vanguard; no external Pod dependency.
//
// Per-connection HTTP/1.1 handler:
//   - Reads exactly one request per NWConnection instance (no keep-alive in this slice).
//   - Max request header buffer: 16 KiB.
//   - Accepted methods: GET, HEAD only.
//   - Looks up token in registry; returns 404 for unknown tokens.
//   - Checks VGStreamingLocalProxyDiskCache for eligible GET requests before upstream.
//   - Forwards Range header to upstream; strips hop-by-hop headers from upstream response.
//   - Buffers response body in memory; stores eligible bodies to disk cache.
//   - Rewrites HLS manifests via VGStreamingLocalProxyHLSRewriter (never cached).
//   - Never logs caller HTTP headers.

import Foundation
import Network

// MARK: - Hop-by-hop headers (RFC 7230 §6.1)

private let kHopByHopHeaders: Set<String> = [
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade"
]

// MARK: - Connection handler

final class VGStreamingLocalProxyConnection {

    private let connection:   NWConnection
    private let proxyBaseURL: URL          // e.g. http://127.0.0.1:PORT/vanguard/
    private let registry:     VGStreamingLocalProxyRegistry
    private let session:      URLSession

    /// Called exactly once on the server queue when this connection is fully
    /// finished (response sent, error path, or EOF/cancel).  The server uses
    /// this to release its strong reference and prevent a memory leak.
    private let onComplete: () -> Void

    private static let maxHeaderBytes = 16 * 1024  // 16 KiB

    init(
        connection:   NWConnection,
        proxyBaseURL: URL,
        registry:     VGStreamingLocalProxyRegistry,
        onComplete:   @escaping () -> Void
    ) {
        self.connection   = connection
        self.proxyBaseURL = proxyBaseURL
        self.registry     = registry
        self.onComplete   = onComplete
        // Dedicated ephemeral session; no cookies, no URLCache — disk cache is managed separately.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Start

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connection.cancel()
                self?.onComplete()
            default: break
            }
        }
        connection.start(queue: queue)
        receiveRequest(accumulated: Data())
    }

    // MARK: - Request accumulation

    private func receiveRequest(accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isEOF, error in
            guard let self = self else { return }
            if let error = error {
                // Connection error — nothing to reply to.
                _ = error
                self.connection.cancel()
                self.onComplete()
                return
            }
            var buf = accumulated
            if let data = data { buf.append(data) }
            // Check for end of HTTP headers (blank line)
            if let headersEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buf[buf.startIndex..<headersEnd.lowerBound]
                let bodyStart  = buf[headersEnd.upperBound...]
                self.handleRequest(headerData: headerData, remainingBody: Data(bodyStart))
                return
            }
            // Simple \n\n fallback
            if let headersEnd = buf.range(of: Data("\n\n".utf8)) {
                let headerData = buf[buf.startIndex..<headersEnd.lowerBound]
                self.handleRequest(headerData: headerData, remainingBody: Data())
                return
            }
            if buf.count > Self.maxHeaderBytes {
                self.sendSimpleResponse(status: 400, reason: "Bad Request", body: Data())
                return
            }
            if isEOF {
                self.connection.cancel()
                self.onComplete()
                return
            }
            self.receiveRequest(accumulated: buf)
        }
    }

    // MARK: - Request parsing + dispatch

    private func handleRequest(headerData: Data, remainingBody: Data) {
        guard let headerString = String(data: headerData, encoding: .utf8) ?? String(data: headerData, encoding: .isoLatin1) else {
            sendSimpleResponse(status: 400, reason: "Bad Request", body: Data())
            return
        }
        let lines = headerString.components(separatedBy: "\r\n").flatMap { $0.components(separatedBy: "\n") }
        guard !lines.isEmpty else {
            sendSimpleResponse(status: 400, reason: "Bad Request", body: Data())
            return
        }
        // Parse request line
        let requestLineParts = lines[0].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard requestLineParts.count >= 2 else {
            sendSimpleResponse(status: 400, reason: "Bad Request", body: Data())
            return
        }
        let method  = requestLineParts[0].uppercased()
        let rawPath = requestLineParts[1]

        guard method == "GET" || method == "HEAD" else {
            sendSimpleResponse(status: 405, reason: "Method Not Allowed", body: Data())
            return
        }

        // Parse headers into dictionary (lower-cased keys)
        var requestHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty else { break }
            if let colonIdx = line.firstIndex(of: ":") {
                let key   = line[line.startIndex..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
                requestHeaders[key] = value
            }
        }

        // Extract token from path: /vanguard/<token>
        let pathComponents = rawPath.components(separatedBy: "?")[0].split(separator: "/").map(String.init)
        // Expect ["vanguard", "<token>"]
        guard pathComponents.count >= 2, pathComponents[0] == "vanguard" else {
            sendSimpleResponse(status: 404, reason: "Not Found", body: Data())
            return
        }
        let token = pathComponents[1]

        guard let record = registry.lookup(routeId: token) else {
            sendSimpleResponse(status: 404, reason: "Not Found", body: Data())
            return
        }

        // Phase 4C6H2B — disk cache read-through.
        // For eligible GET requests with no Range header, check the disk cache first.
        let clientRangeHeader = requestHeaders["range"]
        let isGetMethod = (method == "GET")
        let hasRange    = (clientRangeHeader != nil)

        if isGetMethod, !hasRange {
            let diskCache = VGStreamingLocalProxyDiskCache.shared
            // Check eligibility based on URL only (manifest guard; content type known only after fetch).
            let lastComp = record.originalURL.lastPathComponent
            let urlLooksLikeManifest = lastComp.hasSuffix(".m3u8") || lastComp.hasSuffix(".m3u")
            if !urlLooksLikeManifest, let hit = diskCache.read(for: record.originalURL) {
                // Cache hit — serve directly without opening upstream.
                registry.recordCacheHit(routeId: record.routeId, bytes: hit.body.count)
                let headers: [(String, String)] = [
                    ("Content-Type",   hit.contentType),
                    ("Content-Length", "\(hit.body.count)")
                ]
                sendHTTPResponse(statusCode: 200, headers: headers, body: hit.body)
                return
            }
        }

        fetchUpstream(record: record, method: method, clientRangeHeader: clientRangeHeader)
    }

    // MARK: - Upstream fetch (URLSession, memory-buffered)

    private func fetchUpstream(
        record: VGStreamingLocalProxyRouteRecord,
        method: String,
        clientRangeHeader: String?
    ) {
        var request = URLRequest(url: record.originalURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method

        // Merge caller headers (auth, cookie identity) — never log them.
        if let headers = record.httpHeaders {
            for (key, value) in headers {
                // Never forward Host; skip hop-by-hop.
                let lk = key.lowercased()
                if lk == "host" { continue }
                if kHopByHopHeaders.contains(lk) { continue }
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        // Forward Range header from client request.
        if let rangeHeader = clientRangeHeader {
            request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        }

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                _ = error
                self.sendSimpleResponse(status: 502, reason: "Bad Gateway", body: Data())
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                self.sendSimpleResponse(status: 502, reason: "Bad Gateway", body: Data())
                return
            }

            var body = data ?? Data()
            let statusCode = httpResponse.statusCode
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"

            // Update upstream-fetch metrics.
            self.registry.recordFetch(routeId: record.routeId, bytes: body.count)

            // HLS manifest rewriting (manifests are never cached).
            let isManifest = vgIsHLSContentType(contentType) ||
                record.originalURL.lastPathComponent.hasSuffix(".m3u8") ||
                record.originalURL.lastPathComponent.hasSuffix(".m3u")

            if isManifest, let text = String(data: body, encoding: .utf8) {
                let rewritten = VGStreamingLocalProxyHLSRewriter.rewrite(
                    manifestText:   text,
                    manifestURL:    record.originalURL,
                    proxyBaseURL:   self.proxyBaseURL,
                    callerHeaders:  record.httpHeaders,
                    formatHint:     record.formatHint,
                    networkProfile: record.networkProfile,
                    registry:       self.registry,
                    ownerRouteId:   record.ownerRouteId
                )
                body = Data(rewritten.utf8)
            }

            // Phase 4C6H2B — disk cache store for eligible non-manifest GET 200 responses.
            // This runs before building the response headers so body.count is final.
            if !isManifest, method == "GET", clientRangeHeader == nil, statusCode == 200 {
                let upstreamCLString = httpResponse.value(forHTTPHeaderField: "Content-Length")
                let upstreamCL: Int? = upstreamCLString.flatMap {
                    Int($0.trimmingCharacters(in: .whitespaces))
                }
                let diskCache = VGStreamingLocalProxyDiskCache.shared
                if diskCache.isCacheable(
                    method:                method,
                    clientHasRange:        clientRangeHeader != nil,
                    statusCode:            statusCode,
                    contentType:           contentType,
                    originalURL:           record.originalURL,
                    body:                  body,
                    upstreamContentLength: upstreamCL
                ) {
                    if diskCache.store(body: body, contentType: contentType, statusCode: statusCode, for: record.originalURL) {
                        self.registry.recordCacheStore(routeId: record.routeId, bytes: body.count)
                    }
                }
            }

            // Build stripped response headers.
            var responseHeaders: [(String, String)] = []
            responseHeaders.append(("Content-Type", contentType))

            // For HEAD, URLSession returns an empty body even when upstream sent Content-Length.
            // Reflect the upstream Content-Length so clients (AVPlayer) honour it correctly.
            // For GET, use body.count which accounts for any HLS rewrite already applied above.
            let contentLength: Int
            if method == "HEAD" {
                if let upstreamCL = httpResponse.value(forHTTPHeaderField: "Content-Length"),
                   let parsed = Int(upstreamCL.trimmingCharacters(in: .whitespaces)) {
                    contentLength = parsed
                } else {
                    contentLength = 0
                }
            } else {
                contentLength = body.count
            }
            responseHeaders.append(("Content-Length", "\(contentLength)"))

            // Forward upstream status-range headers (206 partial content support).
            if let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range") {
                responseHeaders.append(("Content-Range", contentRange))
            }
            if let acceptRanges = httpResponse.value(forHTTPHeaderField: "Accept-Ranges") {
                responseHeaders.append(("Accept-Ranges", acceptRanges))
            }

            // For HEAD, send headers only.
            let responseBody = (method == "HEAD") ? Data() : body
            self.sendHTTPResponse(statusCode: statusCode, headers: responseHeaders, body: responseBody)
        }.resume()
    }

    // MARK: - Response senders

    private func sendHTTPResponse(statusCode: Int, headers: [(String, String)], body: Data) {
        let reason = httpReasonPhrase(statusCode)
        var header = "HTTP/1.1 \(statusCode) \(reason)\r\n"
        header += "Connection: close\r\n"
        for (key, value) in headers {
            header += "\(key): \(value)\r\n"
        }
        header += "\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
            self?.onComplete()
        })
    }

    private func sendSimpleResponse(status: Int, reason: String, body: Data) {
        let header = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
            self?.onComplete()
        })
    }

    // MARK: - Helpers

    private func httpReasonPhrase(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 502: return "Bad Gateway"
        default:  return "Unknown"
        }
    }
}
