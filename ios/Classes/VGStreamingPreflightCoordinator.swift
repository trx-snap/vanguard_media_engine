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

    // Network policy maps (aligned with Android Phase 4C5B AdaptiveStreamingNetworkPolicy values)
    //
    // Android Phase 4C5B reference (AdaptiveStreamingNetworkPolicy.kt L147-215):
    //   AUTO        — customPolicyEnabled=false, all buffer/bitrate values nil/default.
    //   STABLE      — min/max/start/rebuffer = 15000/50000/2500/5000 ms, no bitrate cap.
    //   CONSTRAINED — min/max/start/rebuffer = 25000/60000/5000/8000 ms,
    //                 maxVideoBitrate=800000, maxAudioBitrate=96000.
    //   LOW_LATENCY — min/max/start/rebuffer = 3000/10000/1000/1500 ms, no bitrate cap.
    //
    // AVFoundation mapping:
    //   preferredForwardBufferDurationSeconds derived from minBufferMs / 1000.
    //   preferredPeakBitRate = (maxVideoBitrate ?? 0) + (maxAudioBitrate ?? 0); 0 means uncapped.
    //   automaticallyWaitsToMinimizeStalling = (profile != LOW_LATENCY).
    static func policyMap(
        profile:                               String,
        customPolicyEnabled:                   Bool,
        minBufferMs:                           Int?,
        maxBufferMs:                           Int?,
        bufferForPlaybackMs:                   Int?,
        bufferForPlaybackAfterRebufferMs:      Int?,
        maxVideoBitrate:                       Int?,
        maxAudioBitrate:                       Int?,
        forceLowestBitrate:                    Bool,
        exceedVideoConstraintsIfNecessary:     Bool,
        preferredForwardBufferDurationSeconds: Double,
        preferredPeakBitRate:                  Double,
        automaticallyWaitsToMinimizeStalling:  Bool,
        pass:                                  Bool
    ) -> [String: Any] {
        var map: [String: Any] = [
            "profile":                               profile,
            "customPolicyEnabled":                   customPolicyEnabled,
            "forceLowestBitrate":                    forceLowestBitrate,
            "exceedVideoConstraintsIfNecessary":     exceedVideoConstraintsIfNecessary,
            "preferredForwardBufferDurationSeconds": preferredForwardBufferDurationSeconds,
            "preferredPeakBitRate":                  preferredPeakBitRate,
            "automaticallyWaitsToMinimizeStalling":  automaticallyWaitsToMinimizeStalling,
            "pass":                                  pass,
        ]
        map["minBufferMs"]                      = minBufferMs.map { $0 as Any } ?? NSNull()
        map["maxBufferMs"]                      = maxBufferMs.map { $0 as Any } ?? NSNull()
        map["bufferForPlaybackMs"]              = bufferForPlaybackMs.map { $0 as Any } ?? NSNull()
        map["bufferForPlaybackAfterRebufferMs"] = bufferForPlaybackAfterRebufferMs.map { $0 as Any } ?? NSNull()
        map["maxVideoBitrate"]                  = maxVideoBitrate.map { $0 as Any } ?? NSNull()
        map["maxAudioBitrate"]                  = maxAudioBitrate.map { $0 as Any } ?? NSNull()
        return map
    }

    static func policyForProfile(_ profile: String) -> [String: Any] {
        switch profile {
        case profileConstrained:
            return policyMap(
                profile:                               profile,
                customPolicyEnabled:                   true,
                minBufferMs:                           25_000,
                maxBufferMs:                           60_000,
                bufferForPlaybackMs:                   5_000,
                bufferForPlaybackAfterRebufferMs:      8_000,
                maxVideoBitrate:                       800_000,
                maxAudioBitrate:                       96_000,
                forceLowestBitrate:                    false,
                exceedVideoConstraintsIfNecessary:     true,
                preferredForwardBufferDurationSeconds: 25.0,
                preferredPeakBitRate:                  896_000.0,  // 800000 + 96000
                automaticallyWaitsToMinimizeStalling:  true,
                pass:                                  true
            )
        case profileLowLatency, profilePreferLl:
            return policyMap(
                profile:                               profile,
                customPolicyEnabled:                   true,
                minBufferMs:                           3_000,
                maxBufferMs:                           10_000,
                bufferForPlaybackMs:                   1_000,
                bufferForPlaybackAfterRebufferMs:      1_500,
                maxVideoBitrate:                       nil,
                maxAudioBitrate:                       nil,
                forceLowestBitrate:                    false,
                exceedVideoConstraintsIfNecessary:     true,
                preferredForwardBufferDurationSeconds: 3.0,
                preferredPeakBitRate:                  0.0,
                automaticallyWaitsToMinimizeStalling:  false,
                pass:                                  true
            )
        case profileStable:
            return policyMap(
                profile:                               profile,
                customPolicyEnabled:                   true,
                minBufferMs:                           15_000,
                maxBufferMs:                           50_000,
                bufferForPlaybackMs:                   2_500,
                bufferForPlaybackAfterRebufferMs:      5_000,
                maxVideoBitrate:                       nil,
                maxAudioBitrate:                       nil,
                forceLowestBitrate:                    false,
                exceedVideoConstraintsIfNecessary:     true,
                preferredForwardBufferDurationSeconds: 15.0,
                preferredPeakBitRate:                  0.0,
                automaticallyWaitsToMinimizeStalling:  true,
                pass:                                  true
            )
        default: // AUTO — customPolicyEnabled=false, all buffer/bitrate values nil/default
            return policyMap(
                profile:                               profileAuto,
                customPolicyEnabled:                   false,
                minBufferMs:                           nil,
                maxBufferMs:                           nil,
                bufferForPlaybackMs:                   nil,
                bufferForPlaybackAfterRebufferMs:      nil,
                maxVideoBitrate:                       nil,
                maxAudioBitrate:                       nil,
                forceLowestBitrate:                    false,
                exceedVideoConstraintsIfNecessary:     false,
                preferredForwardBufferDurationSeconds: 0.0,
                preferredPeakBitRate:                  0.0,
                automaticallyWaitsToMinimizeStalling:  true,
                pass:                                  true
            )
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

// MARK: - VGStreamingManifestPolicyValidator (Phase 4C8W)
//
// Moved from the standalone VGStreamingManifestPolicyValidator.swift (now deleted)
// into this already-compiled file so it is included in the current Pods build
// without requiring CocoaPods regeneration.
//
// Mirrors Android Phase 4C5D (AdaptiveStreamingManifestPolicySmokeHarness +
// AdaptiveStreamingManifestPolicyValidator) behind the shared MethodChannel route
// `runAndroidDagPhase4C5DManifestPolicyValidation` so the public Dart API
// (VGStreamingManifestPolicyClient.validate) stays stable across platforms.
//
// Invariants:
//   - Zero AVPlayer / AVPlayerItem / AVAssetReader / VTDecompressionSession /
//     CVPixelBuffer / FlutterTexture / cache / audio / WebRTC / LiveKit / camera /
//     editor / export / VanguardEngineMode / switchToMode interaction.
//   - Manifest-only: media segment / container URLs rejected before any network fetch.
//   - 2 MB response cap; ephemeral URLSession (no caching); custom headers
//     copied only when both key and value are String instances.
//   - All network work on a background queue; FlutterResult called exactly once,
//     on the main thread.
//   - DASH is manifest-diagnostic only on iOS (no AVPlayer involvement).
//   - validate(args:result:) captures self strongly — FlutterResult is always
//     delivered even if the plugin drops its reference to this instance.
//   - _fetchManifest uses a bounded DispatchSemaphore.wait(timeout:); on expiry
//     the URLSessionDataTask is cancelled and the session is invalidated, then a
//     timeout error is thrown. URLRequest timeout alone does not satisfy this invariant.

/// Package-internal helper that owns all Phase 4C8W manifest-policy logic.
/// The plugin holds an instance and forwards the single method-channel call here.
final class VGStreamingManifestPolicyValidator {

    // ── Phase / policy constants (match Android strings exactly) ──────────────

    static let phase              = "Phase4C5D"
    static let serverLadderPolicy = "add_hevc_av1_renditions_but_keep_avc_fallback"
    static let iosMirrorNote      =
        "iOS AVPlayer/AVFoundation manifest selection must maintain H.264/AVC fallback renditions alongside HEVC/AV1."

    // ── Policy failure reason strings (match Android constants exactly) ───────

    private static let failureFetchFailed            = "fetch_failed"
    private static let failureParseFailed            = "parse_failed"
    private static let failureAdaptiveLadderRequired = "adaptive_ladder_required"
    private static let failureMediaPlaylistNotAllowed = "media_playlist_not_allowed"
    private static let failureAvcFallbackRequired    = "avc_fallback_required_for_modern_codecs"
    private static let failureLlHlsTagsRequired      = "ll_hls_tags_required"
    private static let failureInvalidManifestSpec    = "invalid_manifest_spec"

    // ── Canonical default public streams (match Android defaults exactly) ─────

    private static let defaultHlsUri   = "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8"
    private static let defaultDashUri  = "https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd"
    private static let defaultLlHlsUri = "https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8"

    // ── Segment rejection probe URI (match Android exactly) ───────────────────

    private static let fakeSegmentUri = "https://example.com/video/segment_00001.m4s"

    // ── Valid format hints ────────────────────────────────────────────────────

    private static let validFormatHints: Set<String> = ["AUTO", "HLS", "DASH"]

    // ── Media segment / container extensions to reject before fetch ───────────

    private static let segmentExtensions: Set<String> = [
        "ts", "m4s", "mp4", "webm", "m4a", "m4v", "m4b", "m4p",
        "aac", "mp3", "ogg", "oga", "opus", "flac", "wav",
        "f4v", "f4f", "cmfv", "cmfa",
    ]

    // ── Max manifest response size ────────────────────────────────────────────

    private static let maxManifestBytes = 2 * 1024 * 1024  // 2 MB

    // ── Fetch timeouts ────────────────────────────────────────────────────────
    // requestTimeout  — URLRequest / URLSession per-request timeout.
    // resourceTimeout — URLSession per-resource timeout (upper bound for transfer).
    // semaphoreTimeout — Bounded semaphore deadline; on expiry the task is
    //                    cancelled and the session invalidated before throwing.
    //                    Must exceed resourceTimeout so URLSession can fire its
    //                    own error first in the normal case, while still providing
    //                    a hard OS-level resource-release guarantee.

    private static let requestTimeout:   TimeInterval = 12.0
    private static let resourceTimeout:  TimeInterval = 20.0
    private static let semaphoreTimeout: TimeInterval = 24.0   // requestTimeout + margin

    // ── Background queue ──────────────────────────────────────────────────────

    private let bgQueue = DispatchQueue(
        label: "com.vanguard.p4c8w.manifestPolicy",
        qos: .userInitiated
    )

    // MARK: - Public entry point

    /// Called from the plugin's `handle(_:result:)` dispatch guard.
    /// Runs all network I/O on `bgQueue`; delivers result exactly once on `DispatchQueue.main`.
    ///
    /// Uses `[self]` (strong capture) intentionally: the validator must remain alive
    /// for the duration of its network calls so that `result(...)` is never dropped
    /// by an early `guard let self = self else { return }` path.
    func validate(args: [String: Any]?, result: @escaping FlutterResult) {
        bgQueue.async { [self] in
            let output = self._runValidation(args: args)
            DispatchQueue.main.async { result(output) }
        }
    }

    // MARK: - Package-internal synchronous spec validation

    /// Synchronous per-spec validation reused by `VGStreamingCompatibilityDecisionReporter`.
    /// MUST be called only from a background queue — never the main thread.
    /// Delegates to the same private `_validateSpec` used by the manifest policy validation
    /// route, so no network/parsing logic is duplicated.
    func validateSpecSync(_ spec: [String: Any]) -> [String: Any] {
        return _validateSpec(spec)
    }

    // MARK: - Orchestration (runs on bgQueue)

    private func _runValidation(args: [String: Any]?) -> [String: Any] {
        // Resolve manifest specs: use host-supplied list or fall back to canonical defaults.
        let specs: [[String: Any]]
        if let raw = args?["manifests"] as? [[String: Any]], !raw.isEmpty {
            specs = raw
        } else if let raw = args?["manifests"] as? [Any], !raw.isEmpty,
                  let typed = raw.compactMap({ $0 as? [String: Any] }) as [[String: Any]]?,
                  !typed.isEmpty {
            specs = typed
        } else {
            specs = Self._defaultPublicSpecs()
        }

        guard !specs.isEmpty else {
            return _emptySpecsResult()
        }

        do {
            // 1. Validate each spec.
            let results: [[String: Any]] = specs.map { _validateSpec($0) }
            let total    = results.count
            let passed   = results.filter { $0["pass"] as? Bool == true }.count
            let failed   = total - passed

            // 2. Internal segment-rejection security probe.
            let segmentSpec: [String: Any] = [
                "key":        "segment_rejection_probe",
                "uri":        Self.fakeSegmentUri,
                "formatHint": "AUTO",
            ]
            let segmentResult = _validateSpec(segmentSpec)
            let segmentRaw    = segmentResult["raw"] as? String ?? ""
            let segmentInspRaw = (segmentResult["inspection"] as? [String: Any])?["raw"] as? String ?? ""
            let segPolicyFails = segmentResult["policyFailures"] as? [String] ?? []

            // Segment must be rejected before fetch:
            // fetchSuccess == false AND (raw or inspectionRaw contains media_segment_uri_rejected
            // OR policyFailures == [fetch_failed]).
            let segmentFetchSuccess = segmentResult["fetchSuccess"] as? Bool ?? false
            let segmentRejectionPass = !segmentFetchSuccess &&
                (segmentRaw.contains("media_segment_uri_rejected") ||
                 segmentInspRaw.contains("media_segment_uri_rejected") ||
                 segPolicyFails == [Self.failureFetchFailed])

            // 3. Overall pass: all manifests passed, at least 1 validated, segment rejected.
            let allManifestsPass = failed == 0 && total > 0
            let overallPass      = allManifestsPass && segmentRejectionPass

            let rawStatus: String
            if overallPass {
                rawStatus = "status=OK;total=\(total);passed=\(passed);failed=0;" +
                    "segmentRejectionPass=true;allManifestsPass=true"
            } else {
                rawStatus = "status=MANIFEST_POLICY_VALIDATION_FAILED;total=\(total);passed=\(passed);" +
                    "failed=\(failed);segmentRejectionPass=\(segmentRejectionPass);" +
                    "allManifestsPass=\(allManifestsPass)"
            }

            return [
                "phase":                   Self.phase,
                "pass":                    overallPass,
                "totalManifestsValidated": total,
                "passedManifests":         passed,
                "failedManifests":         failed,
                "segmentRejectionPass":    segmentRejectionPass,
                "serverLadderPolicy":      Self.serverLadderPolicy,
                "iosMirrorNote":           Self.iosMirrorNote,
                "results":                 results,
                "segmentRejectionResult":  segmentResult,
                "raw":                     rawStatus,
            ]
        }
    }

    // MARK: - Per-spec validation

    private func _validateSpec(_ spec: [String: Any]?) -> [String: Any] {
        guard let spec = spec else {
            return _buildInvalidResult(key: "", uri: "", formatHint: "AUTO",
                                       failures: [Self.failureInvalidManifestSpec])
        }

        let key        = (spec["key"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let uri        = (spec["uri"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let formatHint = ((spec["formatHint"] as? String)?.trimmingCharacters(in: .whitespaces)
                            .uppercased()) ?? "AUTO"

        guard !key.isEmpty, !uri.isEmpty, Self.validFormatHints.contains(formatHint) else {
            return _buildInvalidResult(key: key, uri: uri, formatHint: formatHint,
                                       failures: [Self.failureInvalidManifestSpec])
        }

        let requireAdaptiveLadder = spec["requireAdaptiveLadder"] as? Bool ?? true
        let requireAvcFallback    = spec["requireAvcFallback"]    as? Bool ?? true
        let requireLlHlsTags      = spec["requireLlHlsTags"]      as? Bool ?? false
        let allowMediaPlaylist    = spec["allowMediaPlaylist"]     as? Bool ?? false

        // Copy HTTP headers only when both key and value are strings.
        var httpHeaders: [String: String]? = nil
        if let rawHeaders = spec["httpHeaders"] as? [String: Any] {
            var h = [String: String]()
            for (k, v) in rawHeaders {
                if let sv = v as? String { h[k] = sv }
            }
            if !h.isEmpty { httpHeaders = h }
        } else if let rawHeaders = spec["httpHeaders"] as? [String: String] {
            httpHeaders = rawHeaders
        }

        // Run the inspection (includes media-segment-extension pre-filter).
        let hintArg: String? = formatHint == "AUTO" ? nil : formatHint
        let inspection = _inspectUri(uri: uri, formatHint: hintArg, httpHeaders: httpHeaders)

        let fetchSuccess    = inspection["fetchSuccess"]  as? Bool ?? false
        let parseSuccess    = inspection["parseSuccess"]  as? Bool ?? false
        let isMediaPlaylist = inspection["isMediaPlaylist"] as? Bool ?? false
        let variantCount    = inspection["variantCount"]  as? Int  ?? 0
        let repCount        = (inspection["representationCount"] as? Int) ?? variantCount
        let hasAdaptiveLadder = inspection["hasAdaptiveLadder"] as? Bool ?? false
        let hasAvc          = inspection["hasAvc"]          as? Bool ?? false
        let hasHevc         = inspection["hasHevc"]         as? Bool ?? false
        let hasAv1          = inspection["hasAv1"]          as? Bool ?? false
        let serverPolicyPass = inspection["serverPolicyPass"] as? Bool ?? false

        var policyFailures = [String]()

        if !fetchSuccess {
            policyFailures.append(Self.failureFetchFailed)
        } else if !parseSuccess {
            policyFailures.append(Self.failureParseFailed)
        } else {
            if !allowMediaPlaylist && isMediaPlaylist {
                policyFailures.append(Self.failureMediaPlaylistNotAllowed)
            }
            if requireAdaptiveLadder && !hasAdaptiveLadder {
                policyFailures.append(Self.failureAdaptiveLadderRequired)
            }
            if requireAvcFallback && !serverPolicyPass {
                policyFailures.append(Self.failureAvcFallbackRequired)
            }
            if requireLlHlsTags {
                let llIndicators = inspection["llHlsIndicators"] as? [String: Any]
                let isLlHls      = llIndicators?["isLlHls"] as? Bool ?? false
                if !isLlHls {
                    policyFailures.append(Self.failureLlHlsTagsRequired)
                }
            }
        }

        let pass = policyFailures.isEmpty
        let rawStatus: String
        if pass {
            rawStatus = "status=OK;key=\(key);formatHint=\(formatHint);variantCount=\(variantCount);" +
                "hasAdaptiveLadder=\(hasAdaptiveLadder);hasAvc=\(hasAvc);hasHevc=\(hasHevc);" +
                "hasAv1=\(hasAv1);serverPolicyPass=\(serverPolicyPass)"
        } else {
            rawStatus = "status=FAIL;key=\(key);formatHint=\(formatHint);" +
                "failures=\(policyFailures.joined(separator: ","));" +
                "rawInspection=\(inspection["raw"] as? String ?? "")"
        }

        return [
            "key":               key,
            "uri":               uri,
            "formatHint":        formatHint,
            "pass":              pass,
            "fetchSuccess":      fetchSuccess,
            "parseSuccess":      parseSuccess,
            "hasAdaptiveLadder": hasAdaptiveLadder,
            "variantCount":      variantCount,
            "representationCount": repCount,
            "hasAvc":            hasAvc,
            "hasHevc":           hasHevc,
            "hasAv1":            hasAv1,
            "serverPolicyPass":  serverPolicyPass,
            "policyFailures":    policyFailures,
            "raw":               rawStatus,
            "inspection":        inspection,
        ]
    }

    // MARK: - URI inspection (fetch + parse)

    /// Inspects a single URI. Rejects segment extensions before fetch.
    /// Returns a structured inspection map (fetchSuccess, parseSuccess, …).
    private func _inspectUri(uri: String,
                              formatHint: String?,
                              httpHeaders: [String: String]?) -> [String: Any] {
        // Pre-filter: reject media segment / container extensions without a network round-trip.
        if _isMediaSegmentUri(uri) {
            let raw = "status=FAIL;reason=media_segment_uri_rejected;\(uri)"
            return _fetchFailResult(uri: uri, formatHint: formatHint,
                                    reason: "media_segment_uri_rejected", rawOverride: raw)
        }

        do {
            let (body, resolvedUri) = try _fetchManifest(urlStr: uri, httpHeaders: httpHeaders)
            let format = _determineFormat(uri: resolvedUri, body: body, hint: formatHint)
            switch format {
            case "DASH":
                return _inspectDash(originalUri: uri, resolvedUri: resolvedUri, body: body)
            default:
                return _inspectHls(originalUri: uri, resolvedUri: resolvedUri, body: body)
            }
        } catch {
            let msg = error.localizedDescription
            let isMsgSegRejected = msg.contains("media_segment_uri_rejected")
            let raw = isMsgSegRejected
                ? "status=FAIL;reason=\(msg)"
                : "status=FAIL;reason=fetch_or_parse_exception:\(msg)"
            return _fetchFailResult(uri: uri, formatHint: formatHint, reason: msg, rawOverride: raw)
        }
    }

    // MARK: - Network fetch

    private func _isMediaSegmentUri(_ uriStr: String) -> Bool {
        guard !uriStr.isEmpty else { return false }
        let pathPart: String
        if let url = URL(string: uriStr) {
            pathPart = url.path
        } else {
            pathPart = uriStr.components(separatedBy: "?").first ?? uriStr
        }
        let filename = (pathPart as NSString).lastPathComponent.lowercased()
        let ext      = (filename as NSString).pathExtension
        return !ext.isEmpty && Self.segmentExtensions.contains(ext)
    }

    /// Fetches a manifest synchronously (called from the bgQueue thread).
    ///
    /// Bounded-timeout invariant:
    ///   A `DispatchSemaphore.wait(timeout:)` with `semaphoreTimeout` (24 s) is used
    ///   in addition to the URLRequest/URLSession timeout so that a hung OS socket
    ///   does not block the caller thread forever. On expiry the task is cancelled,
    ///   the session is invalidated, and a `timeout_fetch_failure` error is thrown.
    private func _fetchManifest(urlStr: String,
                                 httpHeaders: [String: String]?) throws -> (String, String) {
        // Media-segment extension guard (also catches segment URIs that bypass the outer check).
        guard !_isMediaSegmentUri(urlStr) else {
            throw NSError(
                domain: "VGP4C8W", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "media_segment_uri_rejected: \(urlStr)"]
            )
        }
        guard let url = URL(string: urlStr) else {
            throw NSError(
                domain: "VGP4C8W", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "invalid_url: \(urlStr)"]
            )
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest  = Self.requestTimeout
        cfg.timeoutIntervalForResource = Self.resourceTimeout
        cfg.requestCachePolicy         = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: cfg)

        var request = URLRequest(url: url)
        request.setValue("Vanguard-Manifest-PolicyInspector/1.0", forHTTPHeaderField: "User-Agent")
        // Copy custom headers; only String key+value pairs (already filtered at call site).
        httpHeaders?.forEach { k, v in request.setValue(v, forHTTPHeaderField: k) }

        var resultData:     Data?
        var resultResponse: URLResponse?
        var resultError:    Error?
        let semaphore = DispatchSemaphore(value: 0)

        let task = session.dataTask(with: request) { data, response, error in
            resultData     = data
            resultResponse = response
            resultError    = error
            semaphore.signal()
        }
        task.resume()

        // Bounded wait: semaphoreTimeout exceeds resourceTimeout so URLSession
        // normally fires its own error first. On expiry, cancel the task and
        // invalidate the session immediately to release OS sockets and callbacks.
        let waitOutcome = semaphore.wait(timeout: .now() + Self.semaphoreTimeout)
        if waitOutcome == .timedOut {
            task.cancel()
            session.invalidateAndCancel()
            throw NSError(
                domain: "VGP4C8W", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "timeout_fetch_failure: semaphore expired after \(Int(Self.semaphoreTimeout))s"]
            )
        }
        // Completed normally — finish session to release delegate/callback references.
        session.finishTasksAndInvalidate()

        if let error = resultError { throw error }
        guard let httpResponse = resultResponse as? HTTPURLResponse else {
            throw NSError(domain: "VGP4C8W", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "non_http_response"])
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "VGP4C8W", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "http_error:\(httpResponse.statusCode)"])
        }
        guard let data = resultData else {
            throw NSError(domain: "VGP4C8W", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "no_data"])
        }
        guard data.count <= Self.maxManifestBytes else {
            throw NSError(domain: "VGP4C8W", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "manifest_exceeds_max_bytes"])
        }
        let body       = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        let resolvedUri = httpResponse.url?.absoluteString ?? urlStr
        return (body, resolvedUri)
    }

    // MARK: - Format determination

    private func _determineFormat(uri: String, body: String, hint: String?) -> String {
        if let h = hint?.uppercased(), h == "HLS" || h == "DASH" { return h }
        let lower = uri.lowercased()
        if lower.contains(".m3u8") { return "HLS" }
        if lower.contains(".mpd")  { return "DASH" }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#EXTM3U") { return "HLS" }
        if trimmed.uppercased().hasPrefix("<MPD") || trimmed.hasPrefix("<?xml") { return "DASH" }
        return "HLS"
    }

    // MARK: - HLS inspection

    private func _inspectHls(originalUri: String,
                              resolvedUri: String,
                              body: String) -> [String: Any] {
        let lines = body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var variants       = [[String: Any]]()
        var pendingAttrs: [String: String]? = nil

        var hasExtXPart          = false
        var hasExtXServerControl = false
        var hasExtXPreloadHint   = false
        var hasExtXPartInf       = false
        var hasExtInf            = false
        var hasTargetDuration    = false

        for line in lines {
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-PART:")          || line.hasPrefix("#EXT-X-PART ")          { hasExtXPart          = true }
            if line.hasPrefix("#EXT-X-SERVER-CONTROL:") || line.hasPrefix("#EXT-X-SERVER-CONTROL ") { hasExtXServerControl = true }
            if line.hasPrefix("#EXT-X-PRELOAD-HINT:")  || line.hasPrefix("#EXT-X-PRELOAD-HINT ")  { hasExtXPreloadHint   = true }
            if line.hasPrefix("#EXT-X-PART-INF:")      || line.hasPrefix("#EXT-X-PART-INF ")      { hasExtXPartInf       = true }
            if line.hasPrefix("#EXTINF:")               || line.hasPrefix("#EXTINF ")              { hasExtInf            = true }
            if line.hasPrefix("#EXT-X-TARGETDURATION:") || line.hasPrefix("#EXT-X-TARGETDURATION ") { hasTargetDuration  = true }

            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrStr = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
                pendingAttrs = _parseHlsAttrList(attrStr)
                continue
            }
            if let attrs = pendingAttrs {
                if !line.hasPrefix("#") {
                    let variantUri = _resolveUri(base: resolvedUri, relative: line)
                    let bw         = Int(attrs["BANDWIDTH"] ?? "") ?? 0
                    let avgBw      = Int(attrs["AVERAGE-BANDWIDTH"] ?? "") ?? bw
                    let res        = attrs["RESOLUTION"] ?? ""
                    let resParts   = res.split(separator: "x").map { String($0) }
                    let w          = Int(resParts.first ?? "") ?? 0
                    let h          = Int(resParts.dropFirst().first ?? "") ?? 0
                    let codecs     = attrs["CODECS"] ?? ""
                    let frameRate  = attrs["FRAME-RATE"] ?? "0.0"
                    let name       = attrs["NAME"] ?? ""
                    let cf         = _detectCodecs(codecs)
                    let idx        = variants.count
                    let v: [String: Any] = [
                        "index":            idx,
                        "id":               "",
                        "uri":              variantUri,
                        "rawUri":           line,
                        "adaptationSetId":  "",
                        "bandwidth":        bw,
                        "averageBandwidth": avgBw,
                        "resolution":       res,
                        "width":            w,
                        "height":           h,
                        "codecs":           codecs,
                        "mimeType":         "",
                        "frameRate":        frameRate,
                        "name":             name,
                        "hasAvc":           cf.hasAvc,
                        "hasHevc":          cf.hasHevc,
                        "hasAv1":           cf.hasAv1,
                        "detectedFamilies": cf.families,
                    ]
                    variants.append(v)
                }
                pendingAttrs = nil
            }
        }

        let isMediaPlaylist   = variants.isEmpty && (hasExtInf || hasTargetDuration)
        let variantCount      = variants.count
        let hasAdaptiveLadder = variantCount > 1
        let hasAvc            = variants.contains { $0["hasAvc"]  as? Bool == true }
        let hasHevc           = variants.contains { $0["hasHevc"] as? Bool == true }
        let hasAv1            = variants.contains { $0["hasAv1"]  as? Bool == true }
        let serverPolicyPass  = (!hasHevc && !hasAv1) || hasAvc
        let isLlHls           = hasExtXPart || hasExtXServerControl || hasExtXPreloadHint || hasExtXPartInf

        let rawStatus = "status=OK;format=HLS;variantCount=\(variantCount);" +
            "hasAdaptiveLadder=\(hasAdaptiveLadder);hasAvc=\(hasAvc);" +
            "hasHevc=\(hasHevc);hasAv1=\(hasAv1);serverPolicyPass=\(serverPolicyPass);" +
            "isLlHls=\(isLlHls);isMediaPlaylist=\(isMediaPlaylist)"

        return [
            "format":              "HLS",
            "uri":                 originalUri.isEmpty ? resolvedUri : originalUri,
            "resolvedUri":         resolvedUri,
            "fetchSuccess":        true,
            "parseSuccess":        true,
            "isMediaPlaylist":     isMediaPlaylist,
            "variantCount":        variantCount,
            "representationCount": variantCount,
            "hasAdaptiveLadder":   hasAdaptiveLadder,
            "hasAvc":              hasAvc,
            "hasHevc":             hasHevc,
            "hasAv1":              hasAv1,
            "serverPolicyPass":    serverPolicyPass,
            "llHlsIndicators": [
                "hasExtXPart":          hasExtXPart,
                "hasExtXServerControl": hasExtXServerControl,
                "hasExtXPreloadHint":   hasExtXPreloadHint,
                "hasExtXPartInf":       hasExtXPartInf,
                "isLlHls":              isLlHls,
            ] as [String: Any],
            "variants":        variants,
            "representations": variants,
            "raw":             rawStatus,
        ]
    }

    // MARK: - DASH inspection (manifest-diagnostic only; no AVPlayer)

    private func _inspectDash(originalUri: String,
                               resolvedUri: String,
                               body: String) -> [String: Any] {
        class DashSaxDelegate: NSObject, XMLParserDelegate {
            var videoReps       = [[String: Any]]()
            var asId            = ""
            var asContentType   = ""
            var asMimeType      = ""
            var asCodecs        = ""
            var asWidth         = ""
            var asHeight        = ""
            var asFrameRate     = ""

            func parser(_ parser: XMLParser,
                         didStartElement elementName: String,
                         namespaceURI: String?,
                         qualifiedName qName: String?,
                         attributes attrs: [String: String] = [:]) {
                let tag = elementName.components(separatedBy: ":").last ?? elementName

                if tag == "AdaptationSet" {
                    asId          = attrs["id"]          ?? ""
                    asContentType = attrs["contentType"] ?? ""
                    asMimeType    = attrs["mimeType"]    ?? ""
                    asCodecs      = attrs["codecs"]      ?? ""
                    asWidth       = attrs["width"]       ?? attrs["maxWidth"]  ?? ""
                    asHeight      = attrs["height"]      ?? attrs["maxHeight"] ?? ""
                    asFrameRate   = attrs["frameRate"]   ?? ""
                }

                if tag == "Representation" {
                    let repId    = attrs["id"]        ?? ""
                    let repBw    = Int(attrs["bandwidth"] ?? "") ?? 0
                    let repW     = Int(attrs["width"]     ?? asWidth)  ?? 0
                    let repH     = Int(attrs["height"]    ?? asHeight) ?? 0
                    let repCodecs = (attrs["codecs"]   ?? "").isEmpty ? asCodecs : (attrs["codecs"] ?? "")
                    let repMime  = (attrs["mimeType"]  ?? "").isEmpty ? asMimeType : (attrs["mimeType"] ?? "")
                    let repFR    = (attrs["frameRate"] ?? "").isEmpty ? asFrameRate : (attrs["frameRate"] ?? "")

                    let isVideo = asContentType.lowercased() == "video"
                        || asMimeType.lowercased().hasPrefix("video/")
                        || repMime.lowercased().hasPrefix("video/")
                        || (repW > 0 && repH > 0)
                    guard isVideo else { return }

                    let lower   = repCodecs.lowercased()
                    let hasAvc  = lower.contains("avc1") || lower.contains("avc3")
                    let hasHevc = lower.contains("hvc1") || lower.contains("hev1")
                    let hasAv1  = lower.contains("av01")
                    var families = [String]()
                    if hasAvc  { families.append("avc") }
                    if hasHevc { families.append("hevc") }
                    if hasAv1  { families.append("av1") }
                    if lower.contains("vp09") || lower.contains("vp9") { families.append("vp9") }
                    if lower.contains("mp4a") || lower.contains("aac") { families.append("aac") }

                    let idx = videoReps.count
                    videoReps.append([
                        "index":            idx,
                        "id":               repId,
                        "uri":              "",
                        "rawUri":           "",
                        "adaptationSetId":  asId,
                        "bandwidth":        repBw,
                        "averageBandwidth": repBw,
                        "resolution":       repW > 0 && repH > 0 ? "\(repW)x\(repH)" : "",
                        "width":            repW,
                        "height":           repH,
                        "codecs":           repCodecs,
                        "mimeType":         repMime,
                        "frameRate":        repFR,
                        "name":             "",
                        "hasAvc":           hasAvc,
                        "hasHevc":          hasHevc,
                        "hasAv1":           hasAv1,
                        "detectedFamilies": families,
                    ] as [String: Any])
                }
            }

            func parser(_ parser: XMLParser,
                         didEndElement elementName: String,
                         namespaceURI: String?,
                         qualifiedName qName: String?) {
                let tag = elementName.components(separatedBy: ":").last ?? elementName
                if tag == "AdaptationSet" {
                    asId = ""; asContentType = ""; asMimeType = ""
                    asCodecs = ""; asWidth = ""; asHeight = ""; asFrameRate = ""
                }
            }
        }

        guard let data = body.data(using: .utf8) else {
            return _dashParseFailResult(originalUri: originalUri, resolvedUri: resolvedUri,
                                        reason: "utf8_encode_failed")
        }
        let delegate = DashSaxDelegate()
        let parser   = XMLParser(data: data)
        parser.shouldProcessNamespaces      = true
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = delegate
        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "xml_parse_error"
            return _dashParseFailResult(originalUri: originalUri, resolvedUri: resolvedUri,
                                        reason: reason)
        }

        let reps              = delegate.videoReps
        let repCount          = reps.count
        let hasAdaptiveLadder = repCount > 1
        let hasAvc            = reps.contains { $0["hasAvc"]  as? Bool == true }
        let hasHevc           = reps.contains { $0["hasHevc"] as? Bool == true }
        let hasAv1            = reps.contains { $0["hasAv1"]  as? Bool == true }
        let serverPolicyPass  = (!hasHevc && !hasAv1) || hasAvc

        let rawStatus = "status=OK;format=DASH;representationCount=\(repCount);" +
            "hasAdaptiveLadder=\(hasAdaptiveLadder);hasAvc=\(hasAvc);" +
            "hasHevc=\(hasHevc);hasAv1=\(hasAv1);serverPolicyPass=\(serverPolicyPass)"

        return [
            "format":              "DASH",
            "uri":                 originalUri.isEmpty ? resolvedUri : originalUri,
            "resolvedUri":         resolvedUri,
            "fetchSuccess":        true,
            "parseSuccess":        true,
            "isMediaPlaylist":     false,
            "variantCount":        repCount,
            "representationCount": repCount,
            "hasAdaptiveLadder":   hasAdaptiveLadder,
            "hasAvc":              hasAvc,
            "hasHevc":             hasHevc,
            "hasAv1":              hasAv1,
            "serverPolicyPass":    serverPolicyPass,
            "llHlsIndicators":     [String: Any](),
            "variants":            reps,
            "representations":     reps,
            "raw":                 rawStatus,
        ]
    }

    private func _dashParseFailResult(originalUri: String,
                                       resolvedUri: String,
                                       reason: String) -> [String: Any] {
        return [
            "format":              "DASH",
            "uri":                 originalUri.isEmpty ? resolvedUri : originalUri,
            "resolvedUri":         resolvedUri,
            "fetchSuccess":        true,
            "parseSuccess":        false,
            "isMediaPlaylist":     false,
            "variantCount":        0,
            "representationCount": 0,
            "hasAdaptiveLadder":   false,
            "hasAvc":              false,
            "hasHevc":             false,
            "hasAv1":              false,
            "serverPolicyPass":    false,
            "llHlsIndicators":     [String: Any](),
            "variants":            [[String: Any]](),
            "representations":     [[String: Any]](),
            "raw":                 "status=FAIL;reason=dash_parse_exception:\(reason)",
        ]
    }

    // MARK: - Shared helpers

    private struct _CodecFlags {
        let hasAvc: Bool; let hasHevc: Bool; let hasAv1: Bool
        let families: [String]
    }

    private func _detectCodecs(_ codecsStr: String?) -> _CodecFlags {
        guard let s = codecsStr, !s.isEmpty else {
            return _CodecFlags(hasAvc: false, hasHevc: false, hasAv1: false, families: [])
        }
        var hasAvc = false; var hasHevc = false; var hasAv1 = false
        var families = [String]()
        for c in s.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            if c.hasPrefix("avc1") || c.hasPrefix("avc3") {
                hasAvc = true; if !families.contains("avc") { families.append("avc") }
            } else if c.hasPrefix("hvc1") || c.hasPrefix("hev1") {
                hasHevc = true; if !families.contains("hevc") { families.append("hevc") }
            } else if c.hasPrefix("av01") {
                hasAv1 = true; if !families.contains("av1") { families.append("av1") }
            } else if c.hasPrefix("vp09") || c.hasPrefix("vp9") {
                if !families.contains("vp9") { families.append("vp9") }
            } else if c.hasPrefix("mp4a") || c.hasPrefix("aac") {
                if !families.contains("aac") { families.append("aac") }
            } else if c.hasPrefix("opus") {
                if !families.contains("opus") { families.append("opus") }
            }
        }
        return _CodecFlags(hasAvc: hasAvc, hasHevc: hasHevc, hasAv1: hasAv1, families: families)
    }

    /// Parses a comma-separated HLS attribute list honouring quoted strings.
    private func _parseHlsAttrList(_ attrString: String) -> [String: String] {
        var result = [String: String]()
        var i      = attrString.startIndex
        let end    = attrString.endIndex

        while i < end {
            while i < end && (attrString[i] == " " || attrString[i] == "," ||
                               attrString[i] == "\t" || attrString[i] == "\r" || attrString[i] == "\n") {
                i = attrString.index(after: i)
            }
            guard i < end else { break }
            guard let eqIdx = attrString[i...].firstIndex(of: "=") else { break }

            let key = String(attrString[i..<eqIdx]).trimmingCharacters(in: .whitespaces)
            i = attrString.index(after: eqIdx)
            guard i < end else { break }

            let value: String
            if attrString[i] == "\"" {
                i = attrString.index(after: i)  // skip opening quote
                if let closeQ = attrString[i...].firstIndex(of: "\"") {
                    value = String(attrString[i..<closeQ])
                    i = attrString.index(after: closeQ)
                } else {
                    value = String(attrString[i...])
                    i = end
                }
            } else {
                if let commaIdx = attrString[i...].firstIndex(of: ",") {
                    value = String(attrString[i..<commaIdx]).trimmingCharacters(in: .whitespaces)
                    i = attrString.index(after: commaIdx)
                } else {
                    value = String(attrString[i...]).trimmingCharacters(in: .whitespaces)
                    i = end
                }
            }
            result[key] = value
        }
        return result
    }

    private func _resolveUri(base: String, relative: String) -> String {
        guard !base.isEmpty, let baseURL = URL(string: base) else { return relative }
        return URL(string: relative, relativeTo: baseURL)?.absoluteString ?? relative
    }

    // MARK: - Result builders

    /// Builds a structured result for a fetch-failed spec (e.g. segment-extension rejection).
    private func _fetchFailResult(uri: String,
                                   formatHint: String?,
                                   reason: String,
                                   rawOverride: String? = nil) -> [String: Any] {
        let raw = rawOverride ?? "status=FAIL;reason=fetch_or_parse_exception:\(reason)"
        return [
            "format":              formatHint ?? "UNKNOWN",
            "uri":                 uri,
            "resolvedUri":         uri,
            "fetchSuccess":        false,
            "parseSuccess":        false,
            "isMediaPlaylist":     false,
            "variantCount":        0,
            "representationCount": 0,
            "hasAdaptiveLadder":   false,
            "hasAvc":              false,
            "hasHevc":             false,
            "hasAv1":              false,
            "serverPolicyPass":    false,
            "llHlsIndicators":     [String: Any](),
            "variants":            [[String: Any]](),
            "representations":     [[String: Any]](),
            "raw":                 raw,
        ]
    }

    /// Builds an invalid-spec validation result (mirrors Android's `buildInvalidResult`).
    private func _buildInvalidResult(key: String,
                                      uri: String,
                                      formatHint: String,
                                      failures: [String]) -> [String: Any] {
        return [
            "key":               key,
            "uri":               uri,
            "formatHint":        formatHint,
            "pass":              false,
            "fetchSuccess":      false,
            "parseSuccess":      false,
            "hasAdaptiveLadder": false,
            "variantCount":      0,
            "representationCount": 0,
            "hasAvc":            false,
            "hasHevc":           false,
            "hasAv1":            false,
            "serverPolicyPass":  false,
            "policyFailures":    failures,
            "raw":               "status=FAIL;key=\(key);failures=\(failures.joined(separator: ","))",
            "inspection":        [String: Any](),
        ]
    }

    /// Returns the result for an empty-specs call (mirrors Android's no-spec guard).
    private func _emptySpecsResult() -> [String: Any] {
        return [
            "phase":                   Self.phase,
            "pass":                    false,
            "totalManifestsValidated": 0,
            "passedManifests":         0,
            "failedManifests":         0,
            "segmentRejectionPass":    false,
            "serverLadderPolicy":      Self.serverLadderPolicy,
            "iosMirrorNote":           Self.iosMirrorNote,
            "results":                 [[String: Any]](),
            "segmentRejectionResult":  [String: Any](),
            "raw":                     "status=FAIL;reason=no_manifest_specs",
        ]
    }

    // MARK: - Default public stream specs (match Android defaults exactly)

    private static func _defaultPublicSpecs() -> [[String: Any]] {
        return [
            [
                "key":                  "mux_hls_test",
                "uri":                  defaultHlsUri,
                "formatHint":           "HLS",
                "requireAdaptiveLadder": true,
                "requireAvcFallback":    true,
                "requireLlHlsTags":      false,
                "allowMediaPlaylist":    false,
            ],
            [
                "key":                  "shaka_angel_one_dash",
                "uri":                  defaultDashUri,
                "formatHint":           "DASH",
                "requireAdaptiveLadder": true,
                "requireAvcFallback":    true,
                "requireLlHlsTags":      false,
                "allowMediaPlaylist":    false,
            ],
            [
                "key":                  "mux_ll_hls_test",
                "uri":                  defaultLlHlsUri,
                "formatHint":           "HLS",
                "requireAdaptiveLadder": true,
                "requireAvcFallback":    true,
                "requireLlHlsTags":      false,
                "allowMediaPlaylist":    false,
            ],
        ]
    }
}

