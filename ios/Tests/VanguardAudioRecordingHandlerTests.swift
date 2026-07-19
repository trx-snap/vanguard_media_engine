// VanguardAudioRecordingHandlerTests.swift
// Vanguard Media Engine — Audio Slice N
//
// Unit tests for VGAudioRecordingHandler under mock boundaries.

import XCTest
import Flutter
@testable import vanguard_media_engine

#if VG_USE_V2_GRAPH

// MARK: - Fake Seams

private final class FakeSessionBackend: NSObject, VGAudioSessionBackend {
    var onEvent: ((String) -> Void)?
    var category: String = AVAudioSession.Category.playback.rawValue
    var options: AVAudioSession.CategoryOptions = []
    var categoryShouldFail = false
    var activeShouldFail = false
    var rollbackActiveShouldFail = false
    var currentRouteVal = VGRouteSnapshot(inputs: [], outputs: [])
    var availableInputsVal: [VGPortSnapshot] = []

    var setCategoryCount = 0
    var setActiveCount = 0

    func setCategory(_ category: AVAudioSession.Category, with options: AVAudioSession.CategoryOptions) throws {
        onEvent?("setCategory")
        setCategoryCount += 1
        if categoryShouldFail {
            throw NSError(domain: "MockBackend", code: 101)
        }
        self.category = category.rawValue
        self.options = options
    }

    func setActiveYes() throws {
        onEvent?("setActive")
        setActiveCount += 1
        if category == AVAudioSession.Category.playback.rawValue && rollbackActiveShouldFail {
            throw NSError(domain: "MockBackend", code: 103)
        }
        if activeShouldFail {
            throw NSError(domain: "MockBackend", code: 102)
        }
    }

    func currentRoute() -> VGRouteSnapshot {
        onEvent?("currentRoute")
        return currentRouteVal
    }

    func availableInputs() -> [VGPortSnapshot] {
        onEvent?("availableInputs")
        return availableInputsVal
    }
}

private final class FakeRuntimeHandle: NSObject, VGRuntimeHandle {}

private final class FakeRecorderControl: VGRecorderControl {
    var onEvent: ((String) -> Void)?
    var isRecording = false
    var startRecordingShouldFail = false
    var startInfo = VGAudioRecordingStartInfo(filePath: "/tmp/mock.m4a", startPTS: 1.0)
    var stopInfo = VGAudioRecordingStopInfo(filePath: "/tmp/mock.m4a", startPTS: 1.0, durationSeconds: 2.0)
    var stopRecordingShouldFail = false
    var cancelCount = 0

    func startRecording(handle: VGRuntimeHandle, outputPath: String) throws -> VGAudioRecordingStartInfo {
        onEvent?("recorderStart")
        if startRecordingShouldFail {
            throw NSError(domain: "MockRecorder", code: 201)
        }
        isRecording = true
        return startInfo
    }

    func stopRecording(completion: @escaping (VGAudioRecordingStopInfo?, Error?) -> Void) {
        if stopRecordingShouldFail {
            completion(nil, NSError(domain: "MockRecorder", code: 202))
        } else {
            isRecording = false
            completion(stopInfo, nil)
        }
    }

    func cancelRecording() {
        isRecording = false
        cancelCount += 1
    }
}

private final class FakeRecorderFactory: VGRecorderFactory {
    let stubbedRecorder = FakeRecorderControl()
    func makeRecorder() -> VGRecorderControl {
        return stubbedRecorder
    }
}

// MARK: - Test error shim

/// Lightweight stand-in for FlutterError, used when Flutter.framework is not
/// loaded into the XCTest AppHost process. The VGFlutterErrorFactory injected
/// into VGAudioRecordingHandler during tests returns this type; test assertions
/// call errorCode(_:) which handles both FakeFlutterError and the real
/// FlutterError transparently.
private final class FakeFlutterError {
    let code: String
    let message: String?
    let details: Any?

    init(code: String, message: String?, details: Any?) {
        self.code    = code
        self.message = message
        self.details = details
    }
}

// MARK: - Test Case

final class VanguardAudioRecordingHandlerTests: XCTestCase {

