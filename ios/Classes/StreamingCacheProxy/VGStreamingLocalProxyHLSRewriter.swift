// VGStreamingLocalProxyHLSRewriter.swift
// Phase 4C6H2A — iOS hardened local loopback streaming proxy substrate
//
// Inspired by KTVHTTPCache local media proxy/cache architecture.
// Rewritten and hardened for Vanguard; no external Pod dependency.
//
// HLS manifest rewriter:
//   - Resolves relative URIs against the manifest base URL.
//   - Rewrites media-segment, init-segment, part, and preload-hint URIs to new
//     proxy tokens so AVPlayer fetches segments through the local proxy.
//   - EXT-X-KEY URIs are NOT rewritten to proxy tokens (no FairPlay key proxying).
//     Relative key URIs are resolved to absolute origin URIs instead.
//   - The original URL never appears in any rewritten proxy path.

import Foundation

// MARK: - Rewriter

struct VGStreamingLocalProxyHLSRewriter {

    /// Rewrite HLS manifest text so all proxyable child URIs become local proxy URLs.
    ///
    /// - Parameters:
    ///   - manifestText:   Raw M3U8 text fetched from upstream.
    ///   - manifestURL:    Upstream URL used to resolve relative URIs.
    ///   - proxyBaseURL:   Local base URL of the form `http://127.0.0.1:<port>/vanguard/`.
    ///   - callerHeaders:  Caller HTTP headers to pass through for child segment fetches.
    ///   - formatHint:     Forwarded from the parent route.
    ///   - networkProfile: Forwarded from the parent route.
    ///   - registry:       Shared token registry.
    ///   - ownerRouteId:   Root route token; all child proxy tokens are scoped to this owner
    ///                     so the same (owner, URL) pair always maps to the same proxy token,
    ///                     giving AVPlayer stable media entry URLs across LL-HLS reloads.
    /// - Returns: Rewritten manifest text.
    static func rewrite(
        manifestText:   String,
        manifestURL:    URL,
        proxyBaseURL:   URL,
        callerHeaders:  [String: String]?,
        formatHint:     String,
        networkProfile: String,
        registry:       VGStreamingLocalProxyRegistry,
        ownerRouteId:   String
    ) -> String {
        let lines = manifestText.components(separatedBy: "\n")
        var output: [String] = []
        output.reserveCapacity(lines.count)

        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

            // ── EXT-X-KEY: resolve relative URI to absolute origin; do NOT proxy ──
            if trimmed.uppercased().hasPrefix("#EXT-X-KEY:") {
                output.append(rewriteKeyTag(raw, manifestURL: manifestURL))
                i += 1
                continue
            }

            // ── EXT-X-MAP (init segment) — proxy it ──────────────────────────────
            if trimmed.uppercased().hasPrefix("#EXT-X-MAP:") {
                output.append(rewriteAttributeURIs(tag: raw,
                                                   manifestURL: manifestURL,
                                                   proxyBaseURL: proxyBaseURL,
                                                   callerHeaders: callerHeaders,
                                                   formatHint: formatHint,
                                                   networkProfile: networkProfile,
                                                   registry: registry,
                                                   ownerRouteId: ownerRouteId))
                i += 1
                continue
            }

            // ── EXT-X-PART (LL-HLS part) — proxy it ─────────────────────────────
            if trimmed.uppercased().hasPrefix("#EXT-X-PART:") {
                output.append(rewriteAttributeURIs(tag: raw,
                                                   manifestURL: manifestURL,
                                                   proxyBaseURL: proxyBaseURL,
                                                   callerHeaders: callerHeaders,
                                                   formatHint: formatHint,
                                                   networkProfile: networkProfile,
                                                   registry: registry,
                                                   ownerRouteId: ownerRouteId))
                i += 1
                continue
            }

            // ── EXT-X-PRELOAD-HINT — proxy it ────────────────────────────────────
            if trimmed.uppercased().hasPrefix("#EXT-X-PRELOAD-HINT:") {
                output.append(rewriteAttributeURIs(tag: raw,
                                                   manifestURL: manifestURL,
                                                   proxyBaseURL: proxyBaseURL,
                                                   callerHeaders: callerHeaders,
                                                   formatHint: formatHint,
                                                   networkProfile: networkProfile,
                                                   registry: registry,
                                                   ownerRouteId: ownerRouteId))
                i += 1
                continue
            }

            // ── EXT-X-MEDIA (rendition playlist URI) — proxy it ──────────────────
            if trimmed.uppercased().hasPrefix("#EXT-X-MEDIA:") {
                output.append(rewriteAttributeURIs(tag: raw,
                                                   manifestURL: manifestURL,
                                                   proxyBaseURL: proxyBaseURL,
                                                   callerHeaders: callerHeaders,
                                                   formatHint: formatHint,
                                                   networkProfile: networkProfile,
                                                   registry: registry,
                                                   ownerRouteId: ownerRouteId))
                i += 1
                continue
            }

            // ── EXT-X-I-FRAME-STREAM-INF (I-frame playlist URI) — proxy it ───────
            if trimmed.uppercased().hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") {
                output.append(rewriteAttributeURIs(tag: raw,
                                                   manifestURL: manifestURL,
                                                   proxyBaseURL: proxyBaseURL,
                                                   callerHeaders: callerHeaders,
                                                   formatHint: formatHint,
                                                   networkProfile: networkProfile,
                                                   registry: registry,
                                                   ownerRouteId: ownerRouteId))
                i += 1
                continue
            }

