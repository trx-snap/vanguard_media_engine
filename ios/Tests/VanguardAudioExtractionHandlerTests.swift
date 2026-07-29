// VanguardAudioExtractionHandlerTests.swift
// vanguard_media_engine — Phase 10-C Slice T Gate 6A
//
// Unit tests for VanguardAudioExtractionHandler.

import XCTest
import Flutter
import AVFoundation
@testable import vanguard_media_engine

private struct FakeFlutterError {
    let code: String
    let message: String?
    let details: Any?
}

private let testFlutterErrorFactory: VGAEFlutterErrorFactory = { code, message, details in
    FakeFlutterError(code: code, message: message, details: details)
}

private final class FakeExporter: _VGAudioExporterProtocol {
    private let lock = NSLock()
    private var _isFinished: Bool = false
    private var _cancelCount: Int = 0
    private var _completionBlock: ((VGAudioExportManifest?, Error?) -> Void)?
    private let startExpectation: XCTestExpectation?

    init(startExpectation: XCTestExpectation? = nil) {
        self.startExpectation = startExpectation
    }

    var isFinished: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return _isFinished
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _isFinished = newValue
        }
    }

    var cancelCount: Int {
        get {
            lock.lock(); defer { lock.unlock() }
            return _cancelCount
        }
    }

    var completionBlock: ((VGAudioExportManifest?, Error?) -> Void)? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _completionBlock
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _completionBlock = newValue
        }
    }

    func startWithCompletion(_ completion: @escaping (VGAudioExportManifest?, Error?) -> Void) {
        lock.lock()
        _completionBlock = completion
        lock.unlock()
        startExpectation?.fulfill()
    }

    func cancel() {
        lock.lock()
        _cancelCount += 1
        lock.unlock()
    }
}

private final class TestExporterFactory {
    private let lock = NSLock()
    private var _explicitExporter: FakeExporter?
    private var _createdExporters: [FakeExporter] = []
    private var _lastAsset: AVAsset?
    private var _lastProfile: VGAudioExportProfile?
    private var _lastOutputURL: URL?
    private var _lastTrimRange: CMTimeRange?

    var explicitExporter: FakeExporter? {
        get { lock.lock(); defer { lock.unlock() } ; return _explicitExporter }
        set { lock.lock(); defer { lock.unlock() } ; _explicitExporter = newValue }
    }

    var createdExporters: [FakeExporter] {
        lock.lock(); defer { lock.unlock() }
        return _createdExporters
    }

    var lastAsset: AVAsset? {
        lock.lock(); defer { lock.unlock() }
        return _lastAsset
    }

    var lastProfile: VGAudioExportProfile? {
        lock.lock(); defer { lock.unlock() }
        return _lastProfile
    }

    var lastOutputURL: URL? {
        lock.lock(); defer { lock.unlock() }
        return _lastOutputURL
    }

    var lastTrimRange: CMTimeRange? {
        lock.lock(); defer { lock.unlock() }
        return _lastTrimRange
    }

    func make(asset: AVAsset, profile: VGAudioExportProfile, url: URL, range: CMTimeRange?) -> any _VGAudioExporterProtocol {
        lock.lock()
        _lastAsset = asset
        _lastProfile = profile
        _lastOutputURL = url
        _lastTrimRange = range

        let exporter = _explicitExporter ?? FakeExporter()
        _createdExporters.append(exporter)
        lock.unlock()

        return exporter
    }
}

private final class ResultCaptor {
    var value: Any?
    var expectation: XCTestExpectation
    var invokedOnMainThread = false

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func result() -> FlutterResult {
        return { [weak self] val in
            self?.value = val
            self?.invokedOnMainThread = Thread.isMainThread
            self?.expectation.fulfill()
        }
    }
}

final class VanguardAudioExtractionHandlerTests: XCTestCase {

    private var testFactory: TestExporterFactory!
    private var handler: VanguardAudioExtractionHandler!

    override func setUp() {
        super.setUp()
        testFactory = TestExporterFactory()

        let factory = _VGAudioExporterFactory { [unowned self] asset, profile, url, range in
            return self.testFactory.make(asset: asset, profile: profile, url: url, range: range)
        }

        handler = VanguardAudioExtractionHandler(
            exporterFactory: factory,
            flutterErrorFactory: testFlutterErrorFactory
        )
    }