// MARK: - VGStreamingCompatibilityDecisionReporter (Phase 4C8X)
//
// iOS native parity for Android Phase 4C5E
// (AdaptiveStreamingCompatibilityDecisionReport + AdaptiveStreamingCompatibilityDecisionSmokeHarness).
//
// Joins Phase 4C8U device codec capability diagnostics with Phase 4C8W manifest policy
// validation into a single structured decision report compatible with the public Dart
// VGStreamingCompatibilityDecisionClient.evaluate() API.
//
// Invariants (mirrors Android mechanical invariants exactly):
//   - Pure diagnostic brain: MUST NEVER instantiate AVPlayer, AVPlayerItem, AVAssetReader,
//     VTDecompressionSession, CVPixelBuffer, FlutterTexture, cache, audio, WebRTC, LiveKit,
//     camera, editor, export, VanguardEngineMode, switchToMode, ABR, or playback mutations.
//   - Calls only validateSpecSync on VGStreamingManifestPolicyValidator and reads the
//     codec-probe map supplied by _buildPhase4C8UCodecCapabilityMap().
//   - Does NOT perform direct network fetches itself; all manifest fetching is delegated
//     to VGStreamingManifestPolicyValidator.validateSpecSync.
//   - All network work on a background queue; FlutterResult called exactly once, on the
//     main thread (DispatchQueue.main).
//   - DASH remains manifest-diagnostic only on iOS; no AVPlayer DASH playback is claimed
//     or implemented.