    private var backend: FakeSessionBackend!
    private var coordinator: VGAudioSessionTransitionCoordinator!
    private var factory: FakeRecorderFactory!
    private var handler: VGAudioRecordingHandler!
    private var handle: FakeRuntimeHandle!
    private var recoveryErr: Error?
    private var recoveryCount = 0
    private var lastRecoveryHandle: VGRuntimeHandle?
    private var recoveryBlock: ((VGRuntimeHandle, @escaping (Error?) -> Void) -> Void)?

    override func setUp() {
        super.setUp()
        backend = FakeSessionBackend()
        coordinator = VGAudioSessionTransitionCoordinator(sessionBackend: backend)
        factory = FakeRecorderFactory()
        handle = FakeRuntimeHandle()
        recoveryErr = nil
        recoveryCount = 0
        lastRecoveryHandle = nil
        recoveryBlock = nil

        let recovery: VGPreviewRecovery = { [weak self] h, completion in
            self?.recoveryCount += 1
            self?.lastRecoveryHandle = h
            if let customBlock = self?.recoveryBlock {
                customBlock(h, completion)
            } else {
                completion(self?.recoveryErr)
            }
        }

        handler = VGAudioRecordingHandler(coordinator: coordinator,
                                          recorderFactory: factory,
                                          previewRecovery: recovery,
                                          flutterErrorFactory: testFlutterErrorFactory)
    }

    // MARK: - Test error helpers

    /// Returns a FakeFlutterError. Injected into VGAudioRecordingHandler so that
    /// error construction does not require Flutter.framework to be loaded in the
    /// XCTest AppHost process.
    private func testFlutterErrorFactory(code: String, message: String?, details: Any?) -> Any {
        FakeFlutterError(code: code, message: message, details: details)
    }

    /// Extracts the error code from a FlutterResult value regardless of whether
    /// it is a FakeFlutterError (under XCTest without Flutter.framework) or a
    /// real FlutterError (in a host that has Flutter loaded).
    private func errorCode(_ value: Any?) -> String? {
        if let err = value as? FakeFlutterError { return err.code }
        if let err = value as? FlutterError     { return err.code }
        return nil
    }

    // MARK: - State Guards (Req 4)

    func testStateGuardStartingRejectsStart() {
        var recoveryCompletion: ((Error?) -> Void)? = nil
        recoveryBlock = { h, completion in
            recoveryCompletion = completion
        }

        // Setup inputs
        backend.availableInputsVal = [VGPortSnapshot(portType: AVAudioSession.Port.builtInMic.rawValue, portName: "mic", uid: "1", selectedDataSourceName: nil)]
        backend.currentRouteVal = VGRouteSnapshot(inputs: backend.availableInputsVal, outputs: [])

        let firstStartExp = expectation(description: "first start completion")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { res in
            firstStartExp.fulfill()
        }

        // At this point, recovery is blocked, so state is .starting.
        var secondResult: Any? = nil
        handler.handleStart(args: ["outputPath": "/tmp/b.m4a"], handle: handle) { res in
            secondResult = res
        }

        XCTAssertEqual(errorCode(secondResult), "START_IN_PROGRESS",
                       "Second start should have failed synchronously with START_IN_PROGRESS, but got: \(String(describing: secondResult))")

        // Unblock first start and wait for it to complete
        recoveryCompletion?(nil)
        waitForExpectations(timeout: 1.0)
    }

    func testStateGuardRecordingRejectsStart() {
        // Setup inputs
        backend.availableInputsVal = [VGPortSnapshot(portType: AVAudioSession.Port.builtInMic.rawValue, portName: "mic", uid: "1", selectedDataSourceName: nil)]
        backend.currentRouteVal = VGRouteSnapshot(inputs: backend.availableInputsVal, outputs: [])

        let exp = expectation(description: "start success")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { res in
            XCTAssertTrue(res is [String: Any])
            if let dict = res as? [String: Any],
               let audioRoute = dict["audioRoute"] as? [String: Any] {
                XCTAssertNotNil(audioRoute["inputAvailable"])
                XCTAssertNotNil(audioRoute["activeInputType"])
                XCTAssertNotNil(audioRoute["activeInputName"])
                XCTAssertNotNil(audioRoute["activeInputUID"])
                XCTAssertTrue(audioRoute.keys.contains("activeInputDataSourceName"))
                XCTAssertNotNil(audioRoute["availableInputTypes"])
                XCTAssertNotNil(audioRoute["activeOutputTypes"])
                XCTAssertNotNil(audioRoute["hasHeadphoneOutput"])
                XCTAssertNotNil(audioRoute["activeInputIsExternal"])
            } else {
                XCTFail("Response is not a dictionary or does not contain audioRoute")
            }
            exp.fulfill()
        }

        waitForExpectations(timeout: 1.0)

        // Now state is .recording.
        let rejectExp = expectation(description: "second start reject")
        handler.handleStart(args: ["outputPath": "/tmp/b.m4a"], handle: handle) { res in
            XCTAssertEqual(self.errorCode(res), "ALREADY_RECORDING",
                           "Should have failed with ALREADY_RECORDING")
            rejectExp.fulfill()
        }
        waitForExpectations(timeout: 1.0)
    }

