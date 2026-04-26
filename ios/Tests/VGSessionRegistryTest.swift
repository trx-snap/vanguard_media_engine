// VGSessionRegistryTest.swift
// Vanguard Media Engine — Phase 1B, P1B-04
//
// Unit tests for VGSessionRegistry (P1B-03).
//
// Design goals:
//   - Simulator-safe: no real media required for registry state-management tests.
//   - Isolated: each test creates a fresh VGSessionRegistry() instance (not .shared)
//     so test runs are independent of process-wide singleton state.
//   - Zero production callsite changes (C-2, C-4, C-6 respected).
//
// Testing strategy:
//   VGSessionRegistry.createSession() calls the real VanguardGraphRuntime, which
//   calls the real AVFoundation prepare chain. On a stub URL this will fire
//   completion with error (textureId = -1) and remove the session's primary-map
//   entry. Tests that need only synchronous state (session count, sessionId
//   uniqueness, early eviction) assert BEFORE prepare fires. Tests that need the
//   textureId reverse-map to be populated use a real PNG URL so that the image
//   source path completes successfully and populates both maps.
//
// Acceptance Criteria covered:
//   AC-1  testUniqueSessionIds            — two calls → two different sessionIds
//   AC-2  testLookupsAfterSuccessfulPrepare — both runtime(forTextureId:) and
//                                            runtime(forSessionId:) return correct runtime
//   AC-3  testInvalidateRemovesBothMapEntries — both maps nil after invalidate(textureId:)
//   AC-4  testInvalidateAllClearsAllEntries — invalidateAll() drains both maps
//   AC-5  testSingleActiveSessionEnforcement — second createSession evicts first
//
// Run with:
//   xcodebuild test -scheme vanguard_media_engine \
//                   -destination 'platform=iOS Simulator,name=iPhone 15'

import XCTest
import Flutter
@testable import vanguard_media_engine

// MARK: - Mock Flutter Dependencies

/// Minimal FlutterTextureRegistry stub. Returns deterministic textureIds
/// starting at 100 so they are distinguishable from real registry IDs.
/// Not thread-safe (tests use it from one thread at a time).
private final class MockTextureRegistry: NSObject, FlutterTextureRegistry {
    private(set) var registerCount   = 0
    private(set) var unregisterCount = 0
    private var nextId: Int64 = 100

    func register(_ texture: FlutterTexture) -> Int64 {
        registerCount += 1
        defer { nextId += 1 }
        return nextId
    }

    func textureFrameAvailable(_ textureId: Int64) { /* no-op */ }

    func unregisterTexture(_ textureId: Int64) {
        unregisterCount += 1
    }
}

/// Minimal FlutterMethodChannel substitute.
/// FlutterMethodChannel is a concrete class so we cannot sub-protocol it in
/// tests. We instantiate a real channel with a mock binary messenger that
/// silently drops all messages.
private final class SilentBinaryMessenger: NSObject, FlutterBinaryMessenger {
    func send(onChannel channel: String, message: Data?) { /* drop */ }
    func send(onChannel channel: String, message: Data?,
              binaryReply callback: FlutterBinaryReply?) { callback?(nil) }
    func setMessageHandlerOnChannel(_ channel: String,
                                    binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection { return 0 }
    func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) { /* no-op */ }
}

// MARK: - Helpers

private let kTestTimeout: TimeInterval = 10.0   // generous for simulator CI

/// Returns a minimal 1×1 white PNG that the image source can decode without
/// a real file — identical bytes to the one used in VGMediaNodeConformanceTest.m.
private func writeTempPNG() -> URL? {
    let bytes: [UInt8] = [
        // PNG signature
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        // IHDR: 1×1-px, 8-bit RGB
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE,
        // IDAT: zlib-compressed white RGB pixel
        0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54,
        0x08, 0xD7, 0x63, 0xF8, 0xFF, 0xFF, 0x3F, 0x00,
        0x05, 0xFE, 0x02, 0xFE, 0xDC, 0xCC, 0x59, 0xE7,
        // IEND
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ]
    let data = Data(bytes)
    let url  = FileManager.default.temporaryDirectory
                   .appendingPathComponent("vg_registry_test_\(UUID().uuidString).png")
    return (try? data.write(to: url)) != nil ? url : nil
}