    override func tearDown() {
        handler = nil
        testFactory = nil
        super.tearDown()
    }

    // MARK: - Test Cases

    // 1. Missing/empty operationId, sourcePath and outputPath
    // Also covers missing sourcePath with a valid operationId,
    // and missing outputPath with valid operationId and sourcePath.
    func testBeginWithMissingOrEmptyArgumentsReturnsInvalidArgument() {
        let testCases: [[String: Any]?] = [
            nil,
            [:],
            ["operationId": "", "sourcePath": "/src", "outputPath": "/out"],
            ["operationId": "id1", "sourcePath": "", "outputPath": "/out"],
            ["operationId": "id1", "sourcePath": "/src", "outputPath": ""],
            // missing sourcePath with valid operationId
            ["operationId": "id1", "outputPath": "/out"],
            // missing outputPath with valid operationId and sourcePath
            ["operationId": "id1", "sourcePath": "/src"]
        ]

        for (idx, args) in testCases.enumerated() {
            let exp = expectation(description: "begin_invalid_args_\(idx)")
            let captor = ResultCaptor(expectation: exp)
            handler.handleBegin(args: args, result: captor.result())
            waitForExpectations(timeout: 1.0, handler: nil)

            XCTAssertNotNil(captor.value)
            let err = captor.value as? FakeFlutterError
            XCTAssertEqual(err?.code, "invalidArgument", "Case \(idx) failed to return invalidArgument")
        }
    }

    // 2. NaN/infinite/negative trim start
    func testBeginWithInvalidTrimStartReturnsInvalidArgument() {
        let invalidStarts = [Double.nan, Double.infinity, -1.0]

        for (idx, start) in invalidStarts.enumerated() {
            let exp = expectation(description: "begin_invalid_start_\(idx)")
            let captor = ResultCaptor(expectation: exp)
            let args: [String: Any] = [
                "operationId": "id1",
                "sourcePath": "/src",
                "outputPath": "/out",
                "trimStartSeconds": start
            ]

            handler.handleBegin(args: args, result: captor.result())
            waitForExpectations(timeout: 1.0, handler: nil)

            XCTAssertNotNil(captor.value)
            let err = captor.value as? FakeFlutterError
            XCTAssertEqual(err?.code, "invalidArgument", "Case \(idx) with start \(start) failed")
        }
    }

    // 3. NaN/infinite/non-positive trim end
    func testBeginWithInvalidTrimEndReturnsInvalidArgument() {
        let invalidEnds = [Double.nan, Double.infinity, 0.0, -2.5]

        for (idx, end) in invalidEnds.enumerated() {
            let exp = expectation(description: "begin_invalid_end_\(idx)")
            let captor = ResultCaptor(expectation: exp)
            let args: [String: Any] = [
                "operationId": "id1",
                "sourcePath": "/src",
                "outputPath": "/out",
                "trimEndSeconds": end
            ]

            handler.handleBegin(args: args, result: captor.result())
            waitForExpectations(timeout: 1.0, handler: nil)

            XCTAssertNotNil(captor.value)
            let err = captor.value as? FakeFlutterError
            XCTAssertEqual(err?.code, "invalidArgument", "Case \(idx) with end \(end) failed")
        }
    }

    // 4. end <= start
    func testBeginWithTrimEndLessThanOrEqualToStartReturnsInvalidArgument() {
        let testCases = [
            (start: 3.0, end: 2.0),
            (start: 3.0, end: 3.0)
        ]

        for (idx, tc) in testCases.enumerated() {
            let exp = expectation(description: "begin_end_le_start_\(idx)")
            let captor = ResultCaptor(expectation: exp)
            let args: [String: Any] = [
                "operationId": "id1",
                "sourcePath": "/src",
                "outputPath": "/out",
                "trimStartSeconds": tc.start,
                "trimEndSeconds": tc.end
            ]

            handler.handleBegin(args: args, result: captor.result())
            waitForExpectations(timeout: 1.0, handler: nil)

            XCTAssertNotNil(captor.value)
            let err = captor.value as? FakeFlutterError
            XCTAssertEqual(err?.code, "invalidArgument")
        }
    }