    func testStateGuardStoppingRejectsStartAndStop() {
        // Drive into recording first
        backend.availableInputsVal = [VGPortSnapshot(portType: AVAudioSession.Port.builtInMic.rawValue, portName: "mic", uid: "1", selectedDataSourceName: nil)]
        backend.currentRouteVal = VGRouteSnapshot(inputs: backend.availableInputsVal, outputs: [])

        let startExp = expectation(description: "start success")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { _ in startExp.fulfill() }
        waitForExpectations(timeout: 1.0)

        // Mock a stop that blocks in recovery
        var recoveryCompletion: ((Error?) -> Void)? = nil
        recoveryBlock = { h, completion in
            recoveryCompletion = completion
        }

        let stopExp = expectation(description: "stop completion")
        handler.handleStop(handle: handle) { res in
            stopExp.fulfill()
        }

        // Now state is .stopping. Let's start and stop synchronously to see errors.
        var secondStartResult: Any? = nil
        handler.handleStart(args: ["outputPath": "/tmp/b.m4a"], handle: handle) { res in
            secondStartResult = res
        }
        XCTAssertEqual(errorCode(secondStartResult), "STOP_IN_PROGRESS")

        var secondStopResult: Any? = nil
        handler.handleStop(handle: handle) { res in
            secondStopResult = res
        }
        XCTAssertEqual(errorCode(secondStopResult), "STOP_IN_PROGRESS")

        // Unblock recovery and wait for stop to complete
        recoveryCompletion?(nil)
        waitForExpectations(timeout: 1.0)
    }

    // MARK: - Start Sequences & Cleanup

    func testNoInputCleanupAndError() {
        // inputs is empty
        backend.availableInputsVal = []
        backend.currentRouteVal = VGRouteSnapshot(inputs: [], outputs: [])

        let exp = expectation(description: "no input fail")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { res in
            XCTAssertEqual(self.errorCode(res), "NO_INPUT_AVAILABLE",
                           "Should have failed with NO_INPUT_AVAILABLE")
            exp.fulfill()
        }

        waitForExpectations(timeout: 1.0)
        // Cleanup was triggered, which restores Playback (category Playback)
        XCTAssertEqual(backend.category, AVAudioSession.Category.playback.rawValue)
    }

    func testRecoveryFailureNeverStartsRecorder() {
        backend.availableInputsVal = [VGPortSnapshot(portType: AVAudioSession.Port.builtInMic.rawValue, portName: "mic", uid: "1", selectedDataSourceName: nil)]
        backend.currentRouteVal = VGRouteSnapshot(inputs: backend.availableInputsVal, outputs: [])
        recoveryErr = NSError(domain: "MockRecovery", code: 301)

        let exp = expectation(description: "recovery fail")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { res in
            XCTAssertEqual(self.errorCode(res), "ENGINE_RECOVERY_FAILED",
                           "Should have failed with ENGINE_RECOVERY_FAILED")
            exp.fulfill()
        }

        waitForExpectations(timeout: 1.0)
        XCTAssertFalse(factory.stubbedRecorder.isRecording)
    }

    // MARK: - Blocked Normalization