/// Package-internal reporter that produces Android Phase 4C5E-compatible compatibility
/// decision maps on iOS. The plugin holds an instance and forwards the single method-channel
/// route `runAndroidDagPhase4C5ECompatibilityDecisionSmoke` here.
final class VGStreamingCompatibilityDecisionReporter {

    // ── Phase / policy / note constants (match Android strings exactly) ────────

    private static let phase            = "Phase4C5E"
    private static let serverLadderPolicy = "add_hevc_av1_renditions_but_keep_avc_fallback"
    private static let iosMirrorNote    =
        "iOS implementer must combine AVFoundation/CoreMedia capability with HLS manifest ladders and preserve AVC fallback; iOS DASH remains deferred."

    // ── Warning constants (match Android exactly) ─────────────────────────────

    private static let warningMissingAvcFallback    = "missing_avc_fallback"
    private static let warningAv1SoftwareOnly       = "av1_software_only"
    private static let warningAv1Unsupported        = "av1_unsupported"
    private static let warningHevcSoftwareOnly      = "hevc_software_only"
    private static let warningHevcUnsupported       = "hevc_unsupported"
    private static let warningNoDeviceSafeVideoCodec = "no_device_safe_video_codec"
    private static let warningManifestPolicyFailed  = "manifest_policy_failed"
    private static let warningNoAdaptiveLadder      = "no_adaptive_ladder"