    // 5. Captured factory ranges
    func testTrimBoundsMapToCorrectCMTimeRanges() {
        struct Case {
            let start: Double?
            let end: Double?
            let verify: (CMTimeRange?) -> Void
        }

        let cases = [
            // - no bounds -> nil
            Case(start: nil, end: nil, verify: { range in
                XCTAssertNil(range)
            }),
            // - end-only -> [0, end)
            Case(start: nil, end: 5.0, verify: { range in
                XCTAssertNotNil(range)
                XCTAssertEqual(range?.start.seconds, 0.0)
                XCTAssertEqual(range?.duration.seconds, 5.0)
            }),
            // - start-only -> [start, positiveInfinity)
            Case(start: 3.0, end: nil, verify: { range in
                XCTAssertNotNil(range)
                XCTAssertEqual(range?.start.seconds, 3.0)
                XCTAssertTrue(range!.duration.isPositiveInfinity)
            }),
            // - both -> [start, end)
            Case(start: 2.0, end: 6.0, verify: { range in
                XCTAssertNotNil(range)
                XCTAssertEqual(range?.start.seconds, 2.0)
                XCTAssertEqual(range?.duration.seconds, 4.0) // 6.0 - 2.0
            })
        ]

        for (idx, tc) in cases.enumerated() {
            var args: [String: Any] = [
                "operationId": "id_\(idx)",
                "sourcePath": "/src",
                "outputPath": "/out"
            ]
            if let s = tc.start { args["trimStartSeconds"] = s }
            if let e = tc.end { args["trimEndSeconds"] = e }

            let exp = expectation(description: "factory_range_\(idx)")
            let captor = ResultCaptor(expectation: exp)

            let startExp = expectation(description: "exporter_started_\(idx)")
            let exporter = FakeExporter(startExpectation: startExp)
            testFactory.explicitExporter = exporter

            handler.handleBegin(args: args, result: captor.result())
            wait(for: [startExp], timeout: 1.0)

            tc.verify(testFactory.lastTrimRange)

            // Terminate begun operation before exiting test case
            exporter.completionBlock?(nil, nil)
            wait(for: [exp], timeout: 1.0)
        }
    }

    // 6. Duplicate active operationId
    func testDuplicateOperationIdReturnsOperationAlreadyExists() {
        let makeExp = expectation(description: "first_make")
        let firstExporter = FakeExporter(startExpectation: makeExp)
        testFactory.explicitExporter = firstExporter

        let exp1 = expectation(description: "begin_first")
        let captor1 = ResultCaptor(expectation: exp1)

        handler.handleBegin(
            args: ["operationId": "dupId", "sourcePath": "/src", "outputPath": "/out"],
            result: captor1.result()
        )
        wait(for: [makeExp], timeout: 1.0)

        // Start duplicate operation
        let exp2 = expectation(description: "begin_second")
        let captor2 = ResultCaptor(expectation: exp2)
        handler.handleBegin(
            args: ["operationId": "dupId", "sourcePath": "/src", "outputPath": "/out"],
            result: captor2.result()
        )
        wait(for: [exp2], timeout: 1.0)

        XCTAssertNotNil(captor2.value)
        let err = captor2.value as? FakeFlutterError
        XCTAssertEqual(err?.code, "operationAlreadyExists")

        // First is still active; resolve it to terminate
        firstExporter.completionBlock?(nil, nil)
        wait(for: [exp1], timeout: 1.0)
    }

    // 7. Success returns the requested outputPath
    func testSuccessReturnsOutputPathOnMainThread() {
        let startExp = expectation(description: "exporter_started")
        let exporter = FakeExporter(startExpectation: startExp)
        testFactory.explicitExporter = exporter

        let exp = expectation(description: "begin_success")
        let captor = ResultCaptor(expectation: exp)

        handler.handleBegin(
            args: ["operationId": "okId", "sourcePath": "/src", "outputPath": "/out/path.m4a"],
            result: captor.result()
        )
        wait(for: [startExp], timeout: 1.0)

        let manifest = VGAudioExportManifest(
            codec: .AAC,
            sampleRate: 44100,
            channels: 2,
            bitrate: 128000,
            durationSeconds: 5.5,
            fileSizeBytes: 200000,
            containerFormat: "m4a"
        )

        exporter.completionBlock?(manifest, nil)
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(captor.invokedOnMainThread)
        XCTAssertNotNil(captor.value)
        let dict = captor.value as? [String: Any]
        XCTAssertEqual(dict?["outputPath"] as? String, "/out/path.m4a")
    }

