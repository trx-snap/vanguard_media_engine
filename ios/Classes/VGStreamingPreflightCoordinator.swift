// Copyright (c) Connects — Vanguard Phase 4C8C.
// VGStreamingPreflightCoordinator.swift
//
// Sole owner of iOS HLS/LL-HLS preflight manifest fetching, parsing,
// network-profile arbitration, warning accumulation, and result-map construction.
//
// Advisory invariants (enforced here, never in the plugin):
//   • Allocates zero AVPlayer, AVPlayerItem, AVPlayerItemVideoOutput, CADisplayLink,
//     FlutterTexture, CVPixelBuffer, audio session, Media3, WebRTC, or LiveKit objects.
//   • Calls result(...) exactly once on the main thread.
//   • All network I/O runs on a background queue with a bounded timeout.
//   • DASH (.mpd / formatHint=DASH) is typed unsupported/deferred — never fetched or played.
//
// Result map is a flat [String: Any] compatible with VGStreamingPreflightReport.fromMap.

import Flutter
import Foundation

// MARK: - Phase / constant strings (mirroring Android AdaptiveStreamingPreflightAdvisory)

private enum Phase4C8C {
    static let phase              = "Phase4C8C"
    static let serverLadderPolicy = "MULTIVARIANT_REQUIRED_UNLESS_MEDIA_PLAYLIST_ALLOWED"
    static let iosMirrorNote      = "iOS HLS/LL-HLS native parity scaffold; DASH deferred"

    // Warning codes
    static let warnInvalidProfile   = "invalid_network_profile"
    static let warnLlDeferredConstr = "low_latency_deferred_for_constrained_network"
    static let warnLlManifestAbsent = "low_latency_manifest_absent"
    static let warnNoManifestSpecs  = "no_manifest_specs"
    static let warnUnsupportedDash  = "unsupported_format_dash"

    // Decision codes
    static let decisionBlockedNoSpec = "blocked_no_manifest_specs"
    static let decisionBlockedFail   = "blocked_compatibility_failed"
    static let decisionConstrained   = "advise_constrained"
    static let decisionLowLatency    = "advise_low_latency"
    static let decisionStable        = "advise_stable"

    // Network profiles (known values)
    static let profileAuto      = "AUTO"
    static let profileConstrained = "CONSTRAINED"
    static let profileStable    = "STABLE"
    static let profileLowLatency = "LOW_LATENCY"
    static let profilePreferLl  = "PREFER_LOW_LATENCY"

    // LL-HLS marker tags
    static let llHlsTags: [String] = [
        "#EXT-X-PART",
        "#EXT-X-PRELOAD-HINT",
        "#EXT-X-SERVER-CONTROL",
        "#EXT-X-RENDITION-REPORT",
    ]

    // Network policy maps (mirror Android AdaptiveStreamingNetworkPolicy constants)
    static func policyMap(
        profile: String,
        bufferMs: Int,
        minBufferMs: Int,
        maxBufferMs: Int,
        allowLowLatency: Bool,
        pass: Bool
    ) -> [String: Any] {
        return [
            "profile":         profile,
            "bufferMs":        bufferMs,
            "minBufferMs":     minBufferMs,
            "maxBufferMs":     maxBufferMs,
            "allowLowLatency": allowLowLatency,
            "pass":            pass,
        ]
    }

    static func policyForProfile(_ profile: String) -> [String: Any] {
        switch profile {
        case profileConstrained:
            return policyMap(profile: profile, bufferMs: 15_000, minBufferMs: 5_000,
                             maxBufferMs: 30_000, allowLowLatency: false, pass: true)
        case profileLowLatency, profilePreferLl:
            return policyMap(profile: profile, bufferMs: 1_000, minBufferMs: 500,
                             maxBufferMs: 5_000, allowLowLatency: true, pass: true)
        case profileStable:
            return policyMap(profile: profile, bufferMs: 5_000, minBufferMs: 2_500,
                             maxBufferMs: 15_000, allowLowLatency: false, pass: true)
        default: // AUTO → STABLE equivalent
            return policyMap(profile: profileStable, bufferMs: 5_000, minBufferMs: 2_500,
                             maxBufferMs: 15_000, allowLowLatency: false, pass: true)
        }
    }
}

