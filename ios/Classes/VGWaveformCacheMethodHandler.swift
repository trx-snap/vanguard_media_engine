// VGWaveformCacheMethodHandler.swift
// vanguard_media_engine — Slice Q
//
// Owns all waveform-cache MethodChannel routing, including:
//   - Legacy flat-storage routes (waveformCache_save, waveformCache_load)
//   - Namespaced routes (waveformCache_lookupNamespaced, waveformCache_saveNamespaced,
//     waveformCache_invalidateAsset, waveformCache_invalidateNamespace)
//
// Architecture:
//   - A private serial DispatchQueue serializes all epoch mutations and ObjC I/O.
//   - Epoch state (namespaceEpochs + assetEpochs) is process-local and protected
//     by the serial queue.
//   - A per-handler session ID is embedded in write tokens. A token from a prior
//     process start cannot match the current session ID, blocking stale saves.
//   - Write tokens are HMAC-SHA256 authenticated using CryptoKit and a per-session random key.
//   - FlutterResult is delivered exactly once on the main thread via DispatchQueue.main.async.

import Foundation
import CryptoKit
import Flutter

// ─── Injectable test seams ────────────────────────────────────────────────────

/// Matches the signature used in VGAudioRecordingHandler.
typealias VGWCFlutterErrorFactory = (_ code: String, _ message: String?, _ details: Any?) -> Any

/// Decodes an opaque Flutter samples argument to Data.
/// Production: accepts only FlutterStandardTypedData and returns `.data`.
typealias VGWCSampleDecoder = (_ raw: Any?) -> Data?

private let _productionFlutterErrorFactory: VGWCFlutterErrorFactory = { code, message, details in
    FlutterError(code: code, message: message, details: details)
}

private let _productionSampleDecoder: VGWCSampleDecoder = { raw in
    (raw as? FlutterStandardTypedData)?.data
}

// ─── Constants ────────────────────────────────────────────────────────────────

private let kErrInvalidArg    = "INVALID_ARG"
private let kErrSaveFailed    = "CACHE_SAVE_FAILED"
private let kErrLookupFailed  = "CACHE_LOAD_FAILED"
private let kErrInvalidate    = "CACHE_INVALIDATION_FAILED"
private let kErrUnsafePath    = "CACHE_UNSAFE_PATH"
private let kErrTokenInvalid  = "CACHE_TOKEN_INVALID"
private let kErrLeaseMismatch = "CACHE_LEASE_MISMATCH"

// Token payload JSON keys.
private let kTokVer = "v"
private let kTokNs  = "ns"
private let kTokAk  = "ak"
private let kTokSps = "sps"
private let kTokSid = "sid"
private let kTokNse = "nse"
private let kTokAse = "ase"

// Combined epoch dictionary key: "<namespace>\0<assetKey>"
private let kEpochKeySeparator = "\0"

// Result map keys returned to Dart.
private let kResStatus     = "status"
private let kResResult     = "result"
private let kResWriteLease = "writeLease"

private let kStatusHit   = "hit"
private let kStatusMiss  = "miss"
private let kStatusSaved = "saved"
private let kStatusStale = "stale"

// ─── Base64url helpers (no padding) ──────────────────────────────────────────

private extension Data {
    func base64URLEncoded() -> String {
        return base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    init?(base64URLEncoded string: String) {
        var b64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = b64.count % 4
        if rem != 0 { b64 += String(repeating: "=", count: 4 - rem) }
        self.init(base64Encoded: b64)
    }
}

// ─── Identifier and payload validation helpers ───────────────────────────────

private func isValidIdentifier(_ str: String) -> Bool {
    let utf8 = str.utf8
    let count = utf8.count
    return count >= 1 && count <= 512 && !utf8.contains(0)
}

private func isUnsafePathError(_ error: NSError?) -> Bool {
    guard let err = error else { return false }
    if err.domain == "VGWaveformCache" {
        return (err.code >= 12 && err.code <= 16) ||
               (err.code >= 20 && err.code <= 24) ||
               (err.code >= 30 && err.code <= 38) ||
               (err.code >= 50 && err.code <= 55)
    }
    return false
}

// ─── Waveform result decode helpers ──────────────────────────────────────────

private func encodeWaveformResult(_ r: VGWaveformResult) -> [String: Any] {
    let samplesData = r.samplesData ?? Data()
    return [
        "samples":          FlutterStandardTypedData(bytes: samplesData),
        "durationSeconds":  r.durationSeconds,
        "samplesPerSecond": r.samplesPerSecond,
        "pointCount":       r.pointCount,
    ]
}

// ─── VGWaveformCacheMethodHandler ────────────────────────────────────────────

final class VGWaveformCacheMethodHandler {