    // ── Decision constants (match Android exactly) ────────────────────────────

    private static let decisionPreferAv1Hardware           = "prefer_av1_hardware"
    private static let decisionPreferHevcHardware          = "prefer_hevc_hardware"
    private static let decisionPreferAvcFallback           = "prefer_avc_fallback"
    private static let decisionBlockedNoSafeCodec          = "blocked_no_safe_codec"
    private static let decisionBlockedManifestPolicyFailed = "blocked_manifest_policy_failed"

    // ── Background queue ──────────────────────────────────────────────────────

    private let bgQueue = DispatchQueue(
        label: "com.vanguard.p4c8x.compatibilityDecision",
        qos: .userInitiated
    )

    // MARK: - Public entry point

    /// Called from the plugin's `handle(_:result:)` dispatch guard.
    /// Resolves specs from `args`, runs all network/validation work on `bgQueue`,
    /// and delivers the aggregate decision map exactly once on `DispatchQueue.main`.
    ///
    /// - Parameters:
    ///   - args: Raw MethodChannel call arguments (may be nil or empty).
    ///   - codecProbe: Pre-built codec capability map from `_buildPhase4C8UCodecCapabilityMap()`.
    ///   - manifestPolicyValidator: Shared validator instance; `validateSpecSync` is called
    ///     only from this method's `bgQueue` — never the main thread.
    ///   - result: FlutterResult closure; called exactly once on `DispatchQueue.main`.
    func evaluate(
        args: [String: Any]?,
        codecProbe: [String: Any],
        manifestPolicyValidator: VGStreamingManifestPolicyValidator,
        result: @escaping FlutterResult
    ) {
        bgQueue.async { [self] in
            let output = self._runDecision(
                args: args,
                codecProbe: codecProbe,
                manifestPolicyValidator: manifestPolicyValidator
            )
            DispatchQueue.main.async { result(output) }
        }
    }