    // 8. Every public error mapping
    func testErrorMappings() {
        struct ErrorCase {
            let nsCode: VGAudioOnlyExporterErrorCode
            let expectedDartCode: String
        }

        let mappings = [
            ErrorCase(nsCode: .invalidSource, expectedDartCode: "invalidArgument"),
            ErrorCase(nsCode: .invalidOutputURL, expectedDartCode: "invalidArgument"),
            ErrorCase(nsCode: .invalidProfile, expectedDartCode: "invalidArgument"),
            ErrorCase(nsCode: .unsupportedCodec, expectedDartCode: "invalidArgument"),
            ErrorCase(nsCode: .unsupportedFormat, expectedDartCode: "invalidArgument"),
            ErrorCase(nsCode: .noAudioTrack, expectedDartCode: "noAudioTrack"),
            ErrorCase(nsCode: .readerSetup, expectedDartCode: "readFailure"),
            ErrorCase(nsCode: .readerStart, expectedDartCode: "readFailure"),
            ErrorCase(nsCode: .readerRuntimeFailure, expectedDartCode: "readFailure"),
            ErrorCase(nsCode: .writerSetup, expectedDartCode: "writeFailure"),
            ErrorCase(nsCode: .writerStart, expectedDartCode: "writeFailure"),
            ErrorCase(nsCode: .writerFailed, expectedDartCode: "writeFailure"),
            ErrorCase(nsCode: .outputMissing, expectedDartCode: "writeFailure"),
            ErrorCase(nsCode: .cancelled, expectedDartCode: "cancelled")
        ]

        for (idx, tc) in mappings.enumerated() {
            let startExp = expectation(description: "exporter_started_err_\(idx)")
            let exporter = FakeExporter(startExpectation: startExp)
            testFactory.explicitExporter = exporter

            let exp = expectation(description: "error_map_\(idx)")
            let captor = ResultCaptor(expectation: exp)

            handler.handleBegin(
                args: ["operationId": "err_\(idx)", "sourcePath": "/src", "outputPath": "/out"],
                result: captor.result()
            )
            wait(for: [startExp], timeout: 1.0)

            let nsError = NSError(
                domain: VGAudioOnlyExporterErrorDomain,
                code: tc.nsCode.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Test error for \(tc.nsCode)"]
            )

            exporter.completionBlock?(nil, nsError)
            wait(for: [exp], timeout: 1.0)

            XCTAssertNotNil(captor.value)
            let err = captor.value as? FakeFlutterError
            XCTAssertEqual(err?.code, tc.expectedDartCode, "Code \(tc.nsCode) mapped incorrectly")
        }

        // Test unknown domain & unknown code
        let unknownCases = [
            NSError(domain: NSCocoaErrorDomain, code: 4, userInfo: nil),
            NSError(domain: VGAudioOnlyExporterErrorDomain, code: 999, userInfo: nil)
        ]

        for (idx, error) in unknownCases.enumerated() {
            let startExp = expectation(description: "exporter_started_unk_\(idx)")
            let exporter = FakeExporter(startExpectation: startExp)
            testFactory.explicitExporter = exporter

            let exp = expectation(description: "error_unknown_\(idx)")
            let captor = ResultCaptor(expectation: exp)

            handler.handleBegin(
                args: ["operationId": "unknown_\(idx)", "sourcePath": "/src", "outputPath": "/out"],
                result: captor.result()
            )
            wait(for: [startExp], timeout: 1.0)

            exporter.completionBlock?(nil, error)
            wait(for: [exp], timeout: 1.0)

            XCTAssertNotNil(captor.value)
            let err = captor.value as? FakeFlutterError
            XCTAssertEqual(err?.code, "internalFailure")
        }

        // Test exporter completion with both manifest and error nil maps to internalFailure
        let startExp = expectation(description: "exporter_started_nil_nil")
        let exporter = FakeExporter(startExpectation: startExp)
        testFactory.explicitExporter = exporter

        let exp = expectation(description: "error_nil_nil")
        let captor = ResultCaptor(expectation: exp)

        handler.handleBegin(
            args: ["operationId": "nilNilId", "sourcePath": "/src", "outputPath": "/out"],
            result: captor.result()
        )
        wait(for: [startExp], timeout: 1.0)

        exporter.completionBlock?(nil, nil)
        wait(for: [exp], timeout: 1.0)

        XCTAssertNotNil(captor.value)
        let err = captor.value as? FakeFlutterError
        XCTAssertEqual(err?.code, "internalFailure")
    }