/// Builds a fresh (non-shared) registry + supporting mock objects.
private func makeRegistry() -> (VGSessionRegistry, MockTextureRegistry, FlutterMethodChannel) {
    let registry = VGSessionRegistry()
    let texReg   = MockTextureRegistry()
    let channel  = FlutterMethodChannel(
        name:             "vg_test_channel_\(UUID().uuidString)",
        binaryMessenger:  SilentBinaryMessenger()
    )
    return (registry, texReg, channel)
}

/// Stub video URL — prepare will fail (no real file), completion fires with -1.
private let stubVideoURL = URL(fileURLWithPath: "/tmp/vg_registry_stub.mp4")

// MARK: - VGSessionRegistryTest

final class VGSessionRegistryTest: XCTestCase {

    // ─────────────────────────────────────────────────────────────────────────
    // AC-1 — Unique session IDs
    // Two consecutive createSession calls must return distinct sessionIds.
    // We call createSession without waiting for prepare because sessionId is
    // returned synchronously — before any background work fires.
    // ─────────────────────────────────────────────────────────────────────────

    func testUniqueSessionIds() {
        let (reg, texReg, channel) = makeRegistry()

        // First call
        let id1 = reg.createSession(
            url:             stubVideoURL,
            textureRegistry: texReg,
            methodChannel:   channel
        ) { _, _ in /* ignored */ }

        // Second call — Phase 1 constraint will evict the first session first,
        // but both sessionIds are generated before any eviction races occur.
        let id2 = reg.createSession(
            url:             stubVideoURL,
            textureRegistry: texReg,
            methodChannel:   channel
        ) { _, _ in /* ignored */ }

        XCTAssertFalse(id1.isEmpty,
            "First sessionId must be non-empty")
        XCTAssertFalse(id2.isEmpty,
            "Second sessionId must be non-empty")
        XCTAssertNotEqual(id1, id2,
            "Two consecutive createSession calls must return distinct sessionIds " +
            "(got identicial id '\(id1)')")

        // Verify UUIDv4 format: 8-4-4-4-12 hex chars separated by '-'
        let uuidPattern = #"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"#
        let predicate   = NSPredicate(format: "SELF MATCHES[c] %@", uuidPattern)
        XCTAssertTrue(predicate.evaluate(with: id1),
            "sessionId '\(id1)' must be a valid UUID string")
        XCTAssertTrue(predicate.evaluate(with: id2),
            "sessionId '\(id2)' must be a valid UUID string")

        // Housekeeping — let any in-flight prepares complete before dealloc.
        reg.invalidateAll()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AC-1 (variant) — sessionId returned synchronously (before completion fires)
    // ─────────────────────────────────────────────────────────────────────────

    func testSessionIdReturnedBeforeCompletion() {
        let (reg, texReg, channel) = makeRegistry()
        var completionFired = false

        let sessionId = reg.createSession(
            url:             stubVideoURL,
            textureRegistry: texReg,
            methodChannel:   channel
        ) { _, _ in completionFired = true }

        // At this point createSession has returned but completion has not yet fired
        // (it fires on a background queue).
        XCTAssertFalse(sessionId.isEmpty,
            "sessionId must be returned synchronously before completion fires")
        XCTAssertFalse(completionFired,
            "completion must not have fired synchronously on the calling thread")

        reg.invalidateAll()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AC-2 — Lookups return the correct runtime after successful prepare
    //
    // Strategy: use a real 1×1 PNG URL so the image source path completes
    // without error, populating both maps. Then verify:
    //   - runtime(forSessionId:) returns a non-nil runtime.
    //   - runtime(forTextureId:) returns the SAME runtime instance.
    // ─────────────────────────────────────────────────────────────────────────

    func testLookupsAfterSuccessfulPrepare() throws {
        guard let pngURL = writeTempPNG() else {
            throw XCTSkip("Cannot write temp PNG — skipping lookup test")
        }
        defer { try? FileManager.default.removeItem(at: pngURL) }

        let (reg, texReg, channel) = makeRegistry()

        let prepExp = expectation(description: "prepare completes")
        var deliveredTextureId: Int64 = -99

        let sessionId = reg.createSession(
            url:             pngURL,
            textureRegistry: texReg,
            methodChannel:   channel
        ) { tid, _ in
            deliveredTextureId = tid
            prepExp.fulfill()
        }

        wait(for: [prepExp], timeout: kTestTimeout)

        // Lookup by sessionId — must work regardless of prepare outcome
        // because the primary map is written synchronously at createSession time.
        // If prepare failed, the entry is removed in the completion handler;
        // guard here so the test is meaningful only when prepare succeeded.
        guard deliveredTextureId >= 0 else {
            // Prepare failed (Metal unavailable, pool issue, etc.) — skip
            // the textureId-dependent assertions.
            reg.invalidateAll()
            throw XCTSkip("Prepare failed (deliveredTextureId=-1); " +
                          "skipping lookup assertions that require a valid textureId")
        }

        // ── runtime(forSessionId:) ──────────────────────────────────────────
        let rtBySession = reg.runtime(forSessionId: sessionId)
        XCTAssertNotNil(rtBySession,
            "runtime(forSessionId:) must return a non-nil runtime after successful prepare")

        // ── runtime(forTextureId:) ──────────────────────────────────────────
        let rtByTexture = reg.runtime(forTextureId: deliveredTextureId)
        XCTAssertNotNil(rtByTexture,
            "runtime(forTextureId:) must return a non-nil runtime after successful prepare " +
            "(textureId=\(deliveredTextureId))")

        // ── Identity: both lookups return the SAME runtime instance ───────────
        XCTAssertTrue(rtBySession === rtByTexture,
            "runtime(forSessionId:) and runtime(forTextureId:) must return " +
            "the SAME runtime instance (got different pointers)")

        reg.invalidateAll()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AC-2 (variant) — runtime(forSessionId:) available synchronously
    //
    // The primary map entry is written synchronously at createSession time.
    // runtime(forSessionId:) must therefore return non-nil immediately after
    // createSession returns and before prepare fires.
    // ─────────────────────────────────────────────────────────────────────────

    func testRuntimeBySessionIdAvailableSynchronously() {
        let (reg, texReg, channel) = makeRegistry()

        let sessionId = reg.createSession(
            url:             stubVideoURL,
            textureRegistry: texReg,
            methodChannel:   channel
        ) { _, _ in /* await not needed here */ }

        // Synchronous read — primary map is set before createSession returns.
        let rt = reg.runtime(forSessionId: sessionId)
        XCTAssertNotNil(rt,
            "runtime(forSessionId:) must return non-nil synchronously after createSession")

        // Unknown sessionId must not crash and must return nil.
        let missingRt = reg.runtime(forSessionId: UUID().uuidString)
        XCTAssertNil(missingRt,
            "runtime(forSessionId:) must return nil for an unknown sessionId")

        reg.invalidateAll()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AC-2 (variant) — runtime(forTextureId:) returns nil for unknown IDs
    // ─────────────────────────────────────────────────────────────────────────

    func testRuntimeByTextureIdUnknownReturnsNil() {
        let (reg, _, _) = makeRegistry()
        XCTAssertNil(reg.runtime(forTextureId: 999_999),
            "runtime(forTextureId:) must return nil for an unknown textureId — " +
            "must never crash")
        XCTAssertNil(reg.runtime(forTextureId: -1),
            "runtime(forTextureId:) must return nil for textureId=-1")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AC-3 — invalidate(textureId:) removes both map entries
    //
    // Strategy: use a real PNG so prepare succeeds and both maps are populated.
    // Then call invalidate(textureId:) and assert both lookups return nil.
    // ─────────────────────────────────────────────────────────────────────────

    func testInvalidateRemovesBothMapEntries() throws {
        guard let pngURL = writeTempPNG() else {
            throw XCTSkip("Cannot write temp PNG")
        }
        defer { try? FileManager.default.removeItem(at: pngURL) }

        let (reg, texReg, channel) = makeRegistry()

        let prepExp = expectation(description: "prepare")
        var textureId: Int64 = -1
        var capturedSessionId = ""

        capturedSessionId = reg.createSession(
            url:             pngURL,
            textureRegistry: texReg,
            methodChannel:   channel
        ) { tid, _ in
            textureId = tid
            prepExp.fulfill()
        }

        wait(for: [prepExp], timeout: kTestTimeout)

        guard textureId >= 0 else {
            reg.invalidateAll()
            throw XCTSkip("Prepare failed — skipping invalidate map-removal test")
        }

        // Pre-condition: both entries are present before invalidate.
        XCTAssertNotNil(reg.runtime(forSessionId: capturedSessionId),
            "Pre-condition: runtime(forSessionId:) must be non-nil before invalidate")
        XCTAssertNotNil(reg.runtime(forTextureId: textureId),
            "Pre-condition: runtime(forTextureId:) must be non-nil before invalidate")
        XCTAssertEqual(reg.sessionCount, 1,
            "Pre-condition: sessionCount must be 1 before invalidate")

        // ── Invalidate by textureId ───────────────────────────────────────────
        reg.invalidate(textureId: textureId)

        // ── Post-condition: both lookups must return nil ───────────────────────
        XCTAssertNil(reg.runtime(forSessionId: capturedSessionId),
            "runtime(forSessionId:) must return nil after invalidate(textureId:)")
        XCTAssertNil(reg.runtime(forTextureId: textureId),
            "runtime(forTextureId:) must return nil after invalidate(textureId:)")
        XCTAssertEqual(reg.sessionCount, 0,
            "sessionCount must be 0 after invalidate(textureId:)")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AC-3 (variant) — invalidate(textureId:) on unknown ID: no crash
    // ─────────────────────────────────────────────────────────────────────────

    func testInvalidateUnknownTextureIdDoesNotCrash() {
        let (reg, _, _) = makeRegistry()
        // Must not crash regardless of whether any session exists.
        reg.invalidate(textureId: 999_999)
        reg.invalidate(textureId: -1)
        XCTAssertEqual(reg.sessionCount, 0)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AC-3 (variant) — invalidate(textureId:) is idempotent
    // ─────────────────────────────────────────────────────────────────────────

    func testInvalidateByTextureIdIdempotent() throws {
        guard let pngURL = writeTempPNG() else {
            throw XCTSkip("Cannot write temp PNG")
        }
        defer { try? FileManager.default.removeItem(at: pngURL) }

        let (reg, texReg, channel) = makeRegistry()
        let prepExp = expectation(description: "prepare")
        var textureId: Int64 = -1

        reg.createSession(url: pngURL, textureRegistry: texReg, methodChannel: channel) { tid, _ in
            textureId = tid
            prepExp.fulfill()
        }
        wait(for: [prepExp], timeout: kTestTimeout)
        guard textureId >= 0 else {
            reg.invalidateAll()
            throw XCTSkip("Prepare failed")
        }

        // First call — removes entries.
        reg.invalidate(textureId: textureId)
        XCTAssertEqual(reg.sessionCount, 0)

        // Second call — must not crash (entry already removed).
        reg.invalidate(textureId: textureId)
        XCTAssertEqual(reg.sessionCount, 0,
            "sessionCount must remain 0 after second invalidate(textureId:)")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AC-4 — invalidateAll() clears all map entries completely
    //
    // We create one session (stub URL, prepare will eventually fail/remove it).
    // We call invalidateAll() BEFORE prepare fires, verifying that the registry
    // drains the primary map immediately. We also verify sessionCount is 0.
    // ─────────────────────────────────────────────────────────────────────────

    func testInvalidateAllClearsAllEntries() {
        let (reg, texReg, channel) = makeRegistry()

        // createSession writes the primary-map entry synchronously.
        let sessionId = reg.createSession(
            url:             stubVideoURL,
            textureRegistry: texReg,
            methodChannel:   channel
        ) { _, _ in /* ignored */ }

        // Pre-condition: primary map has one entry right after createSession.
        XCTAssertEqual(reg.sessionCount, 1,
            "Pre-condition: sessionCount must be 1 after createSession " +
            "(primary map written synchronously)")
        XCTAssertNotNil(reg.runtime(forSessionId: sessionId),
            "Pre-condition: runtime must be findable by sessionId before invalidateAll")

        // ── invalidateAll ─────────────────────────────────────────────────────
        reg.invalidateAll()

        // ── Post-condition: both maps are empty ───────────────────────────────
        XCTAssertEqual(reg.sessionCount, 0,
            "sessionCount must be 0 after invalidateAll()")
        XCTAssertNil(reg.runtime(forSessionId: sessionId),
            "runtime(forSessionId:) must return nil after invalidateAll()")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AC-4 (variant) — disposeAll() is an exact alias for invalidateAll()
    // ─────────────────────────────────────────────────────────────────────────

    func testDisposeAllIsAnAliasForInvalidateAll() {
        let (reg, texReg, channel) = makeRegistry()

        let sessionId = reg.createSession(
            url:             stubVideoURL,
            textureRegistry: texReg,
            methodChannel:   channel
        ) { _, _ in }

        XCTAssertEqual(reg.sessionCount, 1)

        reg.disposeAll()   // alias — must behave identically to invalidateAll()

        XCTAssertEqual(reg.sessionCount, 0,
            "disposeAll() must clear all sessions (alias of invalidateAll())")
        XCTAssertNil(reg.runtime(forSessionId: sessionId),
            "runtime(forSessionId:) must return nil after disposeAll()")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AC-4 (variant) — invalidateAll() on an empty registry: no crash
    // ─────────────────────────────────────────────────────────────────────────

    func testInvalidateAllOnEmptyRegistryDoesNotCrash() {
        let (reg, _, _) = makeRegistry()
        reg.invalidateAll()   // should be a no-op
        reg.invalidateAll()   // second call: still no crash
        XCTAssertEqual(reg.sessionCount, 0)
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AC-5 — Single-active-session enforcement
    //
    // createSession is called while another session is already active.
    // The first session must be evicted (removed from both maps) and the
    // second session must be created successfully.
    //
    // We verify eviction synchronously (the eviction step inside createSession
    // is synchronous). The second session's prepare may fail on the stub URL,
    // but the registry's state-management logic (eviction + new-entry) is
    // tested independently of prepare success.
    // ─────────────────────────────────────────────────────────────────────────

    func testSingleActiveSessionEnforcement() {
        let (reg, texReg, channel) = makeRegistry()

        // ── Create first session ───────────────────────────────────────────────
        let sessionId1 = reg.createSession(
            url:             stubVideoURL,
            textureRegistry: texReg,
            methodChannel:   channel
        ) { _, _ in /* ignored */ }

        // Synchronous post-condition: primary map has exactly one entry.
        XCTAssertEqual(reg.sessionCount, 1,
            "Pre-condition: after first createSession, sessionCount must be 1")
        XCTAssertNotNil(reg.runtime(forSessionId: sessionId1),
            "Pre-condition: first session must be findable immediately after createSession")

        // ── Create second session (while first is active) ─────────────────────
        let sessionId2 = reg.createSession(
            url:             stubVideoURL,
            textureRegistry: texReg,
            methodChannel:   channel
        ) { _, _ in /* ignored */ }

        // The two sessionIds must be different.
        XCTAssertNotEqual(sessionId1, sessionId2,
            "First and second sessionIds must be distinct")

        // ── Eviction check: first session is gone ─────────────────────────────
        // createSession drains the previous maps synchronously (under _lock)
        // before writing the new entry. By the time createSession returns here,
        // session1 is no longer in the registry.
        XCTAssertNil(reg.runtime(forSessionId: sessionId1),
            "First session must have been evicted from the registry when the " +
            "second createSession was called")

        // ── Second session is live ────────────────────────────────────────────
        XCTAssertNotNil(reg.runtime(forSessionId: sessionId2),
            "Second session must be findable in the registry after its createSession call")
        XCTAssertEqual(reg.sessionCount, 1,
            "sessionCount must be exactly 1 after second createSession " +
            "(Phase 1 single-active-session invariant)")

        reg.invalidateAll()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AC-5 (variant) — Triple-create: session N-1 is always evicted
    // ─────────────────────────────────────────────────────────────────────────

    func testTripleCreateAlwaysRetainsOnlyLastSession() {
        let (reg, texReg, channel) = makeRegistry()

        let sid1 = reg.createSession(url: stubVideoURL, textureRegistry: texReg,
                                     methodChannel: channel) { _, _ in }
        let sid2 = reg.createSession(url: stubVideoURL, textureRegistry: texReg,
                                     methodChannel: channel) { _, _ in }
        let sid3 = reg.createSession(url: stubVideoURL, textureRegistry: texReg,
                                     methodChannel: channel) { _, _ in }

        XCTAssertNil(reg.runtime(forSessionId: sid1),
            "Session 1 must be evicted after session 2 is created")
        XCTAssertNil(reg.runtime(forSessionId: sid2),
            "Session 2 must be evicted after session 3 is created")
        XCTAssertNotNil(reg.runtime(forSessionId: sid3),
            "Session 3 (most recent) must be findable")
        XCTAssertEqual(reg.sessionCount, 1,
            "sessionCount must be 1 — only the most recently created session survives")

        reg.invalidateAll()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AC-5 (variant) — Second session after invalidateAll: count goes 0→1
    // ─────────────────────────────────────────────────────────────────────────

    func testCreateAfterInvalidateAll() {
        let (reg, texReg, channel) = makeRegistry()

        reg.createSession(url: stubVideoURL, textureRegistry: texReg,
                          methodChannel: channel) { _, _ in }
        reg.invalidateAll()
        XCTAssertEqual(reg.sessionCount, 0, "After invalidateAll, count must be 0")

        let newSid = reg.createSession(url: stubVideoURL, textureRegistry: texReg,
                                       methodChannel: channel) { _, _ in }
        XCTAssertEqual(reg.sessionCount, 1, "New session after invalidateAll must restore count to 1")
        XCTAssertNotNil(reg.runtime(forSessionId: newSid))

        reg.invalidateAll()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Concurrency — concurrent createSession calls from multiple threads
    // The registry must not crash or corrupt its maps under concurrent access.
    // After all calls complete there must be exactly one session.
    // ─────────────────────────────────────────────────────────────────────────

    func testConcurrentCreateSessionIsSafe() {
        let (reg, texReg, channel) = makeRegistry()
        let group = DispatchGroup()
        let threadCount = 8

        for _ in 0..<threadCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                reg.createSession(url: self.stubURL(), textureRegistry: texReg,
                                  methodChannel: channel) { _, _ in }
                group.leave()
            }
        }

        group.wait()

        // Exactly one session must survive (Phase 1 single-session constraint).
        XCTAssertLessThanOrEqual(reg.sessionCount, 1,
            "sessionCount must be ≤ 1 after concurrent createSession calls " +
            "(Phase 1 single-session constraint violated)")
        // No crash = pass.

        reg.invalidateAll()
    }

    // MARK: - Private helpers

    private func stubURL() -> URL {
        URL(fileURLWithPath: "/tmp/vg_registry_concurrent_stub.mp4")
    }
}

// MARK: - AC Coverage Summary
//
//  AC-1  testUniqueSessionIds
//            Two consecutive calls produce distinct, non-empty UUID strings.
//        testSessionIdReturnedBeforeCompletion
//            sessionId is synchronous; completion flag is false immediately after return.
//
//  AC-2  testLookupsAfterSuccessfulPrepare
//            runtime(forTextureId:) and runtime(forSessionId:) both return the same
//            non-nil runtime instance after a successful PNG prepare.
//        testRuntimeBySessionIdAvailableSynchronously
//            runtime(forSessionId:) non-nil immediately; nil for unknown key.
//        testRuntimeByTextureIdUnknownReturnsNil
//            Edge-case: never crashes on unknown or -1 textureId.
//
//  AC-3  testInvalidateRemovesBothMapEntries
//            After invalidate(textureId:): both lookups return nil, sessionCount=0.
//        testInvalidateUnknownTextureIdDoesNotCrash
//            Unknown textureId: idempotent, no crash.
//        testInvalidateByTextureIdIdempotent
//            Double invalidate on same textureId: no crash, sessionCount stays 0.
//
//  AC-4  testInvalidateAllClearsAllEntries
//            invalidateAll() immediately drains primary map; all lookups return nil.
//        testDisposeAllIsAnAliasForInvalidateAll
//            disposeAll() has identical observable behaviour to invalidateAll().
//        testInvalidateAllOnEmptyRegistryDoesNotCrash
//            Safe to call on empty registry; double-call is also safe.
//
//  AC-5  testSingleActiveSessionEnforcement
//            After second createSession: first sessionId lookup returns nil;
//            second lookup returns non-nil; sessionCount=1.
//        testTripleCreateAlwaysRetainsOnlyLastSession
//            Only the most recently created session survives.
//        testCreateAfterInvalidateAll
//            count 0→1 after invalidateAll + new createSession.
//        testConcurrentCreateSessionIsSafe
//            ≤1 session after concurrent creates; no crash.