    // MARK: - Orchestration (runs on bgQueue)

    private func _runDecision(
        args: [String: Any]?,
        codecProbe: [String: Any],
        manifestPolicyValidator: VGStreamingManifestPolicyValidator
    ) -> [String: Any] {
        // Resolve manifest specs: use host-supplied list or fall back to canonical defaults
        // (same resolution logic as VGStreamingManifestPolicyValidator._runValidation).
        let specs: [[String: Any]]
        if let raw = args?["manifests"] as? [[String: Any]], !raw.isEmpty {
            specs = raw
        } else if let raw = args?["manifests"] as? [Any], !raw.isEmpty,
                  let typed = raw.compactMap({ $0 as? [String: Any] }) as [[String: Any]]?,
                  !typed.isEmpty {
            specs = typed
        } else {
            specs = Self._defaultPublicSpecs()
        }

        guard !specs.isEmpty else {
            return _emptySpecsResult(codecProbe: codecProbe)
        }

        do {
            let reports = specs.map { spec -> [String: Any] in
                let manifestValidation = manifestPolicyValidator.validateSpecSync(spec)
                return _buildReport(spec: spec, manifestValidation: manifestValidation,
                                    codecProbe: codecProbe)
            }
            return _buildAggregateResult(reports: reports, codecProbe: codecProbe)
        }
    }