    func testBlockedNormalizationSuccess() {
        // Put coordinator into unknown state (switchToPlayAndRecord fails, rollback fails)
        backend.activeShouldFail = true
        backend.rollbackActiveShouldFail = true

        let startFailExp = expectation(description: "start fails coordinator unknown")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { _ in startFailExp.fulfill() }
        waitForExpectations(timeout: 1.0)

        // Handler should be in .blocked state. Let's make normalization succeed.
        backend.activeShouldFail = false
        backend.rollbackActiveShouldFail = false
        // Make route valid for the subsequent start
        backend.availableInputsVal = [VGPortSnapshot(portType: AVAudioSession.Port.builtInMic.rawValue, portName: "mic", uid: "1", selectedDataSourceName: nil)]
        backend.currentRouteVal = VGRouteSnapshot(inputs: backend.availableInputsVal, outputs: [])

        let successExp = expectation(description: "start normalization success")
        handler.handleStart(args: ["outputPath": "/tmp/b.m4a"], handle: handle) { res in
            XCTAssertTrue(res is [String: Any])
            successExp.fulfill()
        }
        waitForExpectations(timeout: 1.0)
    }

    func testBlockedNormalizationFailure() {
        // Drive into blocked state
        backend.activeShouldFail = true
        backend.rollbackActiveShouldFail = true
        let startFailExp = expectation(description: "start fails coordinator unknown")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { _ in startFailExp.fulfill() }
        waitForExpectations(timeout: 1.0)

        // Normalization should fail again
        backend.categoryShouldFail = true

        let failExp = expectation(description: "start fails from blocked")
        handler.handleStart(args: ["outputPath": "/tmp/b.m4a"], handle: handle) { res in
            XCTAssertEqual(self.errorCode(res), "SESSION_STATE_UNKNOWN")
            failExp.fulfill()
        }
        waitForExpectations(timeout: 1.0)
    }

    // MARK: - Stop States & Metadata