    // 9. Multiple cancel waiters remain unresolved until terminal completion, then each receives cancellationCompleted
    func testMultipleCancelWaitersResolveOnExporterCompletion() {
        let startExp = expectation(description: "exporter_started_cancel")
        let exporter = FakeExporter(startExpectation: startExp)
        testFactory.explicitExporter = exporter

        let beginExp = expectation(description: "begin_cancel")
        let beginCaptor = ResultCaptor(expectation: beginExp)

        handler.handleBegin(
            args: ["operationId": "cancelId", "sourcePath": "/src", "outputPath": "/out"],
            result: beginCaptor.result()
        )
        wait(for: [startExp], timeout: 1.0)

        // Queue first cancel waiter
        let cancelExp1 = expectation(description: "cancel_waiter_1")
        let cancelCaptor1 = ResultCaptor(expectation: cancelExp1)
        handler.handleCancel(args: ["operationId": "cancelId"], result: cancelCaptor1.result())

        // Queue second cancel waiter
        let cancelExp2 = expectation(description: "cancel_waiter_2")
        let cancelCaptor2 = ResultCaptor(expectation: cancelExp2)
        handler.handleCancel(args: ["operationId": "cancelId"], result: cancelCaptor2.result())

        // Use a dummy cancel call for an unknown ID as a queue barrier to ensure
        // both cancel requests for "cancelId" have been processed on the stateQueue.
        let barrierExp = expectation(description: "queue_barrier")
        let barrierCaptor = ResultCaptor(expectation: barrierExp)
        handler.handleCancel(args: ["operationId": "unknownBarrierId"], result: barrierCaptor.result())
        wait(for: [barrierExp], timeout: 1.0)

        // Verify that cancel has been called twice and they remain pending
        XCTAssertNil(cancelCaptor1.value)
        XCTAssertNil(cancelCaptor2.value)
        XCTAssertEqual(exporter.cancelCount, 2)

        // Now complete the exporter (e.g. cancelled error)
        let cancelledErr = NSError(
            domain: VGAudioOnlyExporterErrorDomain,
            code: VGAudioOnlyExporterErrorCode.cancelled.rawValue,
            userInfo: nil
        )
        exporter.completionBlock?(nil, cancelledErr)

        wait(for: [beginExp, cancelExp1, cancelExp2], timeout: 1.0)

        // Verify begin got resolved as cancelled
        let beginErr = beginCaptor.value as? FakeFlutterError
        XCTAssertEqual(beginErr?.code, "cancelled")

        // Verify cancel waiters got cancellationCompleted
        XCTAssertTrue(cancelCaptor1.invokedOnMainThread)
        XCTAssertTrue(cancelCaptor2.invokedOnMainThread)
        let result1 = cancelCaptor1.value as? [String: String]
        let result2 = cancelCaptor2.value as? [String: String]
        XCTAssertEqual(result1?["disposition"], "cancellationCompleted")
        XCTAssertEqual(result2?["disposition"], "cancellationCompleted")
    }

    // 10. `isFinished` race returns alreadyTerminal without calling cancel
    func testIsFinishedRaceReturnsAlreadyTerminal() {
        let startExp = expectation(description: "exporter_started_race")
        let exporter = FakeExporter(startExpectation: startExp)
        testFactory.explicitExporter = exporter

        let beginExp = expectation(description: "begin_race")
        let beginCaptor = ResultCaptor(expectation: beginExp)

        handler.handleBegin(
            args: ["operationId": "raceId", "sourcePath": "/src", "outputPath": "/out"],
            result: beginCaptor.result()
        )
        wait(for: [startExp], timeout: 1.0)

        // Simulate exporter finished before handleCancel executes on queue
        exporter.isFinished = true

        let cancelExp = expectation(description: "cancel_race")
        let cancelCaptor = ResultCaptor(expectation: cancelExp)

        handler.handleCancel(args: ["operationId": "raceId"], result: cancelCaptor.result())
        wait(for: [cancelExp], timeout: 1.0)

        XCTAssertTrue(cancelCaptor.invokedOnMainThread)
        let res = cancelCaptor.value as? [String: String]
        XCTAssertEqual(res?["disposition"], "alreadyTerminal")
        XCTAssertEqual(exporter.cancelCount, 0) // should NOT have been cancelled

        // Clean up begin
        exporter.completionBlock?(nil, nil)
        wait(for: [beginExp], timeout: 1.0)
    }