    // MARK: – Identity

    private var handlerSessionId: String
    private var handlerSecret: SymmetricKey

    private let cache: VGWaveformCache

    // MARK: – Serial I/O queue

    private let cacheQueue = DispatchQueue(
        label: "com.vanguard.waveformCache.methodHandler",
        qos:   .utility
    )

    // MARK: – Epoch state (guarded by cacheQueue)

    private var namespaceEpochs: [String: Int] = [:]
    private var assetEpochs: [String: Int] = [:]

    // MARK: – Test seams

    let flutterErrorFactory: VGWCFlutterErrorFactory
    let sampleDecoder:       VGWCSampleDecoder

    // MARK: – Init

    init(cache: VGWaveformCache = VGWaveformCache.default(),
         flutterErrorFactory: @escaping VGWCFlutterErrorFactory = _productionFlutterErrorFactory,
         sampleDecoder: @escaping VGWCSampleDecoder = _productionSampleDecoder) {
        self.cache               = cache
        self.flutterErrorFactory = flutterErrorFactory
        self.sampleDecoder       = sampleDecoder
        handlerSessionId = UUID().uuidString
        handlerSecret = SymmetricKey(size: .bits256)
    }

    // MARK: – Epoch overflow rotation (must be called on cacheQueue)

    private func nextEpoch(_ current: Int) -> Int {
        if current == Int.max {
            handlerSecret     = SymmetricKey(size: .bits256)
            handlerSessionId  = UUID().uuidString
            namespaceEpochs   = [:]
            assetEpochs       = [:]
            return 0
        }
        return current + 1
    }

    // MARK: – Epoch helpers (must be called on cacheQueue)

    private func nsEpoch(for namespace: String) -> Int {
        return namespaceEpochs[namespace] ?? 0
    }

    private func assetEpoch(for namespace: String, assetKey: String) -> Int {
        return assetEpochs[combinedKey(namespace, assetKey)] ?? 0
    }

    private func combinedKey(_ namespace: String, _ assetKey: String) -> String {
        return "\(namespace)\(kEpochKeySeparator)\(assetKey)"
    }

    // MARK: – CryptoKit HMAC helpers

    private func computeHMAC(data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: handlerSecret)
        return Data(mac)
    }

    private func verifyHMAC(payloadData: Data, macData: Data) -> Bool {
        return HMAC<SHA256>.isValidAuthenticationCode(macData, authenticating: payloadData, using: handlerSecret)
    }

    // MARK: – Token encoding

    private func buildToken(namespace: String, assetKey: String,
                            samplesPerSecond: Int,
                            nsEpoch: Int, assetEpoch: Int) -> String? {
        let payload: [String: Any] = [
            kTokVer: 1,
            kTokNs:  namespace,
            kTokAk:  assetKey,
            kTokSps: samplesPerSecond,
            kTokSid: handlerSessionId,
            kTokNse: nsEpoch,
            kTokAse: assetEpoch,
        ]
        guard let payloadData = try? JSONSerialization.data(
            withJSONObject: payload,
            options: .sortedKeys
        ) else { return nil }
        let payloadB64 = payloadData.base64URLEncoded()
        let macData = computeHMAC(data: payloadData)
        let macB64 = macData.base64URLEncoded()
        return "\(payloadB64).\(macB64)"
    }

    // MARK: – Token verification

    private struct TokenPayload {
        let namespace: String
        let assetKey: String
        let samplesPerSecond: Int
        let sessionId: String
        let nsEpoch: Int
        let assetEpoch: Int
    }