// MARK: - Per-manifest compatibility report (internal value type)

private struct ManifestReport {
    let key:          String
    let uri:          String
    let pass:         Bool
    let isHls:        Bool
    let isDash:       Bool
    let hasLlHls:     Bool
    let hasStreamInf: Bool   // multivariant adaptive ladder detected
    let warnings:     [String]
    let rawStatus:    String

    func toDiagnosticMap() -> [String: Any] {
        return [
            "key":          key,
            "uri":          uri,
            "pass":         pass,
            "isHls":        isHls,
            "isDash":       isDash,
            "hasLlHls":     hasLlHls,
            "hasStreamInf": hasStreamInf,
            "warnings":     warnings,
            "raw":          rawStatus,
        ]
    }
}

// MARK: - URLSession fetch result (internal)

private struct PlaylistFetch {
    let text:  String?
    let error: String?
    var succeeded: Bool { text != nil && error == nil }
}

// MARK: - Synchronous playlist fetch helper (runs on background queue)

private func fetchPlaylistSync(
    url: URL,
    headers: [String: String]?,
    timeoutSeconds: TimeInterval
) -> PlaylistFetch {
    var fetchResult: PlaylistFetch?
    let semaphore = DispatchSemaphore(value: 0)

    var request = URLRequest(
        url: url,
        cachePolicy: .reloadIgnoringLocalCacheData,
        timeoutInterval: timeoutSeconds
    )
    request.httpMethod = "GET"
    headers?.forEach { request.setValue($1, forHTTPHeaderField: $0) }

    let session = URLSession(configuration: .ephemeral)
    let task = session.dataTask(with: request) { data, _, error in
        if let error = error {
            fetchResult = PlaylistFetch(text: nil, error: "network_error;\(error.localizedDescription)")
            semaphore.signal()
            return
        }
        guard let data = data, let text = String(data: data, encoding: .utf8) else {
            fetchResult = PlaylistFetch(text: nil, error: "decode_error;empty_or_non_utf8")
            semaphore.signal()
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#EXTM3U") else {
            fetchResult = PlaylistFetch(text: nil, error: "non_hls_content;missing_EXTM3U_header")
            semaphore.signal()
            return
        }
        fetchResult = PlaylistFetch(text: text, error: nil)
        semaphore.signal()
    }
    task.resume()

    // Extra 2 s margin above the URLRequest timeout.
    // On expiry: cancel the task and invalidate the session to release resources immediately.
    let waitOutcome = semaphore.wait(timeout: .now() + timeoutSeconds + 2.0)
    if waitOutcome == .timedOut {
        task.cancel()
        session.invalidateAndCancel()
        return PlaylistFetch(text: nil, error: "timeout_or_no_response")
    }
    // Completed normally — finish session to release delegate/callback references.
    session.finishTasksAndInvalidate()
    return fetchResult ?? PlaylistFetch(text: nil, error: "timeout_or_no_response")
}

// MARK: - VGStreamingPreflightCoordinator

/// Phase 4C8C: sole owner of iOS streaming preflight advisory logic.
///
/// Plugin holds one instance and routes `evaluateStreamingPreflightAdvisory`
/// calls here. No VanguardEngineMode, camera, editor, export, cache, WebRTC,
/// or LiveKit interaction is permitted in this file.
final class VGStreamingPreflightCoordinator {

    /// Bounded URLSession timeout per manifest fetch.
    private let fetchTimeoutSeconds: TimeInterval = 8.0

