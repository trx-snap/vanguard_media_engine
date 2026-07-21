// VGWaveformCacheMethodHandlerTests.swift
// vanguard_media_engine — Slice Q
//
// Unit tests for VGWaveformCacheMethodHandler.

import XCTest
import Flutter
@testable import vanguard_media_engine

private struct FakeFlutterError {
    let code: String
    let message: String?
    let details: Any?
}

private func errorCode(_ result: Any?) -> String? {
    return (result as? FakeFlutterError)?.code
}

private let testFlutterErrorFactory: VGWCFlutterErrorFactory = { code, message, details in
    FakeFlutterError(code: code, message: message, details: details)
}

private let testSampleDecoder: VGWCSampleDecoder = { raw in
    if let data = raw as? Data {
        return data
    }
    return (raw as? FlutterStandardTypedData)?.data
}

final class VGWaveformCacheMethodHandlerTests: XCTestCase {

    private var tmpRootPath: String!
    private var externalTmpPath: String!
    private var extraCleanupPaths: [String] = []
    private var cache: VGWaveformCache!
    private var handler: VGWaveformCacheMethodHandler!

    override func setUp() {
        super.setUp()
        let uuid = UUID().uuidString
        tmpRootPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("VGHanTest_\(uuid)")
        externalTmpPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("VGHanExt_\(uuid)")
        extraCleanupPaths = []

        let url = URL(fileURLWithPath: tmpRootPath, isDirectory: true)
        cache = VGWaveformCache(rootDirectoryURL: url)
        handler = VGWaveformCacheMethodHandler(cache: cache,
                                               flutterErrorFactory: testFlutterErrorFactory,
                                               sampleDecoder: testSampleDecoder)
    }

    override func tearDown() {
        let fm = FileManager.default
        // Registered symlink paths FIRST unconditionally (do not depend on fileExists which follows symlinks)
        for path in extraCleanupPaths {
            try? fm.removeItem(atPath: path)
        }
        extraCleanupPaths.removeAll()

        if let tmpRoot = tmpRootPath {
            try? fm.removeItem(atPath: tmpRoot)
        }
        // External target directory LAST
        if let extTmp = externalTmpPath {
            try? fm.removeItem(atPath: extTmp)
        }

        handler = nil
        cache = nil
        tmpRootPath = nil
        externalTmpPath = nil
        super.tearDown()
    }

    // MARK: - Helper

    @discardableResult
    private func invoke(
        _ targetHandler: VGWaveformCacheMethodHandler? = nil,
        method: String,
        args: [String: Any]?
    ) -> (result: Any?, callCount: Int, isMainThread: Bool) {
        let h = targetHandler ?? handler!
        let firstExp = expectation(description: "handler_\(method)_first_callback")
        let extraExp = expectation(description: "handler_\(method)_extra_callback")
        extraExp.isInverted = true

        var capturedResult: Any?
        var callCount = 0
        var isMainThread = false

        h.handle(call: method, args: args) { res in
            callCount += 1
            if callCount == 1 {
                capturedResult = res
                isMainThread = Thread.isMainThread
                firstExp.fulfill()
            } else {
                extraExp.fulfill()
            }
        }

        wait(for: [firstExp, extraExp], timeout: 1.0)
        return (capturedResult, callCount, isMainThread)
    }