    func testFailedUnknownRestoredSuccessfullyFinishesIdle() {
        // Switch to PlayAndRecord fails with FailedUnknown, but restorePlayback succeeds.
        backend.activeShouldFail = true
        backend.rollbackActiveShouldFail = false // restore/rollback succeeds!

        let exp = expectation(description: "failed unknown rollback success")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { res in
            XCTAssertEqual(self.errorCode(res), "SESSION_ACTIVATION_FAILED")
            exp.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Assert handler state recovered to idle (so we can start recording again without normalization)
        backend.activeShouldFail = false
        backend.availableInputsVal = [VGPortSnapshot(portType: AVAudioSession.Port.builtInMic.rawValue, portName: "mic", uid: "1", selectedDataSourceName: nil)]
        backend.currentRouteVal = VGRouteSnapshot(inputs: backend.availableInputsVal, outputs: [])

        let retryExp = expectation(description: "retry start success")
        handler.handleStart(args: ["outputPath": "/tmp/b.m4a"], handle: handle) { res in
            XCTAssertTrue(res is [String: Any])
            retryExp.fulfill()
        }
        waitForExpectations(timeout: 1.0)
    }

    func testRestorationAndNormalizationFailureFinishesBlocked() {
        // Drive into recording
        backend.availableInputsVal = [VGPortSnapshot(portType: AVAudioSession.Port.builtInMic.rawValue, portName: "mic", uid: "1", selectedDataSourceName: nil)]
        backend.currentRouteVal = VGRouteSnapshot(inputs: backend.availableInputsVal, outputs: [])

        let startExp = expectation(description: "start success")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { _ in startExp.fulfill() }
        waitForExpectations(timeout: 1.0)

        // Stop fails category switch back to Playback, and normalization fails too
        backend.categoryShouldFail = true

        let stopExp = expectation(description: "stop finishes blocked")
        handler.handleStop(handle: handle) { res in
            let map = res as? [String: Any]
            XCTAssertNotNil(map)
            let status = map?["transitionStatus"] as? [String: Any]
            XCTAssertEqual(status?["sessionRestored"] as? Bool, false)
            stopExp.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        // Verify start is now blocked
        let rejectStart = expectation(description: "start is blocked")
        handler.handleStart(args: ["outputPath": "/tmp/b.m4a"], handle: handle) { res in
            // Because normalization will fail (categoryShouldFail is true), we get SESSION_STATE_UNKNOWN
            XCTAssertEqual(self.errorCode(res), "SESSION_STATE_UNKNOWN")
            rejectStart.fulfill()
        }
        waitForExpectations(timeout: 1.0)
    }

    func testRecorderStateDisagreementOnStop() {
        // Force the handler into .recording state without activeRecorder
        // We do this by calling start (completing successfully) but then manually setting activeRecorder = nil
        backend.availableInputsVal = [VGPortSnapshot(portType: AVAudioSession.Port.builtInMic.rawValue, portName: "mic", uid: "1", selectedDataSourceName: nil)]
        backend.currentRouteVal = VGRouteSnapshot(inputs: backend.availableInputsVal, outputs: [])

        let startExp = expectation(description: "start success")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { _ in startExp.fulfill() }
        waitForExpectations(timeout: 1.0)

        // Break active recorder
        factory.stubbedRecorder.isRecording = false

        let stopExp = expectation(description: "stop cleans up and returns NOT_RECORDING")
        handler.handleStop(handle: handle) { res in
            XCTAssertEqual(self.errorCode(res), "NOT_RECORDING")
            stopExp.fulfill()
        }
        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(backend.category, AVAudioSession.Category.playback.rawValue)
    }

    func testNilRuntimeStopDiagnostics() {
        // Start normally
        backend.availableInputsVal = [VGPortSnapshot(portType: AVAudioSession.Port.builtInMic.rawValue, portName: "mic", uid: "1", selectedDataSourceName: nil)]
        backend.currentRouteVal = VGRouteSnapshot(inputs: backend.availableInputsVal, outputs: [])

        let startExp = expectation(description: "start success")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { _ in startExp.fulfill() }
        waitForExpectations(timeout: 1.0)

        // Stop with nil runtime handle
        let stopExp = expectation(description: "stop diagnostic")
        handler.handleStop(handle: nil) { res in
            let map = res as? [String: Any]
            XCTAssertNotNil(map)
            let status = map?["transitionStatus"] as? [String: Any]
            XCTAssertEqual(status?["previewRecovered"] as? Bool, false)
            XCTAssertEqual(status?["previewErrorCode"] as? String, "RECOVERY_RUNTIME_NIL")
            stopExp.fulfill()
        }
        waitForExpectations(timeout: 1.0)
    }

    func testStopMetadataSurvivesTransitionFailure() {
        // Start normally
        backend.availableInputsVal = [VGPortSnapshot(portType: AVAudioSession.Port.builtInMic.rawValue, portName: "mic", uid: "1", selectedDataSourceName: nil)]
        backend.currentRouteVal = VGRouteSnapshot(inputs: backend.availableInputsVal, outputs: [])

        let startExp = expectation(description: "start success")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { _ in startExp.fulfill() }
        waitForExpectations(timeout: 1.0)

        // Make session restoration fail
        backend.categoryShouldFail = true

        let stopExp = expectation(description: "stop metadata survives")
        handler.handleStop(handle: handle) { res in
            let map = res as? [String: Any]
            XCTAssertNotNil(map)
            XCTAssertEqual(map?["filePath"] as? String, "/tmp/mock.m4a")
            XCTAssertEqual(map?["startPTS"] as? Double, 1.0)
            XCTAssertEqual(map?["durationSeconds"] as? Double, 2.0)

            let status = map?["transitionStatus"] as? [String: Any]
            XCTAssertEqual(status?["sessionRestored"] as? Bool, false)
            stopExp.fulfill()
        }
        waitForExpectations(timeout: 1.0)
    }

    func testStartRecordingChronologicalOrder() {
        var trace: [String] = []
        backend.onEvent = { trace.append($0) }
        factory.stubbedRecorder.onEvent = { trace.append($0) }
        recoveryBlock = { _, completion in
            trace.append("previewRecovery")
            completion(nil)
        }

        backend.availableInputsVal = [VGPortSnapshot(portType: AVAudioSession.Port.builtInMic.rawValue, portName: "mic", uid: "1", selectedDataSourceName: nil)]
        backend.currentRouteVal = VGRouteSnapshot(inputs: backend.availableInputsVal, outputs: [])

        let exp = expectation(description: "start chronological")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { res in
            exp.fulfill()
        }

        waitForExpectations(timeout: 1.0)

        let expected = ["setCategory", "setActive", "currentRoute", "availableInputs", "previewRecovery", "recorderStart"]
        XCTAssertEqual(trace, expected)
    }
}

#endif // VG_USE_V2_GRAPH