    /// Concurrent background queue for all network I/O.
    private let fetchQueue = DispatchQueue(
        label: "com.connects.vanguard.preflight.fetch",
        qos: .userInitiated,
        attributes: .concurrent
    )

    // MARK: - Public entry point

    /// Called by the plugin on the main thread. Calls `result(...)` exactly
    /// once on the main thread after all manifest fetches complete.
    func evaluate(args: [String: Any]?, result: @escaping FlutterResult) {
        // 1. Parse top-level request args
        let rawManifests  = args?["manifests"]                    as? [[String: Any]] ?? []
        let rawProfile    = (args?["requestedNetworkProfile"]     as? String ?? "AUTO")
                              .uppercased().trimmingCharacters(in: .whitespaces)
        let preferLl      = args?["preferLowLatency"]             as? Bool ?? false
        let allowLlConstr = args?["allowLowLatencyOnConstrained"] as? Bool ?? false

        // 2. Validate / normalise network profile
        var globalWarnings = [String]()
        let knownProfiles: Set<String> = [
            Phase4C8C.profileAuto, Phase4C8C.profileConstrained,
            Phase4C8C.profileStable, Phase4C8C.profileLowLatency,
            Phase4C8C.profilePreferLl,
        ]
        let parsedProfile: String
        if knownProfiles.contains(rawProfile) {
            parsedProfile = rawProfile
        } else {
            globalWarnings.append(Phase4C8C.warnInvalidProfile)
            parsedProfile = Phase4C8C.profileAuto
        }

        // 3. Empty manifests fast-path
        if rawManifests.isEmpty {
            globalWarnings.append(Phase4C8C.warnNoManifestSpecs)
            let policy = Phase4C8C.policyForProfile(Phase4C8C.profileConstrained)
            let map = buildResultMap(
                pass:                 false,
                advisoryDecision:     Phase4C8C.decisionBlockedNoSpec,
                parsedProfile:        parsedProfile,
                recommendedProfile:   Phase4C8C.profileConstrained,
                recommendedPolicy:    policy,
                totalReports:         0,
                passedReports:        0,
                failedReports:        0,
                warnings:             globalWarnings,
                deviceWarnings:       [],
                llHlsAvailable:       false,
                compatibilityReports: [],
                rawStatus:            "status=FAIL;reason=no_manifest_specs"
            )
            DispatchQueue.main.async { result(map) }
            return
        }

        // 4. Async parallel manifest evaluation
        let group      = DispatchGroup()
        let reportLock = NSLock()
        var reports    = [ManifestReport?](repeating: nil, count: rawManifests.count)

        for (idx, spec) in rawManifests.enumerated() {
            let key         = spec["key"]           as? String ?? "manifest_\(idx)"
            let uriStr      = spec["uri"]           as? String ?? ""
            let fmtHint     = (spec["formatHint"]   as? String ?? "AUTO").uppercased()
            let reqAdaptive = spec["requireAdaptiveLadder"] as? Bool ?? true
            let allowMedia  = spec["allowMediaPlaylist"]    as? Bool ?? false
            let reqLlTags   = spec["requireLlHlsTags"]      as? Bool ?? false
            let httpHdrs    = spec["httpHeaders"]           as? [String: String]

            group.enter()
            fetchQueue.async { [self] in
                let r = self.evaluateManifest(
                    key:         key,
                    uriStr:      uriStr,
                    formatHint:  fmtHint,
                    reqAdaptive: reqAdaptive,
                    allowMedia:  allowMedia,
                    reqLlTags:   reqLlTags,
                    httpHeaders: httpHdrs
                )
                reportLock.lock()
                reports[idx] = r
                reportLock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [self] in
            let finalReports = reports.compactMap { $0 }
            self.arbitrateAndReturn(
                finalReports:   finalReports,
                parsedProfile:  parsedProfile,
                preferLl:       preferLl,
                allowLlConstr:  allowLlConstr,
                globalWarnings: globalWarnings,
                result:         result
            )
        }
    }

    // MARK: - Per-manifest evaluation (runs on fetchQueue background thread)

    private func evaluateManifest(
        key:         String,
        uriStr:      String,
        formatHint:  String,
        reqAdaptive: Bool,
        allowMedia:  Bool,
        reqLlTags:   Bool,
        httpHeaders: [String: String]?
    ) -> ManifestReport {

        var warnings = [String]()

        // DASH rejection — typed unsupported, no fetch
        let isDashHint = (formatHint == "DASH")
        let isDashUri  = uriStr.lowercased().hasSuffix(".mpd")
        if isDashHint || isDashUri {
            warnings.append(Phase4C8C.warnUnsupportedDash)
            return ManifestReport(
                key: key, uri: uriStr,
                pass: false, isHls: false, isDash: true,
                hasLlHls: false, hasStreamInf: false,
                warnings: warnings,
                rawStatus: "status=FAIL;reason=unsupported_format_dash;uri=\(uriStr)"
            )
        }

        // URL validation — must be non-empty http(s)
        guard !uriStr.isEmpty,
              let url = URL(string: uriStr),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return ManifestReport(
                key: key, uri: uriStr,
                pass: false, isHls: false, isDash: false,
                hasLlHls: false, hasStreamInf: false,
                warnings: ["invalid_url"],
                rawStatus: "status=FAIL;reason=invalid_or_non_http_url;uri=\(uriStr)"
            )
        }

        // Confirm HLS by hint (.m3u8 extension, or AUTO/HLS hint)
        let isHlsHint = (formatHint == "HLS" || formatHint == "AUTO")
        let isHlsUri  = uriStr.lowercased().hasSuffix(".m3u8")
        guard isHlsHint || isHlsUri else {
            return ManifestReport(
                key: key, uri: uriStr,
                pass: false, isHls: false, isDash: false,
                hasLlHls: false, hasStreamInf: false,
                warnings: ["unknown_format;formatHint=\(formatHint)"],
                rawStatus: "status=FAIL;reason=unknown_format;formatHint=\(formatHint);uri=\(uriStr)"
            )
        }

        // Fetch playlist (blocking within the background queue thread)
        let fetch = fetchPlaylistSync(
            url: url,
            headers: httpHeaders,
            timeoutSeconds: fetchTimeoutSeconds
        )
        guard fetch.succeeded, let playlistText = fetch.text else {
            let errReason = fetch.error ?? "timeout_or_no_response"
            return ManifestReport(
                key: key, uri: uriStr,
                pass: false, isHls: true, isDash: false,
                hasLlHls: false, hasStreamInf: false,
                warnings: ["fetch_failed;\(errReason)"],
                rawStatus: "status=FAIL;reason=\(errReason);uri=\(uriStr)"
            )
        }

        // Parse master playlist content
        let hasStreamInf = playlistText.contains("#EXT-X-STREAM-INF")
        var hasLlHls     = Phase4C8C.llHlsTags.contains { playlistText.contains($0) }

        // LL-HLS tags live in child rendition playlists for real LL-HLS masters.
        // When the master contains EXT-X-STREAM-INF but no LL-HLS markers,
        // probe the first child variant playlist (one additional bounded fetch).
        if !hasLlHls && hasStreamInf {
            if let childURL = firstVariantURL(masterText: playlistText, masterURL: url) {
                let childFetch = fetchPlaylistSync(
                    url: childURL,
                    headers: httpHeaders,
                    timeoutSeconds: fetchTimeoutSeconds
                )
                if childFetch.succeeded, let childText = childFetch.text {
                    hasLlHls = Phase4C8C.llHlsTags.contains { childText.contains($0) }
                } else if reqLlTags {
                    // Child fetch failed while caller requires LL-HLS — record diagnostic.
                    let childErr = childFetch.error ?? "timeout_or_no_response"
                    warnings.append("ll_hls_variant_fetch_failed;\(childErr)")
                }
            }
        }

        // Adaptive ladder requirement
        if reqAdaptive && !hasStreamInf && !allowMedia {
            warnings.append("missing_adaptive_ladder;key=\(key)")
        }
        // LL-HLS tag requirement
        if reqLlTags && !hasLlHls {
            warnings.append("missing_ll_hls_tags;key=\(key)")
        }

        let pass = warnings.isEmpty
        let rawStatus = pass
            ? "status=OK;isHls=true;hasStreamInf=\(hasStreamInf);hasLlHls=\(hasLlHls);uri=\(uriStr)"
            : "status=FAIL;warnings=\(warnings.joined(separator: ","));uri=\(uriStr)"

        return ManifestReport(
            key: key, uri: uriStr,
            pass: pass, isHls: true, isDash: false,
            hasLlHls: hasLlHls, hasStreamInf: hasStreamInf,
            warnings: warnings, rawStatus: rawStatus
        )
    }