            // ── EXT-X-RENDITION-REPORT (LL-HLS) — proxy URI so AVPlayer resolves ─
            // ── it through the local proxy and not against the bare loopback root. ─
            if trimmed.uppercased().hasPrefix("#EXT-X-RENDITION-REPORT:") {
                output.append(rewriteAttributeURIs(tag: raw,
                                                   manifestURL: manifestURL,
                                                   proxyBaseURL: proxyBaseURL,
                                                   callerHeaders: callerHeaders,
                                                   formatHint: formatHint,
                                                   networkProfile: networkProfile,
                                                   registry: registry,
                                                   ownerRouteId: ownerRouteId))
                i += 1
                continue
            }

            // ── Segment URI line (not a tag, not empty) ──────────────────────────
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                if let absolute = resolveURI(trimmed, against: manifestURL),
                   let proxied = makeProxyURL(
                       for: absolute,
                       proxyBaseURL: proxyBaseURL,
                       callerHeaders: callerHeaders,
                       formatHint: formatHint,
                       networkProfile: networkProfile,
                       registry: registry,
                       ownerRouteId: ownerRouteId
                   ) {
                    output.append(proxied.absoluteString)
                } else {
                    output.append(raw) // fallback: keep original
                }
                i += 1
                continue
            }

            // ── All other lines (tags, comments, blank) — pass through ────────────
            output.append(raw)
            i += 1
        }

        return output.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Resolve a URI string (possibly relative) against `base`.
    private static func resolveURI(_ uri: String, against base: URL) -> URL? {
        let cleaned = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        if let absolute = URL(string: cleaned), absolute.scheme != nil {
            return absolute
        }
        return URL(string: cleaned, relativeTo: base)?.absoluteURL
    }

    /// Create a proxy token URL for `targetURL`, reusing an existing token when the same
    /// `(ownerRouteId, targetURL)` pair has been seen before (stable LL-HLS token guarantee).
    private static func makeProxyURL(
        for targetURL:    URL,
        proxyBaseURL:     URL,
        callerHeaders:    [String: String]?,
        formatHint:       String,
        networkProfile:   String,
        registry:         VGStreamingLocalProxyRegistry,
        ownerRouteId:     String
    ) -> URL? {
        let token = registry.insertChild(
            originalURL:    targetURL,
            httpHeaders:    callerHeaders,
            formatHint:     formatHint,
            networkProfile: networkProfile,
            ownerRouteId:   ownerRouteId
        )
        return proxyBaseURL.appendingPathComponent(token)
    }

    /// Rewrite `URI="..."` attribute inside a tag line (EXT-X-MAP, EXT-X-PART, EXT-X-PRELOAD-HINT).
    /// Only the URI attribute is rewritten; other attributes are preserved verbatim.
    private static func rewriteAttributeURIs(
        tag:            String,
        manifestURL:    URL,
        proxyBaseURL:   URL,
        callerHeaders:  [String: String]?,
        formatHint:     String,
        networkProfile: String,
        registry:       VGStreamingLocalProxyRegistry,
        ownerRouteId:   String
    ) -> String {
        // Match URI="<value>" (case-insensitive attribute name per HLS spec).
        var result = tag
        let pattern = #"URI="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return tag
        }
        let nsTag = tag as NSString
        // Collect matches in reverse so replacement indices remain valid.
        let matches = regex.matches(in: tag, range: NSRange(location: 0, length: nsTag.length)).reversed()
        for match in matches {
            let fullRange = match.range          // URI="..."
            let valueRange = match.range(at: 1) // inner value
            let uriString = nsTag.substring(with: valueRange)
            guard let absolute = resolveURI(uriString, against: manifestURL),
                  let proxied = makeProxyURL(
                      for: absolute,
                      proxyBaseURL: proxyBaseURL,
                      callerHeaders: callerHeaders,
                      formatHint: formatHint,
                      networkProfile: networkProfile,
                      registry: registry,
                      ownerRouteId: ownerRouteId
                  ) else { continue }
            let replacement = "URI=\"\(proxied.absoluteString)\""
            result = (result as NSString).replacingCharacters(in: fullRange, with: replacement)
        }
        return result
    }

    /// Rewrite EXT-X-KEY tag: resolve relative URI to absolute origin; do NOT proxy.
    private static func rewriteKeyTag(_ tag: String, manifestURL: URL) -> String {
        let pattern = #"URI="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return tag
        }
        var result = tag
        let nsTag = tag as NSString
        let matches = regex.matches(in: tag, range: NSRange(location: 0, length: nsTag.length)).reversed()
        for match in matches {
            let fullRange = match.range
            let valueRange = match.range(at: 1)
            let uriString = nsTag.substring(with: valueRange)
            // Resolve to absolute origin URL only — never make it a proxy URL.
            guard let absolute = resolveURI(uriString, against: manifestURL) else { continue }
            let replacement = "URI=\"\(absolute.absoluteString)\""
            result = (result as NSString).replacingCharacters(in: fullRange, with: replacement)
        }
        return result
    }
}