    // MARK: - Per-spec report (mirrors Android AdaptiveStreamingCompatibilityDecisionReport.buildReport)

    private func _buildReport(
        spec: [String: Any],
        manifestValidation: [String: Any],
        codecProbe: [String: Any]
    ) -> [String: Any] {
        let key        = (spec["key"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let uri        = (spec["uri"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let formatHint = ((spec["formatHint"] as? String)?.trimmingCharacters(in: .whitespaces)
                            .uppercased()) ?? "AUTO"

        // ── Manifest-side booleans ─────────────────────────────────────────────
        let manifestPolicyPass  = manifestValidation["pass"] as? Bool ?? false
        let hasAdaptiveLadder   = manifestValidation["hasAdaptiveLadder"] as? Bool ?? false
        let avcManifestPresent  = manifestValidation["hasAvc"] as? Bool ?? false
        let hevcManifestPresent = manifestValidation["hasHevc"] as? Bool ?? false
        let av1ManifestPresent  = manifestValidation["hasAv1"] as? Bool ?? false

        // ── Device codec support ───────────────────────────────────────────────
        let avcDeviceSupported  = codecProbe["avcSupported"] as? Bool ?? false
        let hevcDeviceSupported = codecProbe["hevcSupported"] as? Bool ?? false
        let av1DeviceSupported  = codecProbe["av1Supported"] as? Bool ?? false

        // ── Hardware safety from codecs list (mirrors Android exactly) ─────────
        let codecsList = codecProbe["codecs"] as? [[String: Any]] ?? []
        let avcEntry   = codecsList.first { $0["codecKey"] as? String == "avc" }
        let hevcEntry  = codecsList.first { $0["codecKey"] as? String == "hevc" }
        let av1Entry   = codecsList.first { $0["codecKey"] as? String == "av1" }

        let avcHardwareSafe  = avcEntry?["hardwareDecoderPresent"] as? Bool ?? false
        let hevcHardwareSafe = hevcEntry?["hardwareDecoderPresent"] as? Bool ?? false
        let av1HardwareSafe  = av1Entry?["hardwareDecoderPresent"] as? Bool ?? false

        // ── Renditions and bandwidth stats ────────────────────────────────────
        // Extract renditionCount from variantCount then representationCount (Android parity).
        let inspection = manifestValidation["inspection"] as? [String: Any]
        let variantCountRaw = (manifestValidation["variantCount"] as? Int)
            ?? (manifestValidation["variantCount"] as? NSNumber)?.intValue
        let repCountRaw = (manifestValidation["representationCount"] as? Int)
            ?? (manifestValidation["representationCount"] as? NSNumber)?.intValue

        // Variants/representations for bandwidth extraction.
        let variantsAny = inspection?["variants"] as? [[String: Any]]
            ?? inspection?["representations"] as? [[String: Any]]
            ?? []

        let renditionCount = variantCountRaw ?? repCountRaw ?? variantsAny.count

        let bandwidths: [Int] = variantsAny.compactMap {
            let bw = ($0["bandwidth"] as? Int)
                ?? ($0["bandwidth"] as? NSNumber)?.intValue
            guard let b = bw, b > 0 else { return nil }
            return b
        }
        let lowestBandwidth  = bandwidths.min() ?? 0
        let highestBandwidth = bandwidths.max() ?? 0

        // ── Codec selection (mirrors Android preferredCodecFamily logic) ────────
        let preferredCodecFamily: String
        if av1ManifestPresent && av1HardwareSafe {
            preferredCodecFamily = "av1"
        } else if hevcManifestPresent && hevcHardwareSafe {
            preferredCodecFamily = "hevc"
        } else if avcManifestPresent && avcDeviceSupported {
            preferredCodecFamily = "avc"
        } else {
            preferredCodecFamily = "none"
        }

        let fallbackCodecFamily: String = (avcManifestPresent && avcDeviceSupported) ? "avc" : "none"

        var safeCodecFamilies = [String]()
        if avcManifestPresent && avcDeviceSupported  { safeCodecFamilies.append("avc") }
        if hevcManifestPresent && hevcHardwareSafe   { safeCodecFamilies.append("hevc") }
        if av1ManifestPresent  && av1HardwareSafe    { safeCodecFamilies.append("av1") }

        var riskyCodecFamilies = [String]()
        if hevcManifestPresent && (!hevcDeviceSupported || !hevcHardwareSafe) { riskyCodecFamilies.append("hevc") }
        if av1ManifestPresent  && (!av1DeviceSupported  || !av1HardwareSafe)  { riskyCodecFamilies.append("av1") }

        // ── Warnings (mirrors Android exactly) ────────────────────────────────
        var warnings = [String]()
        if !manifestPolicyPass                                              { warnings.append(Self.warningManifestPolicyFailed) }
        if !hasAdaptiveLadder || renditionCount <= 1                        { warnings.append(Self.warningNoAdaptiveLadder) }
        if !avcManifestPresent || !avcDeviceSupported                       { warnings.append(Self.warningMissingAvcFallback) }
        if hevcManifestPresent && !hevcDeviceSupported                      { warnings.append(Self.warningHevcUnsupported) }
        if hevcManifestPresent && hevcDeviceSupported && !hevcHardwareSafe  { warnings.append(Self.warningHevcSoftwareOnly) }
        if av1ManifestPresent  && !av1DeviceSupported                       { warnings.append(Self.warningAv1Unsupported) }
        if av1ManifestPresent  && av1DeviceSupported  && !av1HardwareSafe   { warnings.append(Self.warningAv1SoftwareOnly) }
        if safeCodecFamilies.isEmpty                                        { warnings.append(Self.warningNoDeviceSafeVideoCodec) }

        // ── Decision (mirrors Android exactly) ────────────────────────────────
        let decision: String
        if !manifestPolicyPass {
            decision = Self.decisionBlockedManifestPolicyFailed
        } else if preferredCodecFamily == "none" || safeCodecFamilies.isEmpty {
            decision = Self.decisionBlockedNoSafeCodec
        } else if preferredCodecFamily == "av1" {
            decision = Self.decisionPreferAv1Hardware
        } else if preferredCodecFamily == "hevc" {
            decision = Self.decisionPreferHevcHardware
        } else if preferredCodecFamily == "avc" {
            decision = Self.decisionPreferAvcFallback
        } else {
            decision = Self.decisionBlockedNoSafeCodec
        }

        // ── Pass (mirrors Android pass rule exactly) ───────────────────────────
        // manifest policy passes, preferred codec is not none,
        // if HEVC/AV1 is present then fallback is avc,
        // decision does not start with "blocked_".
        let pass = manifestPolicyPass
            && preferredCodecFamily != "none"
            && ((!hevcManifestPresent && !av1ManifestPresent) || fallbackCodecFamily == "avc")
            && !decision.hasPrefix("blocked_")

        // ── Raw diagnostic string ─────────────────────────────────────────────
        let rawStatus: String
        if pass {
            rawStatus = "status=OK;key=\(key);decision=\(decision);preferred=\(preferredCodecFamily);" +
                "fallback=\(fallbackCodecFamily);safeCodecs=\(safeCodecFamilies.joined(separator: ","));" +
                "renditionCount=\(renditionCount);lowestBandwidth=\(lowestBandwidth);highestBandwidth=\(highestBandwidth)"
        } else {
            rawStatus = "status=COMPATIBILITY_DECISION_FAILED;key=\(key);decision=\(decision);" +
                "preferred=\(preferredCodecFamily);fallback=\(fallbackCodecFamily);" +
                "warnings=\(warnings.joined(separator: ","));manifestPolicyPass=\(manifestPolicyPass)"
        }

        return [
            "key":                  key,
            "uri":                  uri,
            "formatHint":           formatHint,
            "pass":                 pass,
            "manifestPolicyPass":   manifestPolicyPass,
            "avcManifestPresent":   avcManifestPresent,
            "hevcManifestPresent":  hevcManifestPresent,
            "av1ManifestPresent":   av1ManifestPresent,
            "avcDeviceSupported":   avcDeviceSupported,
            "hevcDeviceSupported":  hevcDeviceSupported,
            "av1DeviceSupported":   av1DeviceSupported,
            "avcHardwareSafe":      avcHardwareSafe,
            "hevcHardwareSafe":     hevcHardwareSafe,
            "av1HardwareSafe":      av1HardwareSafe,
            "preferredCodecFamily": preferredCodecFamily,
            "fallbackCodecFamily":  fallbackCodecFamily,
            "safeCodecFamilies":    safeCodecFamilies,
            "riskyCodecFamilies":   riskyCodecFamilies,
            "warnings":             warnings,
            "renditionCount":       renditionCount,
            "lowestBandwidth":      lowestBandwidth,
            "highestBandwidth":     highestBandwidth,
            "decision":             decision,
            "raw":                  rawStatus,
            "manifestValidation":   manifestValidation,
        ]
    }

    // MARK: - Aggregate result (mirrors Android AdaptiveStreamingCompatibilityDecisionReport.buildReports)

    private func _buildAggregateResult(
        reports: [[String: Any]],
        codecProbe: [String: Any]
    ) -> [String: Any] {
        let totalReports  = reports.count
        let passedReports = reports.filter { $0["pass"] as? Bool == true }.count
        let failedReports = totalReports - passedReports

        let codecProbePass = codecProbe["pass"] as? Bool ?? false
        let avcSupported   = codecProbe["avcSupported"] as? Bool ?? false
        let hevcSupported  = codecProbe["hevcSupported"] as? Bool ?? false
        let av1Supported   = codecProbe["av1Supported"] as? Bool ?? false

        let codecsList = codecProbe["codecs"] as? [[String: Any]] ?? []
        let hevcCodec  = codecsList.first { $0["codecKey"] as? String == "hevc" }
        let hevcHardwareSafe = hevcCodec?["hardwareDecoderPresent"] as? Bool ?? false
        let av1Codec   = codecsList.first { $0["codecKey"] as? String == "av1" }
        let av1HardwareSafe  = av1Codec?["hardwareDecoderPresent"] as? Bool ?? false

        var deviceWarnings = [String]()
        if !avcSupported   { deviceWarnings.append(Self.warningMissingAvcFallback) }
        if !hevcSupported  { deviceWarnings.append(Self.warningHevcUnsupported) }
        else if !hevcHardwareSafe { deviceWarnings.append(Self.warningHevcSoftwareOnly) }
        if !av1Supported   { deviceWarnings.append(Self.warningAv1Unsupported) }
        else if !av1HardwareSafe  { deviceWarnings.append(Self.warningAv1SoftwareOnly) }

        let allReportsPass = totalReports > 0 && failedReports == 0
        let pass = allReportsPass && codecProbePass && avcSupported

        let rawStatus: String
        if pass {
            rawStatus = "status=OK;total=\(totalReports);passed=\(passedReports);failed=0;codecProbePass=true;avcSupported=true"
        } else {
            rawStatus = "status=COMPATIBILITY_DECISION_FAILED;total=\(totalReports);passed=\(passedReports);" +
                "failed=\(failedReports);codecProbePass=\(codecProbePass);avcSupported=\(avcSupported)"
        }

        return [
            "phase":             Self.phase,
            "pass":              pass,
            "totalReports":      totalReports,
            "passedReports":     passedReports,
            "failedReports":     failedReports,
            "codecProbePass":    codecProbePass,
            "avcSupported":      avcSupported,
            "hevcSupported":     hevcSupported,
            "av1Supported":      av1Supported,
            "av1HardwareSafe":   av1HardwareSafe,
            "deviceWarnings":    deviceWarnings,
            "serverLadderPolicy": Self.serverLadderPolicy,
            "iosMirrorNote":     Self.iosMirrorNote,
            "reports":           reports,
            "raw":               rawStatus,
        ]
    }

    // MARK: - Empty-specs guard (mirrors Android AdaptiveStreamingCompatibilityDecisionSmokeHarness)

    private func _emptySpecsResult(codecProbe: [String: Any]) -> [String: Any] {
        return [
            "phase":             Self.phase,
            "pass":              false,
            "totalReports":      0,
            "passedReports":     0,
            "failedReports":     0,
            "codecProbePass":    false,
            "avcSupported":      false,
            "hevcSupported":     false,
            "av1Supported":      false,
            "av1HardwareSafe":   false,
            "deviceWarnings":    [String](),
            "serverLadderPolicy": Self.serverLadderPolicy,
            "iosMirrorNote":     Self.iosMirrorNote,
            "reports":           [[String: Any]](),
            "raw":               "status=FAIL;reason=no_manifest_specs",
        ]
    }

    // MARK: - Canonical default public stream specs (match Android defaults exactly)

    private static func _defaultPublicSpecs() -> [[String: Any]] {
        return [
            [
                "key":                   "mux_hls_test",
                "uri":                   "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8",
                "formatHint":            "HLS",
                "requireAdaptiveLadder": true,
                "requireAvcFallback":    true,
                "requireLlHlsTags":      false,
                "allowMediaPlaylist":    false,
            ],
            [
                "key":                   "shaka_angel_one_dash",
                "uri":                   "https://storage.googleapis.com/shaka-demo-assets/angel-one/dash.mpd",
                "formatHint":            "DASH",
                "requireAdaptiveLadder": true,
                "requireAvcFallback":    true,
                "requireLlHlsTags":      false,
                "allowMediaPlaylist":    false,
            ],
            [
                "key":                   "mux_ll_hls_test",
                "uri":                   "https://stream.mux.com/v69RSHhFelSm4701snP22dYz2jICy4E4FUyk02rW4gxRM.m3u8",
                "formatHint":            "HLS",
                "requireAdaptiveLadder": true,
                "requireAvcFallback":    true,
                "requireLlHlsTags":      false,
                "allowMediaPlaylist":    false,
            ],
        ]
    }
}