    // 11. Cancel after recorded terminal returns alreadyTerminal
    func testCancelAfterRecordedTerminalReturnsAlreadyTerminal() {
        let startExp = expectation(description: "exporter_started_term")
        let exporter = FakeExporter(startExpectation: startExp)
        testFactory.explicitExporter = exporter

        let beginExp = expectation(description: "begin_terminal")
        let beginCaptor = ResultCaptor(expectation: beginExp)

        handler.handleBegin(
            args: ["operationId": "termId", "sourcePath": "/src", "outputPath": "/out"],
            result: beginCaptor.result()
        )
        wait(for: [startExp], timeout: 1.0)

        // Complete the exporter to record as terminal
        exporter.completionBlock?(nil, nil)
        wait(for: [beginExp], timeout: 1.0)

        // Now call cancel on the terminal operation ID
        let cancelExp = expectation(description: "cancel_term")
        let cancelCaptor = ResultCaptor(expectation: cancelExp)
        handler.handleCancel(args: ["operationId": "termId"], result: cancelCaptor.result())
        wait(for: [cancelExp], timeout: 1.0)

        let res = cancelCaptor.value as? [String: String]
        XCTAssertEqual(res?["disposition"], "alreadyTerminal")
    }

    // 12. Unknown ID returns notFound
    func testCancelWithUnknownIdReturnsNotFound() {
        let cancelExp = expectation(description: "cancel_unknown")
        let cancelCaptor = ResultCaptor(expectation: cancelExp)
        handler.handleCancel(args: ["operationId": "unknownId"], result: cancelCaptor.result())
        wait(for: [cancelExp], timeout: 1.0)

        let res = cancelCaptor.value as? [String: String]
        XCTAssertEqual(res?["disposition"], "notFound")
    }

    // handleCancel missing/empty operationId maps to invalidArgument
    func testCancelWithMissingOrEmptyOperationIdReturnsInvalidArgument() {
        let testCases: [[String: Any]?] = [
            nil,
            [:],
            ["operationId": ""]
        ]
        for (idx, args) in testCases.enumerated() {
            let exp = expectation(description: "cancel_invalid_args_\(idx)")
            let captor = ResultCaptor(expectation: exp)
            handler.handleCancel(args: args, result: captor.result())
            waitForExpectations(timeout: 1.0, handler: nil)

            XCTAssertNotNil(captor.value)
            let err = captor.value as? FakeFlutterError
            XCTAssertEqual(err?.code, "invalidArgument")
        }
    }

    // 13. A fake exporter invoking completion twice resolves begin exactly once
    func testExporterInvokingCompletionTwiceResolvesBeginExactlyOnce() {
        let startExp = expectation(description: "exporter_started_twice")
        let exporter = FakeExporter(startExpectation: startExp)
        testFactory.explicitExporter = exporter

        var beginCallbackCount = 0
        let beginCallback: FlutterResult = { _ in
            beginCallbackCount += 1
        }

        handler.handleBegin(
            args: ["operationId": "twiceId", "sourcePath": "/src", "outputPath": "/out"],
            result: beginCallback
        )
        wait(for: [startExp], timeout: 1.0)

        // Invoke the captured completion block twice
        exporter.completionBlock?(nil, nil)
        exporter.completionBlock?(nil, nil)

        // Call handleCancel for the same operationId as a queue barrier to ensure
        // both completion dispatches have run on the stateQueue.
        let cancelExp = expectation(description: "barrier_twice")
        let cancelCaptor = ResultCaptor(expectation: cancelExp)
        handler.handleCancel(args: ["operationId": "twiceId"], result: cancelCaptor.result())
        wait(for: [cancelExp], timeout: 1.0)

        // Verify we got alreadyTerminal from cancel
        let res = cancelCaptor.value as? [String: String]
        XCTAssertEqual(res?["disposition"], "alreadyTerminal")

        // Assert the begin callback count is exactly 1
        XCTAssertEqual(beginCallbackCount, 1)
    }
}