    private func makeSampleData(pointCount: Int = 4) -> Data {
        var samples = [Float]()
        for i in 1...pointCount {
            samples.append(Float(i) * 0.1)
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    private func mutateBase64Segment(_ segment: Substring) -> String {
        var chars = Array(String(segment))
        guard !chars.isEmpty else { return "A" }
        chars[0] = (chars[0] == "A") ? "B" : "A"
        return String(chars)
    }

    // MARK: - Tests

    // 1. Lookup miss returns a non-empty opaque write lease
    func testLookupMissReturnsNonEmptyWriteLease() {
        let (res, count, isMain) = invoke(method: "waveformCache_lookupNamespaced", args: [
            "namespace": "ns1",
            "assetKey": "key1",
            "samplesPerSecond": 100
        ])

        XCTAssertEqual(count, 1)
        XCTAssertTrue(isMain)
        guard let dict = res as? [String: Any] else {
            XCTFail("Result should be dictionary")
            return
        }

        XCTAssertEqual(dict["status"] as? String, "miss")
        let lease = dict["writeLease"] as? String
        XCTAssertNotNil(lease)
        XCTAssertFalse(lease!.isEmpty)
    }

    // 2. Valid lease saves successfully
    func testValidLeaseSavesSuccessfully() {
        let (lookupRes, _, _) = invoke(method: "waveformCache_lookupNamespaced", args: [
            "namespace": "ns1",
            "assetKey": "key1",
            "samplesPerSecond": 100
        ])
        let lease = (lookupRes as? [String: Any])?["writeLease"] as? String
        XCTAssertNotNil(lease)

        let (saveRes, count, isMain) = invoke(method: "waveformCache_saveNamespaced", args: [
            "token": lease!,
            "samples": makeSampleData(pointCount: 4),
            "durationSeconds": 2.0,
            "samplesPerSecond": 100,
            "pointCount": 4
        ])

        XCTAssertEqual(count, 1)
        XCTAssertTrue(isMain)
        let dict = saveRes as? [String: Any]
        XCTAssertEqual(dict?["status"] as? String, "saved")
    }

    // 3a. Payload tampering returns CACHE_TOKEN_INVALID independently
    func testPayloadTamperingReturnsTokenInvalid() {
        let (lookupRes, _, _) = invoke(method: "waveformCache_lookupNamespaced", args: [
            "namespace": "ns1",
            "assetKey": "key1",
            "samplesPerSecond": 100
        ])
        let lease = (lookupRes as? [String: Any])?["writeLease"] as? String
        XCTAssertNotNil(lease)

        let parts = lease!.split(separator: ".")
        XCTAssertEqual(parts.count, 2)
        let tamperedPayload = mutateBase64Segment(parts[0])
        let tamperedToken = "\(tamperedPayload).\(parts[1])"

        let (saveRes, _, isMain) = invoke(method: "waveformCache_saveNamespaced", args: [
            "token": tamperedToken,
            "samples": makeSampleData(),
            "durationSeconds": 2.0,
            "samplesPerSecond": 100,
            "pointCount": 4
        ])

        XCTAssertTrue(isMain)
        XCTAssertEqual(errorCode(saveRes), "CACHE_TOKEN_INVALID")
    }

    // 3b. Signature tampering returns CACHE_TOKEN_INVALID independently
    func testSignatureTamperingReturnsTokenInvalid() {
        let (lookupRes, _, _) = invoke(method: "waveformCache_lookupNamespaced", args: [
            "namespace": "ns1",
            "assetKey": "key1",
            "samplesPerSecond": 100
        ])
        let lease = (lookupRes as? [String: Any])?["writeLease"] as? String
        XCTAssertNotNil(lease)

        let parts = lease!.split(separator: ".")
        XCTAssertEqual(parts.count, 2)
        let tamperedSignature = mutateBase64Segment(parts[1])
        let tamperedToken = "\(parts[0]).\(tamperedSignature)"

        let (saveRes, _, isMain) = invoke(method: "waveformCache_saveNamespaced", args: [
            "token": tamperedToken,
            "samples": makeSampleData(),
            "durationSeconds": 2.0,
            "samplesPerSecond": 100,
            "pointCount": 4
        ])

        XCTAssertTrue(isMain)
        XCTAssertEqual(errorCode(saveRes), "CACHE_TOKEN_INVALID")
    }

    // 4. Malformed tokens return CACHE_TOKEN_INVALID
    func testMalformedTokenReturnsTokenInvalid() {
        let (saveRes, _, isMain) = invoke(method: "waveformCache_saveNamespaced", args: [
            "token": "invalid_token_without_dot",
            "samples": makeSampleData(),
            "durationSeconds": 2.0,
            "samplesPerSecond": 100,
            "pointCount": 4
        ])

        XCTAssertTrue(isMain)
        XCTAssertEqual(errorCode(saveRes), "CACHE_TOKEN_INVALID")
    }

    // 5. A token created by handler A is rejected by handler B
    func testTokenFromHandlerARejectedByHandlerB() {
        let handlerB = VGWaveformCacheMethodHandler(cache: cache,
                                                    flutterErrorFactory: testFlutterErrorFactory,
                                                    sampleDecoder: testSampleDecoder)

        let (lookupRes, _, _) = invoke(handler, method: "waveformCache_lookupNamespaced", args: [
            "namespace": "ns1",
            "assetKey": "key1",
            "samplesPerSecond": 100
        ])
        let lease = (lookupRes as? [String: Any])?["writeLease"] as? String
        XCTAssertNotNil(lease)

        let (saveRes, _, isMain) = invoke(handlerB, method: "waveformCache_saveNamespaced", args: [
            "token": lease!,
            "samples": makeSampleData(),
            "durationSeconds": 2.0,
            "samplesPerSecond": 100,
            "pointCount": 4
        ])

        XCTAssertTrue(isMain)
        XCTAssertEqual(errorCode(saveRes), "CACHE_TOKEN_INVALID")
    }

    // 6. Lease SPS disagreement returns CACHE_LEASE_MISMATCH
    func testLeaseSPSDisagreementReturnsLeaseMismatch() {
        let (lookupRes, _, _) = invoke(method: "waveformCache_lookupNamespaced", args: [
            "namespace": "ns1",
            "assetKey": "key1",
            "samplesPerSecond": 100
        ])
        let lease = (lookupRes as? [String: Any])?["writeLease"] as? String
        XCTAssertNotNil(lease)

        let (saveRes, _, isMain) = invoke(method: "waveformCache_saveNamespaced", args: [
            "token": lease!,
            "samples": makeSampleData(),
            "durationSeconds": 2.0,
            "samplesPerSecond": 200,
            "pointCount": 4
        ])

        XCTAssertTrue(isMain)
        XCTAssertEqual(errorCode(saveRes), "CACHE_LEASE_MISMATCH")
    }

    // 7. Asset invalidation makes earlier asset lease return stale
    func testAssetInvalidationStalesLease() {
        let (lookupRes, _, _) = invoke(method: "waveformCache_lookupNamespaced", args: [
            "namespace": "ns1",
            "assetKey": "key1",
            "samplesPerSecond": 100
        ])
        let lease = (lookupRes as? [String: Any])?["writeLease"] as? String
        XCTAssertNotNil(lease)

        invoke(method: "waveformCache_invalidateAsset", args: [
            "namespace": "ns1",
            "assetKey": "key1"
        ])

        let (saveRes, _, isMain) = invoke(method: "waveformCache_saveNamespaced", args: [
            "token": lease!,
            "samples": makeSampleData(),
            "durationSeconds": 2.0,
            "samplesPerSecond": 100,
            "pointCount": 4
        ])

        XCTAssertTrue(isMain)
        let dict = saveRes as? [String: Any]
        XCTAssertEqual(dict?["status"] as? String, "stale")
    }

    // 8. Namespace invalidation makes every earlier lease in that namespace return stale
    func testNamespaceInvalidationStalesAllLeasesInNamespace() {
        let (lookup1, _, _) = invoke(method: "waveformCache_lookupNamespaced", args: [
            "namespace": "ns1", "assetKey": "key1", "samplesPerSecond": 100
        ])
        let (lookup2, _, _) = invoke(method: "waveformCache_lookupNamespaced", args: [
            "namespace": "ns1", "assetKey": "key2", "samplesPerSecond": 100
        ])

        let lease1 = (lookup1 as? [String: Any])?["writeLease"] as? String
        let lease2 = (lookup2 as? [String: Any])?["writeLease"] as? String
        XCTAssertNotNil(lease1)
        XCTAssertNotNil(lease2)

        invoke(method: "waveformCache_invalidateNamespace", args: ["namespace": "ns1"])

        let (save1, _, _) = invoke(method: "waveformCache_saveNamespaced", args: [
            "token": lease1!, "samples": makeSampleData(), "durationSeconds": 2.0, "samplesPerSecond": 100, "pointCount": 4
        ])
        let (save2, _, _) = invoke(method: "waveformCache_saveNamespaced", args: [
            "token": lease2!, "samples": makeSampleData(), "durationSeconds": 2.0, "samplesPerSecond": 100, "pointCount": 4
        ])

        XCTAssertEqual((save1 as? [String: Any])?["status"] as? String, "stale")
        XCTAssertEqual((save2 as? [String: Any])?["status"] as? String, "stale")
    }

    // 9. Invalidation of one asset does not stale a sibling asset lease
    func testInvalidationOfOneAssetDoesNotStaleSiblingAssetLease() {
        let (lookup1, _, _) = invoke(method: "waveformCache_lookupNamespaced", args: [
            "namespace": "ns1", "assetKey": "key1", "samplesPerSecond": 100
        ])
        let (lookup2, _, _) = invoke(method: "waveformCache_lookupNamespaced", args: [
            "namespace": "ns1", "assetKey": "key2", "samplesPerSecond": 100
        ])

        let lease1 = (lookup1 as? [String: Any])?["writeLease"] as? String
        let lease2 = (lookup2 as? [String: Any])?["writeLease"] as? String
        XCTAssertNotNil(lease1)
        XCTAssertNotNil(lease2)

        invoke(method: "waveformCache_invalidateAsset", args: [
            "namespace": "ns1", "assetKey": "key1"
        ])

        let (save2, _, _) = invoke(method: "waveformCache_saveNamespaced", args: [
            "token": lease2!, "samples": makeSampleData(), "durationSeconds": 2.0, "samplesPerSecond": 100, "pointCount": 4
        ])

        XCTAssertEqual((save2 as? [String: Any])?["status"] as? String, "saved")
    }

    // 10. Invalidation of one namespace does not stale another namespace lease
    func testInvalidationOfOneNamespaceDoesNotStaleAnotherNamespaceLease() {
        let (lookup1, _, _) = invoke(method: "waveformCache_lookupNamespaced", args: [
            "namespace": "ns1", "assetKey": "key1", "samplesPerSecond": 100
        ])
        let (lookup2, _, _) = invoke(method: "waveformCache_lookupNamespaced", args: [
            "namespace": "ns2", "assetKey": "key1", "samplesPerSecond": 100
        ])

        let lease1 = (lookup1 as? [String: Any])?["writeLease"] as? String
        let lease2 = (lookup2 as? [String: Any])?["writeLease"] as? String
        XCTAssertNotNil(lease1)
        XCTAssertNotNil(lease2)

        invoke(method: "waveformCache_invalidateNamespace", args: ["namespace": "ns1"])

        let (save2, _, _) = invoke(method: "waveformCache_saveNamespaced", args: [
            "token": lease2!, "samples": makeSampleData(), "durationSeconds": 2.0, "samplesPerSecond": 100, "pointCount": 4
        ])

        XCTAssertEqual((save2 as? [String: Any])?["status"] as? String, "saved")
    }

    // 11. Unsafe native path failures map to CACHE_UNSAFE_PATH
    func testUnsafeNativePathFailuresMapToCacheUnsafePath() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: externalTmpPath, withIntermediateDirectories: true)
        let externalMarkerPath = (externalTmpPath as NSString).appendingPathComponent("external_marker.txt")
        let markerPayload = "external_marker_payload"
        try? markerPayload.write(toFile: externalMarkerPath, atomically: true, encoding: .utf8)

        let symRootPath = (NSTemporaryDirectory() as NSString).appendingPathComponent("VGSymRoot_\(UUID().uuidString)")
        extraCleanupPaths.append(symRootPath)
        defer {
            try? fm.removeItem(atPath: symRootPath)
        }

        try? fm.createSymbolicLink(atPath: symRootPath, withDestinationPath: externalTmpPath)

        let symCache = VGWaveformCache(rootDirectoryURL: URL(fileURLWithPath: symRootPath, isDirectory: true))
        let symHandler = VGWaveformCacheMethodHandler(cache: symCache,
                                                       flutterErrorFactory: testFlutterErrorFactory,
                                                       sampleDecoder: testSampleDecoder)

        let (symLookupRes, _, _) = invoke(symHandler, method: "waveformCache_lookupNamespaced", args: [
            "namespace": "ns1", "assetKey": "key1", "samplesPerSecond": 100
        ])
        XCTAssertEqual(errorCode(symLookupRes), "CACHE_UNSAFE_PATH")

        let (symInvRes, _, _) = invoke(symHandler, method: "waveformCache_invalidateNamespace", args: [
            "namespace": "ns1"
        ])
        XCTAssertEqual(errorCode(symInvRes), "CACHE_UNSAFE_PATH")

        XCTAssertTrue(fm.fileExists(atPath: externalMarkerPath), "External marker file must remain intact")
        let currentPayload = try? String(contentsOfFile: externalMarkerPath, encoding: .utf8)
        XCTAssertEqual(currentPayload, markerPayload, "External marker payload must remain unchanged")
    }

    // 12. Each invocation delivers exactly one result on the main thread
    func testInvocationDeliversExactlyOneResultOnMainThread() {
        let (res, callCount, isMainThread) = invoke(method: "waveformCache_lookupNamespaced", args: [
            "namespace": "ns_main_test", "assetKey": "key1", "samplesPerSecond": 100
        ])

        XCTAssertEqual(callCount, 1, "Must deliver callback exactly once")
        XCTAssertTrue(isMainThread, "Must deliver callback on main thread")
        XCTAssertNotNil(res)
    }
}