    // MARK: - LL-HLS child variant URI resolver (private helper)

    /// Finds the URI of the first variant stream in a multivariant HLS playlist
    /// and resolves it relative to `masterURL`.
    ///
    /// Scans lines sequentially: the line immediately after `#EXT-X-STREAM-INF`
    /// is the variant URI per RFC 8216 §4.3.4.2.
    /// Returns `nil` if no valid variant URI can be found or resolved.
    private func firstVariantURL(masterText: String, masterURL: URL) -> URL? {
        let lines = masterText.components(separatedBy: .newlines)
        var nextIsVariantURI = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if nextIsVariantURI {
                // Non-empty, non-tag line is the variant URI
                if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                    if let absolute = URL(string: trimmed), absolute.scheme != nil {
                        return absolute
                    }
                    // Relative URI — resolve against master URL
                    return URL(string: trimmed, relativeTo: masterURL)?.absoluteURL
                }
                // Blank or unexpected tag line resets expectation
                nextIsVariantURI = false
            }
            if trimmed.hasPrefix("#EXT-X-STREAM-INF") {
                nextIsVariantURI = true
            }
        }
        return nil
    }

    // MARK: - Arbitration and final result map (runs on main thread)

    private func arbitrateAndReturn(
        finalReports:   [ManifestReport],
        parsedProfile:  String,
        preferLl:       Bool,
        allowLlConstr:  Bool,
        globalWarnings: [String],
        result:         @escaping FlutterResult
    ) {
        let total  = finalReports.count
        let passed = finalReports.filter { $0.pass }.count
        let failed = total - passed
        let overallPass    = (failed == 0 && total > 0)
        let llHlsAvailable = finalReports.contains { $0.hasLlHls }

        // Merge per-manifest failure warnings into global list
        var warnings = globalWarnings
        for r in finalReports where !r.pass {
            for w in r.warnings where !warnings.contains(w) {
                warnings.append(w)
            }
        }

        // Network-profile arbitration (mirrors Android AdaptiveStreamingPreflightAdvisory exactly)
        let pass:              Bool
        let recommendedProfile: String
        let advisoryDecision:  String

        if !overallPass {
            pass               = false
            recommendedProfile = Phase4C8C.profileConstrained
            advisoryDecision   = Phase4C8C.decisionBlockedFail
        } else {
            pass = true
            let wantsLl = (parsedProfile == Phase4C8C.profileLowLatency
                        || parsedProfile == Phase4C8C.profilePreferLl
                        || preferLl)

            if parsedProfile == Phase4C8C.profileConstrained {
                recommendedProfile = Phase4C8C.profileConstrained
                advisoryDecision   = Phase4C8C.decisionConstrained
                if preferLl && !allowLlConstr && !warnings.contains(Phase4C8C.warnLlDeferredConstr) {
                    warnings.append(Phase4C8C.warnLlDeferredConstr)
                }
            } else if wantsLl {
                if llHlsAvailable {
                    recommendedProfile = Phase4C8C.profileLowLatency
                    advisoryDecision   = Phase4C8C.decisionLowLatency
                } else {
                    recommendedProfile = Phase4C8C.profileStable
                    advisoryDecision   = Phase4C8C.decisionStable
                    if !warnings.contains(Phase4C8C.warnLlManifestAbsent) {
                        warnings.append(Phase4C8C.warnLlManifestAbsent)
                    }
                }
            } else {
                // STABLE, AUTO, or any other recognised profile
                recommendedProfile = Phase4C8C.profileStable
                advisoryDecision   = Phase4C8C.decisionStable
            }
        }

        // Build policy and override its pass key to match the top-level preflight result.
        // policyForProfile always emits pass:true for valid profiles; correct that for failure paths.
        var recommendedPolicy    = Phase4C8C.policyForProfile(recommendedProfile)
        recommendedPolicy["pass"] = pass
        let compatibilityReports = finalReports.map { $0.toDiagnosticMap() }

        let rawStatus: String
        if pass {
            rawStatus = "status=OK;decision=\(advisoryDecision);recommended=\(recommendedProfile);" +
                "requested=\(parsedProfile);llHlsAvailable=\(llHlsAvailable);" +
                "totalReports=\(total);passedReports=\(passed);failedReports=0"
        } else {
            rawStatus = "status=PREFLIGHT_ADVISORY_FAILED;decision=\(advisoryDecision);" +
                "recommended=\(recommendedProfile);requested=\(parsedProfile);" +
                "warnings=\(warnings.joined(separator: ","));" +
                "totalReports=\(total);failedReports=\(failed)"
        }

        let map = buildResultMap(
            pass:                 pass,
            advisoryDecision:     advisoryDecision,
            parsedProfile:        parsedProfile,
            recommendedProfile:   recommendedProfile,
            recommendedPolicy:    recommendedPolicy,
            totalReports:         total,
            passedReports:        passed,
            failedReports:        failed,
            warnings:             warnings,
            deviceWarnings:       [],   // iOS: no pre-check decoder advisory in Phase 4C8C
            llHlsAvailable:       llHlsAvailable,
            compatibilityReports: compatibilityReports,
            rawStatus:            rawStatus
        )
        result(map)
    }

    // MARK: - Result map builder

    /// Returns a flat [String: Any] map compatible with
    /// VGStreamingPreflightReport.fromMap. Extra keys (compatibilityReports)
    /// are preserved by Dart in the diagnostics map.
    private func buildResultMap(
        pass:                 Bool,
        advisoryDecision:     String,
        parsedProfile:        String,
        recommendedProfile:   String,
        recommendedPolicy:    [String: Any],
        totalReports:         Int,
        passedReports:        Int,
        failedReports:        Int,
        warnings:             [String],
        deviceWarnings:       [String],
        llHlsAvailable:       Bool,
        compatibilityReports: [[String: Any]],
        rawStatus:            String
    ) -> [String: Any] {
        return [
            "phase":                     Phase4C8C.phase,
            "pass":                      pass,
            "advisoryDecision":          advisoryDecision,
            "requestedNetworkProfile":   parsedProfile,
            "recommendedNetworkProfile": recommendedProfile,
            "recommendedNetworkPolicy":  recommendedPolicy,
            "totalReports":              totalReports,
            "passedReports":             passedReports,
            "failedReports":             failedReports,
            "warnings":                  warnings,
            "deviceWarnings":            deviceWarnings,
            "llHlsAvailable":            llHlsAvailable,
            "advisoryOnly":              true,
            "playbackMutation":          false,
            "serverLadderPolicy":        Phase4C8C.serverLadderPolicy,
            "iosMirrorNote":             Phase4C8C.iosMirrorNote,
            "raw":                       rawStatus,
            "compatibilityReports":      compatibilityReports,
        ]
    }
}