    private func verifyToken(_ token: String) -> TokenPayload? {
        guard let dotIdx = token.firstIndex(of: ".") else { return nil }
        let payloadB64 = String(token[token.startIndex..<dotIdx])
        let macB64 = String(token[token.index(after: dotIdx)...])
        guard !payloadB64.isEmpty, !macB64.isEmpty else { return nil }
        guard let payloadData = Data(base64URLEncoded: payloadB64),
              let macData = Data(base64URLEncoded: macB64) else { return nil }
        // Verify HMAC BEFORE JSON decoding
        guard verifyHMAC(payloadData: payloadData, macData: macData) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { return nil }
        guard let ver = (json[kTokVer] as? NSNumber)?.intValue, ver == 1,
              let ns  = json[kTokNs]  as? String, isValidIdentifier(ns),
              let ak  = json[kTokAk]  as? String, isValidIdentifier(ak),
              let sid = json[kTokSid] as? String, !sid.isEmpty,
              let sps = (json[kTokSps] as? NSNumber)?.intValue, sps >= 1 && sps <= 1000,
              let nse = (json[kTokNse] as? NSNumber)?.intValue,
              let ase = (json[kTokAse] as? NSNumber)?.intValue
        else { return nil }
        return TokenPayload(namespace: ns, assetKey: ak, samplesPerSecond: sps,
                            sessionId: sid, nsEpoch: nse, assetEpoch: ase)
    }

    // MARK: – FlutterResult delivery helper

    private func deliver(_ result: @escaping FlutterResult, value: Any?) {
        DispatchQueue.main.async { result(value) }
    }

    // MARK: – Unified dispatcher

    func handle(call method: String, args: [String: Any]?, result: @escaping FlutterResult) {
        switch method {
        case "waveformCache_save":
            handleLegacySave(args: args, result: result)
        case "waveformCache_load":
            handleLegacyLoad(args: args, result: result)
        case "waveformCache_lookupNamespaced":
            handleLookupNamespaced(args: args, result: result)
        case "waveformCache_saveNamespaced":
            handleSaveNamespaced(args: args, result: result)
        case "waveformCache_invalidateAsset":
            handleInvalidateAsset(args: args, result: result)
        case "waveformCache_invalidateNamespace":
            handleInvalidateNamespace(args: args, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: – Legacy routes

    func handleLegacySave(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let cacheKey = args?["cacheKey"] as? String, !cacheKey.isEmpty else {
            deliver(result, value: flutterErrorFactory(kErrInvalidArg,
                "cacheKey is required and must be non-empty", nil))
            return
        }
        let samplesData: Data?
        if let typedData = args?["samples"] as? FlutterStandardTypedData {
            samplesData = typedData.data
        } else if let intArray = args?["samples"] as? [Int] {
            var data = Data(capacity: intArray.count)
            for sample in intArray {
                data.append(UInt8(truncatingIfNeeded: sample))
            }
            samplesData = data
        } else if let numArray = args?["samples"] as? [NSNumber] {
            var data = Data(capacity: numArray.count)
            for num in numArray {
                data.append(UInt8(truncatingIfNeeded: num.intValue))
            }
            samplesData = data
        } else {
            samplesData = nil
        }
        guard let samplesData = samplesData, !samplesData.isEmpty else {
            deliver(result, value: flutterErrorFactory(kErrInvalidArg,
                "samples must be non-empty", nil))
            return
        }
        guard let durationSeconds = (args?["durationSeconds"] as? NSNumber)?.doubleValue,
              durationSeconds > 0, durationSeconds.isFinite else {
            deliver(result, value: flutterErrorFactory(kErrInvalidArg,
                "durationSeconds must be finite and > 0", nil))
            return
        }
        guard let sps = (args?["samplesPerSecond"] as? NSNumber)?.intValue, sps > 0 else {
            deliver(result, value: flutterErrorFactory(kErrInvalidArg,
                "samplesPerSecond is required and must be > 0", nil))
            return
        }
        guard let pointCount = (args?["pointCount"] as? NSNumber)?.intValue, pointCount > 0 else {
            deliver(result, value: flutterErrorFactory(kErrInvalidArg,
                "pointCount is required and must be > 0", nil))
            return
        }
        let waveResult = VGWaveformResult(samplesData: samplesData,
                                          durationSeconds: durationSeconds,
                                          samplesPerSecond: sps,
                                          pointCount: pointCount)
        cacheQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.cache.save(waveResult, forCacheKey: cacheKey)
                self.deliver(result, value: nil)
            } catch {
                let nsErr = error as NSError
                self.deliver(result, value: self.flutterErrorFactory(
                    kErrSaveFailed,
                    nsErr.localizedDescription,
                    nil))
            }
        }
    }

    func handleLegacyLoad(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let cacheKey = args?["cacheKey"] as? String, !cacheKey.isEmpty else {
            deliver(result, value: flutterErrorFactory(kErrInvalidArg,
                "cacheKey is required and must be non-empty", nil))
            return
        }
        cacheQueue.async { [weak self] in
            guard let self = self else { return }
            let cached = self.cache.loadResult(forCacheKey: cacheKey)
            if let cached = cached {
                self.deliver(result, value: encodeWaveformResult(cached))
            } else {
                self.deliver(result, value: nil)
            }
        }
    }

    // MARK: – Namespaced lookup

    func handleLookupNamespaced(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let namespace = args?["namespace"] as? String, isValidIdentifier(namespace),
              let assetKey  = args?["assetKey"]  as? String, isValidIdentifier(assetKey),
              let sps = (args?["samplesPerSecond"] as? NSNumber)?.intValue, sps >= 1 && sps <= 1000
        else {
            deliver(result, value: flutterErrorFactory(kErrInvalidArg,
                "namespace, assetKey must be 1-512 UTF-8 bytes without NUL; samplesPerSecond must be in 1-1000",
                nil))
            return
        }
        cacheQueue.async { [weak self] in
            guard let self = self else { return }
            let nse = self.nsEpoch(for: namespace)
            let ase = self.assetEpoch(for: namespace, assetKey: assetKey)
            var loadError: NSError? = nil
            let cached = self.cache.loadNamespacedResult(
                forNamespace: namespace, assetKey: assetKey,
                samplesPerSecond: sps, error: &loadError)
            if let cached = cached {
                let res: [String: Any] = [
                    kResStatus: kStatusHit,
                    kResResult: encodeWaveformResult(cached),
                ]
                self.deliver(result, value: res)
            } else if let loadError = loadError {
                let errCode = isUnsafePathError(loadError) ? kErrUnsafePath : kErrLookupFailed
                self.deliver(result, value: self.flutterErrorFactory(errCode,
                    loadError.localizedDescription, nil))
            } else {
                guard let token = self.buildToken(namespace: namespace, assetKey: assetKey,
                                                   samplesPerSecond: sps,
                                                   nsEpoch: nse, assetEpoch: ase) else {
                    self.deliver(result, value: self.flutterErrorFactory(kErrLookupFailed,
                        "Failed to build write token", nil))
                    return
                }
                let res: [String: Any] = [
                    kResStatus:     kStatusMiss,
                    kResWriteLease: token,
                ]
                self.deliver(result, value: res)
            }
        }
    }

    // MARK: – Namespaced save

    func handleSaveNamespaced(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let token = args?["token"] as? String, !token.isEmpty else {
            deliver(result, value: flutterErrorFactory(kErrInvalidArg,
                "token is required and must be non-empty", nil))
            return
        }
        guard let samplesData = sampleDecoder(args?["samples"]), !samplesData.isEmpty else {
            deliver(result, value: flutterErrorFactory(kErrInvalidArg,
                "samples must be non-empty", nil))
            return
        }
        guard let durationSeconds = (args?["durationSeconds"] as? NSNumber)?.doubleValue,
              durationSeconds > 0, durationSeconds.isFinite else {
            deliver(result, value: flutterErrorFactory(kErrInvalidArg,
                "durationSeconds must be finite and > 0", nil))
            return
        }
        guard let spsArg = (args?["samplesPerSecond"] as? NSNumber)?.intValue,
              spsArg >= 1 && spsArg <= 1000 else {
            deliver(result, value: flutterErrorFactory(kErrInvalidArg,
                "samplesPerSecond is required and must be in 1-1000", nil))
            return
        }
        guard let pointCount = (args?["pointCount"] as? NSNumber)?.intValue,
              pointCount > 0 else {
            deliver(result, value: flutterErrorFactory(kErrInvalidArg,
                "pointCount is required and must be > 0", nil))
            return
        }
        cacheQueue.async { [weak self] in
            guard let self = self else { return }
            guard let tok = self.verifyToken(token) else {
                self.deliver(result, value: self.flutterErrorFactory(
                    kErrTokenInvalid,
                    "Write token is malformed, has an invalid signature, or invalid payload",
                    nil))
                return
            }
            guard tok.sessionId == self.handlerSessionId else {
                self.deliver(result, value: self.flutterErrorFactory(
                    kErrTokenInvalid,
                    "Write token belongs to a prior process session",
                    nil))
                return
            }
            if tok.samplesPerSecond != spsArg {
                self.deliver(result, value: self.flutterErrorFactory(
                    kErrLeaseMismatch,
                    "samplesPerSecond \(spsArg) does not match lease value \(tok.samplesPerSecond)",
                    nil))
                return
            }
            let curNse = self.nsEpoch(for: tok.namespace)
            let curAse = self.assetEpoch(for: tok.namespace, assetKey: tok.assetKey)
            guard tok.nsEpoch == curNse, tok.assetEpoch == curAse else {
                self.deliver(result, value: [kResStatus: kStatusStale])
                return
            }
            let waveResult = VGWaveformResult(samplesData: samplesData,
                                              durationSeconds: durationSeconds,
                                              samplesPerSecond: tok.samplesPerSecond,
                                              pointCount: pointCount)
            do {
                try self.cache.saveNamespacedResult(waveResult,
                    namespace: tok.namespace, assetKey: tok.assetKey,
                    samplesPerSecond: tok.samplesPerSecond)
                self.deliver(result, value: [kResStatus: kStatusSaved])
            } catch {
                let nsErr = error as NSError
                let errCode = isUnsafePathError(nsErr) ? kErrUnsafePath : kErrSaveFailed
                self.deliver(result, value: self.flutterErrorFactory(errCode,
                    nsErr.localizedDescription, nil))
            }
        }
    }

    // MARK: – Asset invalidation

    func handleInvalidateAsset(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let namespace = args?["namespace"] as? String, isValidIdentifier(namespace),
              let assetKey  = args?["assetKey"]  as? String, isValidIdentifier(assetKey)
        else {
            deliver(result, value: flutterErrorFactory(kErrInvalidArg,
                "namespace and assetKey must be 1-512 UTF-8 bytes without NUL", nil))
            return
        }
        cacheQueue.async { [weak self] in
            guard let self = self else { return }
            let ck = self.combinedKey(namespace, assetKey)
            self.assetEpochs[ck] = self.nextEpoch(self.assetEpochs[ck] ?? 0)
            do {
                try self.cache.invalidateAsset(forNamespace: namespace,
                                               assetKey: assetKey)
                self.deliver(result, value: nil)
            } catch {
                let nsErr = error as NSError
                let errCode = isUnsafePathError(nsErr) ? kErrUnsafePath : kErrInvalidate
                self.deliver(result, value: self.flutterErrorFactory(errCode,
                    nsErr.localizedDescription, nil))
            }
        }
    }

    // MARK: – Namespace invalidation

    func handleInvalidateNamespace(args: [String: Any]?, result: @escaping FlutterResult) {
        guard let namespace = args?["namespace"] as? String, isValidIdentifier(namespace) else {
            deliver(result, value: flutterErrorFactory(kErrInvalidArg,
                "namespace must be 1-512 UTF-8 bytes without NUL", nil))
            return
        }
        cacheQueue.async { [weak self] in
            guard let self = self else { return }
            self.namespaceEpochs[namespace] = self.nextEpoch(self.namespaceEpochs[namespace] ?? 0)
            let prefix = namespace + kEpochKeySeparator
            let keysToRemove = self.assetEpochs.keys.filter { $0.hasPrefix(prefix) }
            for k in keysToRemove { self.assetEpochs.removeValue(forKey: k) }
            do {
                try self.cache.invalidateNamespace(namespace)
                self.deliver(result, value: nil)
            } catch {
                let nsErr = error as NSError
                let errCode = isUnsafePathError(nsErr) ? kErrUnsafePath : kErrInvalidate
                self.deliver(result, value: self.flutterErrorFactory(errCode,
                    nsErr.localizedDescription, nil))
            }
        }
    }
}
