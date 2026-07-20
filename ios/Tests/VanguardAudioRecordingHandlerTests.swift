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
        onEvent?("recorderStop")
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

private final class FakeLifecycleHandler: VGAudioRecordingLifecycleHandling {
    var hasActiveCaptureOperation = false
    var suspendForLifecycleCount = 0
    var suspendForLifecycleReason: VGAudioRecordingTerminationReason?
    var suspendQuiescedCallback: (() -> Void)?
    var completeLifecycleRecoveryCount = 0
    var lastLifecycleTransition: VGRecordingLifecycleTransition?

    func suspendForLifecycle(reason: VGAudioRecordingTerminationReason, quiesced: @escaping () -> Void) {
        suspendForLifecycleCount += 1
        suspendForLifecycleReason = reason
        suspendQuiescedCallback = quiesced
    }

    func completeLifecycleRecovery(_ outcome: VGRecordingLifecycleTransition) {
        completeLifecycleRecoveryCount += 1
        lastLifecycleTransition = outcome
    }
}

private final class FakeTimelineLifecycle: VGAudioTimelineLifecycle {
    var pauseTimelineCount = 0
    var recoverPreviewCount = 0
    var recoverPreviewCompletion: ((Error?) -> Void)?
    var recoverPreviewErr: Error?

    func pauseTimeline() {
        pauseTimelineCount += 1
    }

    func recoverPreview(completion: @escaping (Error?) -> Void) {
        recoverPreviewCount += 1
        recoverPreviewCompletion = completion
        if let err = recoverPreviewErr {
            completion(err)
        }
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

    func testP0StaleStopCleanupHasNoEffect() {
        backend.availableInputsVal = [VGPortSnapshot(portType: AVAudioSession.Port.builtInMic.rawValue, portName: "mic", uid: "1", selectedDataSourceName: nil)]
        backend.currentRouteVal = VGRouteSnapshot(inputs: backend.availableInputsVal, outputs: [])

        let startExp = expectation(description: "start success")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { _ in startExp.fulfill() }
        wait(for: [startExp], timeout: 1.0)

        var recoveryCompletion: ((Error?) -> Void)? = nil
        recoveryBlock = { h, completion in
            recoveryCompletion = completion
        }

        let stopExp = expectation(description: "stop callback")
        handler.handleStop(handle: handle) { res in
            let map = res as? [String: Any]
            XCTAssertNotNil(map)
            let status = map?["transitionStatus"] as? [String: Any]
            XCTAssertEqual(status?.keys.contains("terminationReason"), false, "User stop should omit terminationReason")
            XCTAssertEqual(status?["sessionRestored"] as? Bool, true)
            stopExp.fulfill()
        }

        let quiescedExp = expectation(description: "quiesced called")
        handler.suspendForLifecycle(reason: .interruption) {
            quiescedExp.fulfill()
        }
        wait(for: [quiescedExp], timeout: 1.0)

        handler.completeLifecycleRecovery(VGRecordingLifecycleTransition(
            sessionRestored: true,
            sessionErrorCode: nil,
            previewRecovered: true,
            previewErrorCode: nil
        ))

        recoveryCompletion?(nil)
        wait(for: [stopExp], timeout: 1.0)

        recoveryBlock = nil

        let start2Exp = expectation(description: "start 2 success")
        handler.handleStart(args: ["outputPath": "/tmp/b.m4a"], handle: handle) { res in
            XCTAssertTrue(res is [String: Any])
            start2Exp.fulfill()
        }
        wait(for: [start2Exp], timeout: 1.0)
    }

    func testInactiveRecorderLifecyclePreemptionQuiescesAndResolvesExactlyOnce() {
        // 1. Start recording normally so handler state becomes `.recording` and activeRecorder contains the fake recorder.
        backend.availableInputsVal = [VGPortSnapshot(portType: AVAudioSession.Port.builtInMic.rawValue, portName: "mic", uid: "1", selectedDataSourceName: nil)]
        backend.currentRouteVal = VGRouteSnapshot(inputs: backend.availableInputsVal, outputs: [])

        let startExp = expectation(description: "start success")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { _ in startExp.fulfill() }
        wait(for: [startExp], timeout: 1.0)

        // 2. Set the fake recorder’s `isRecording` to false while leaving the recorder object installed.
        factory.stubbedRecorder.isRecording = false

        // 3. Replace preview recovery with a controlled closure that retains the cleanup completion without firing it.
        var retainedCleanupCompletion: ((Error?) -> Void)? = nil
        recoveryBlock = { h, completion in
            retainedCleanupCompletion = completion
        }

        // 4. Call handleStop and count all FlutterResult deliveries.
        var deliveryCount = 0
        var lastResult: Any? = nil
        handler.handleStop(handle: handle) { res in
            deliveryCount += 1
            lastResult = res
        }

        // 5. Call suspendForLifecycle(.interruption).
        let quiescedExp = expectation(description: "quiesced called")
        handler.suspendForLifecycle(reason: .interruption) {
            quiescedExp.fulfill()
        }

        // 6. Assert quiescence occurs promptly and deterministically.
        wait(for: [quiescedExp], timeout: 1.0)

        // 7. Assert the stop result has not been delivered before lifecycle recovery completes.
        XCTAssertEqual(deliveryCount, 0, "Stop result should not be delivered before recovery completes")

        // 8. Call completeLifecycleRecovery with a successful session/preview outcome.
        handler.completeLifecycleRecovery(VGRecordingLifecycleTransition(
            sessionRestored: true,
            sessionErrorCode: nil,
            previewRecovered: true,
            previewErrorCode: nil
        ))

        // 9. Assert the original stop result is delivered exactly once.
        XCTAssertEqual(deliveryCount, 1, "Stop result should be delivered exactly once after recovery")

        // 10. Assert its error code is STOP_FAILED because no recorder metadata exists.
        XCTAssertEqual(errorCode(lastResult), "STOP_FAILED", "Expected error code STOP_FAILED because metadata is absent")

        // 11. Fire the old retained cleanup completion.
        XCTAssertNotNil(retainedCleanupCompletion)
        retainedCleanupCompletion?(nil)

        // 12. Assert delivery count remains exactly one.
        XCTAssertEqual(deliveryCount, 1, "Delivery count must remain exactly one after staled callback fires")

        // 13. Restore immediate preview recovery.
        recoveryBlock = nil

        // 14. Start a second recording successfully, proving the stale callback did not corrupt state.
        let start2Exp = expectation(description: "start 2 success")
        handler.handleStart(args: ["outputPath": "/tmp/b.m4a"], handle: handle) { res in
            XCTAssertTrue(res is [String: Any])
            start2Exp.fulfill()
        }
        wait(for: [start2Exp], timeout: 1.0)
    }

    func testLifecycleDuringStartRecoveryStalesCallback() {
        backend.availableInputsVal = [VGPortSnapshot(portType: AVAudioSession.Port.builtInMic.rawValue, portName: "mic", uid: "1", selectedDataSourceName: nil)]
        backend.currentRouteVal = VGRouteSnapshot(inputs: backend.availableInputsVal, outputs: [])

        var startResultCount = 0
        var lastStartResult: Any? = nil
        var recoveryCompletion: ((Error?) -> Void)? = nil

        recoveryBlock = { h, completion in
            recoveryCompletion = completion
        }

        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { res in
            startResultCount += 1
            lastStartResult = res
        }

        XCTAssertNotNil(recoveryCompletion)
        XCTAssertEqual(startResultCount, 0)

        let quiesceExp = expectation(description: "quiesced")
        handler.suspendForLifecycle(reason: .interruption) {
            quiesceExp.fulfill()
        }
        wait(for: [quiesceExp], timeout: 1.0)

        XCTAssertEqual(startResultCount, 1)
        XCTAssertEqual(errorCode(lastStartResult), "RECORDING_INTERRUPTED")

        recoveryCompletion?(nil)

        XCTAssertFalse(factory.stubbedRecorder.isRecording)
        XCTAssertEqual(startResultCount, 1)

        handler.completeLifecycleRecovery(VGRecordingLifecycleTransition.success)
        _ = coordinator.forceNormalizePlaybackAfterExternalChange()

        recoveryBlock = nil
        let start2Exp = expectation(description: "start 2 success")
        handler.handleStart(args: ["outputPath": "/tmp/b.m4a"], handle: handle) { res in
            if let err = res as? FakeFlutterError {
                print("--- testLifecycleDuringStartRecoveryStalesCallback start2 result error code: \(err.code) message: \(err.message ?? "")")
            } else {
                print("--- testLifecycleDuringStartRecoveryStalesCallback start2 result: \(res)")
            }
            XCTAssertTrue(res is [String: Any])
            start2Exp.fulfill()
        }
        wait(for: [start2Exp], timeout: 1.0)
    }

    func testLifecycleDuringBlockedStartRecoveryStalesCallback() {
        backend.activeShouldFail = true
        backend.rollbackActiveShouldFail = true
        let startFailExp = expectation(description: "start fails")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { _ in startFailExp.fulfill() }
        wait(for: [startFailExp], timeout: 1.0)

        backend.activeShouldFail = false
        backend.rollbackActiveShouldFail = false
        backend.availableInputsVal = [VGPortSnapshot(portType: AVAudioSession.Port.builtInMic.rawValue, portName: "mic", uid: "1", selectedDataSourceName: nil)]
        backend.currentRouteVal = VGRouteSnapshot(inputs: backend.availableInputsVal, outputs: [])

        var startResultCount = 0
        var lastStartResult: Any? = nil
        var recoveryCompletion: ((Error?) -> Void)? = nil

        recoveryBlock = { h, completion in
            recoveryCompletion = completion
        }

        handler.handleStart(args: ["outputPath": "/tmp/b.m4a"], handle: handle) { res in
            startResultCount += 1
            lastStartResult = res
        }

        XCTAssertNotNil(recoveryCompletion)
        XCTAssertEqual(startResultCount, 0)

        let quiesceExp = expectation(description: "quiesced")
        handler.suspendForLifecycle(reason: .interruption) {
            quiesceExp.fulfill()
        }
        wait(for: [quiesceExp], timeout: 1.0)

        XCTAssertEqual(startResultCount, 1)
        XCTAssertEqual(errorCode(lastStartResult), "RECORDING_INTERRUPTED")

        recoveryCompletion?(nil)

        XCTAssertFalse(factory.stubbedRecorder.isRecording)
        XCTAssertEqual(startResultCount, 1)
    }

    func testSystemTerminationDuringActiveRecording() {
        backend.availableInputsVal = [VGPortSnapshot(portType: AVAudioSession.Port.builtInMic.rawValue, portName: "mic", uid: "1", selectedDataSourceName: nil)]
        backend.currentRouteVal = VGRouteSnapshot(inputs: backend.availableInputsVal, outputs: [])

        let startExp = expectation(description: "start success")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { _ in startExp.fulfill() }
        wait(for: [startExp], timeout: 1.0)

        var stopCallbackCount = 0
        factory.stubbedRecorder.onEvent = { event in
            if event == "recorderStop" {
                stopCallbackCount += 1
            }
        }

        let quiesceExp = expectation(description: "quiesced")
        handler.suspendForLifecycle(reason: .interruption) {
            quiesceExp.fulfill()
        }
        wait(for: [quiesceExp], timeout: 1.0)

        XCTAssertEqual(stopCallbackCount, 1)

        handler.completeLifecycleRecovery(VGRecordingLifecycleTransition.success)

        let stopExp = expectation(description: "stop terminal result")
        handler.handleStop(handle: handle) { res in
            let map = res as? [String: Any]
            XCTAssertNotNil(map)
            XCTAssertEqual(map?["filePath"] as? String, "/tmp/mock.m4a")
            let ts = map?["transitionStatus"] as? [String: Any]
            XCTAssertEqual(ts?["terminationReason"] as? String, "interruption")
            stopExp.fulfill()
        }
        wait(for: [stopExp], timeout: 1.0)
    }

    func testRecoveryFailureAfterSystemTermination() {
        backend.availableInputsVal = [VGPortSnapshot(portType: AVAudioSession.Port.builtInMic.rawValue, portName: "mic", uid: "1", selectedDataSourceName: nil)]
        backend.currentRouteVal = VGRouteSnapshot(inputs: backend.availableInputsVal, outputs: [])

        let startExp = expectation(description: "start success")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { _ in startExp.fulfill() }
        wait(for: [startExp], timeout: 1.0)

        let quiesceExp = expectation(description: "quiesced")
        handler.suspendForLifecycle(reason: .interruption) {
            quiesceExp.fulfill()
        }
        wait(for: [quiesceExp], timeout: 1.0)

        handler.completeLifecycleRecovery(VGRecordingLifecycleTransition.sessionFailed(code: "ERR"))

        let stopExp = expectation(description: "stop terminal failure")
        handler.handleStop(handle: handle) { res in
            let map = res as? [String: Any]
            XCTAssertNotNil(map)
            let ts = map?["transitionStatus"] as? [String: Any]
            XCTAssertEqual(ts?["sessionRestored"] as? Bool, false)
            stopExp.fulfill()
        }
        wait(for: [stopExp], timeout: 1.0)

        let start2Exp = expectation(description: "start fails from blocked")
        backend.categoryShouldFail = true
        handler.handleStart(args: ["outputPath": "/tmp/b.m4a"], handle: handle) { res in
            XCTAssertEqual(self.errorCode(res), "SESSION_STATE_UNKNOWN")
            start2Exp.fulfill()
        }
        wait(for: [start2Exp], timeout: 1.0)
    }

    func testUserStopPreemptedByLifecycle() {
        backend.availableInputsVal = [VGPortSnapshot(portType: AVAudioSession.Port.builtInMic.rawValue, portName: "mic", uid: "1", selectedDataSourceName: nil)]
        backend.currentRouteVal = VGRouteSnapshot(inputs: backend.availableInputsVal, outputs: [])

        let startExp = expectation(description: "start success")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { _ in startExp.fulfill() }
        wait(for: [startExp], timeout: 1.0)

        var stopCallbackCount = 0
        factory.stubbedRecorder.onEvent = { event in
            if event == "recorderStop" {
                stopCallbackCount += 1
            }
        }

        // Block cleanup so preemption can happen during stopping
        var recoveryCompletion: ((Error?) -> Void)? = nil
        recoveryBlock = { h, completion in
            recoveryCompletion = completion
        }

        var stopResultCount = 0
        var stopResult: Any? = nil

        handler.handleStop(handle: handle) { res in
            stopResultCount += 1
            stopResult = res
        }

        let quiesceExp = expectation(description: "quiesced")
        handler.suspendForLifecycle(reason: .interruption) {
            quiesceExp.fulfill()
        }
        wait(for: [quiesceExp], timeout: 1.0)

        XCTAssertEqual(stopCallbackCount, 1)
        XCTAssertEqual(stopResultCount, 0)

        handler.completeLifecycleRecovery(VGRecordingLifecycleTransition.success)

        recoveryCompletion?(nil) // Fire stale cleanup callback

        XCTAssertEqual(stopResultCount, 1)
        let map = stopResult as? [String: Any]
        XCTAssertNotNil(map)
        let ts = map?["transitionStatus"] as? [String: Any]
        XCTAssertNil(ts?["terminationReason"])
    }

    func testFirstTerminationReasonWins() {
        backend.availableInputsVal = [VGPortSnapshot(portType: AVAudioSession.Port.builtInMic.rawValue, portName: "mic", uid: "1", selectedDataSourceName: nil)]
        backend.currentRouteVal = VGRouteSnapshot(inputs: backend.availableInputsVal, outputs: [])

        let startExp = expectation(description: "start success")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { _ in startExp.fulfill() }
        wait(for: [startExp], timeout: 1.0)

        let q1 = expectation(description: "q1")
        handler.suspendForLifecycle(reason: .interruption) {
            q1.fulfill()
        }
        wait(for: [q1], timeout: 1.0)

        let q2 = expectation(description: "q2")
        handler.suspendForLifecycle(reason: .background) {
            q2.fulfill()
        }
        wait(for: [q2], timeout: 1.0)

        handler.completeLifecycleRecovery(VGRecordingLifecycleTransition.success)

        let stopExp = expectation(description: "stop")
        handler.handleStop(handle: handle) { res in
            let map = res as? [String: Any]
            let ts = map?["transitionStatus"] as? [String: Any]
            XCTAssertEqual(ts?["terminationReason"] as? String, "interruption")
            stopExp.fulfill()
        }
        wait(for: [stopExp], timeout: 1.0)
    }

    func testDuplicateStop() {
        backend.availableInputsVal = [VGPortSnapshot(portType: AVAudioSession.Port.builtInMic.rawValue, portName: "mic", uid: "1", selectedDataSourceName: nil)]
        backend.currentRouteVal = VGRouteSnapshot(inputs: backend.availableInputsVal, outputs: [])

        let startExp = expectation(description: "start success")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { _ in startExp.fulfill() }
        wait(for: [startExp], timeout: 1.0)

        // Block cleanup so first stop is in progress
        var recoveryCompletion: ((Error?) -> Void)? = nil
        recoveryBlock = { h, completion in
            recoveryCompletion = completion
        }

        handler.handleStop(handle: handle) { _ in }

        var secondStopResult: Any? = nil
        handler.handleStop(handle: handle) { res in
            secondStopResult = res
        }
        XCTAssertEqual(errorCode(secondStopResult), "STOP_IN_PROGRESS")

        recoveryCompletion?(nil) // Unblock first stop cleanup
    }

    func testStartWhileTerminalResultPending() {
        backend.availableInputsVal = [VGPortSnapshot(portType: AVAudioSession.Port.builtInMic.rawValue, portName: "mic", uid: "1", selectedDataSourceName: nil)]
        backend.currentRouteVal = VGRouteSnapshot(inputs: backend.availableInputsVal, outputs: [])

        let startExp = expectation(description: "start success")
        handler.handleStart(args: ["outputPath": "/tmp/a.m4a"], handle: handle) { _ in startExp.fulfill() }
        wait(for: [startExp], timeout: 1.0)

        let quiesceExp = expectation(description: "quiesced")
        handler.suspendForLifecycle(reason: .interruption) {
            quiesceExp.fulfill()
        }
        wait(for: [quiesceExp], timeout: 1.0)

        handler.completeLifecycleRecovery(VGRecordingLifecycleTransition.success)

        var startResult: Any? = nil
        handler.handleStart(args: ["outputPath": "/tmp/b.m4a"], handle: handle) { res in
            startResult = res
        }
        XCTAssertEqual(errorCode(startResult), "STOP_RESULT_PENDING")
    }

    func testLifecycleCoordinatorInterruptionInhibitor() {
        let fakeHandler = FakeLifecycleHandler()
        let fakeTimeline = FakeTimelineLifecycle()
        let coord = VGAudioLifecycleCoordinator(recordingHandler: fakeHandler,
                                                coordinator: coordinator,
                                                timelineLifecycle: fakeTimeline)

        coord.interruptionBegan()
        XCTAssertEqual(fakeTimeline.pauseTimelineCount, 1)

        XCTAssertEqual(fakeTimeline.recoverPreviewCount, 0)

        coord.interruptionEnded()
        XCTAssertEqual(fakeTimeline.recoverPreviewCount, 1)
    }

    func testLifecycleCoordinatorBackgroundInhibitor() {
        let fakeHandler = FakeLifecycleHandler()
        let fakeTimeline = FakeTimelineLifecycle()
        let coord = VGAudioLifecycleCoordinator(recordingHandler: fakeHandler,
                                                coordinator: coordinator,
                                                timelineLifecycle: fakeTimeline)

        coord.didEnterBackground()
        XCTAssertEqual(fakeTimeline.pauseTimelineCount, 1)
        XCTAssertEqual(fakeTimeline.recoverPreviewCount, 0)

        coord.didBecomeActive()
        XCTAssertEqual(fakeTimeline.recoverPreviewCount, 1)
    }

    func testLifecycleCoordinatorCombinedInhibitors() {
        let fakeHandler = FakeLifecycleHandler()
        let fakeTimeline = FakeTimelineLifecycle()
        let coord = VGAudioLifecycleCoordinator(recordingHandler: fakeHandler,
                                                coordinator: coordinator,
                                                timelineLifecycle: fakeTimeline)

        coord.interruptionBegan()
        coord.didEnterBackground()

        coord.interruptionEnded()
        XCTAssertEqual(fakeTimeline.recoverPreviewCount, 0)

        coord.didBecomeActive()
        XCTAssertEqual(fakeTimeline.recoverPreviewCount, 1)
    }

    func testLifecycleCoordinatorCaptureQuiescenceGating() {
        let fakeHandler = FakeLifecycleHandler()
        let fakeTimeline = FakeTimelineLifecycle()
        let coord = VGAudioLifecycleCoordinator(recordingHandler: fakeHandler,
                                                coordinator: coordinator,
                                                timelineLifecycle: fakeTimeline)

        fakeHandler.hasActiveCaptureOperation = true

        coord.interruptionBegan()
        XCTAssertEqual(fakeHandler.suspendForLifecycleCount, 1)
        XCTAssertEqual(fakeTimeline.recoverPreviewCount, 0)

        fakeHandler.suspendQuiescedCallback?()
        XCTAssertEqual(fakeTimeline.recoverPreviewCount, 0)

        coord.interruptionEnded()
        XCTAssertEqual(fakeTimeline.recoverPreviewCount, 1)
    }

    func testLifecycleCoordinatorSecondRouteEventInvalidatesOlderCallback() {
        let fakeHandler = FakeLifecycleHandler()
        let fakeTimeline = FakeTimelineLifecycle()
        let coord = VGAudioLifecycleCoordinator(recordingHandler: fakeHandler,
                                                coordinator: coordinator,
                                                timelineLifecycle: fakeTimeline)

        coord.routeChanged(.oldDeviceUnavailable)
        XCTAssertEqual(fakeTimeline.recoverPreviewCount, 1)

        let originalCompletion = fakeTimeline.recoverPreviewCompletion
        XCTAssertNotNil(originalCompletion)

        coord.routeChanged(.newDeviceAvailable)
        XCTAssertEqual(fakeTimeline.recoverPreviewCount, 1)

        originalCompletion?(nil)

        XCTAssertEqual(fakeTimeline.recoverPreviewCount, 2)
    }

    func testLifecycleCoordinatorOldDeviceUnavailableAlwaysPauses() {
        let fakeHandler = FakeLifecycleHandler()
        let fakeTimeline = FakeTimelineLifecycle()
        let coord = VGAudioLifecycleCoordinator(recordingHandler: fakeHandler,
                                                coordinator: coordinator,
                                                timelineLifecycle: fakeTimeline)

        coord.routeChanged(.oldDeviceUnavailable)
        XCTAssertEqual(fakeTimeline.pauseTimelineCount, 1)
    }

    func testLifecycleCoordinatorNewDeviceAvailableWithActiveCapturePausesAndQuiesces() {
        let fakeHandler = FakeLifecycleHandler()
        let fakeTimeline = FakeTimelineLifecycle()
        let coord = VGAudioLifecycleCoordinator(recordingHandler: fakeHandler,
                                                coordinator: coordinator,
                                                timelineLifecycle: fakeTimeline)

        fakeHandler.hasActiveCaptureOperation = true
        coord.routeChanged(.newDeviceAvailable)

        XCTAssertEqual(fakeTimeline.pauseTimelineCount, 1)
        XCTAssertEqual(fakeHandler.suspendForLifecycleCount, 1)
    }

    func testLifecycleCoordinatorNewDeviceAvailableWithoutActiveCaptureMayAvoidPause() {
        let fakeHandler = FakeLifecycleHandler()
        let fakeTimeline = FakeTimelineLifecycle()
        let coord = VGAudioLifecycleCoordinator(recordingHandler: fakeHandler,
                                                coordinator: coordinator,
                                                timelineLifecycle: fakeTimeline)

        fakeHandler.hasActiveCaptureOperation = false
        coord.routeChanged(.newDeviceAvailable)

        XCTAssertEqual(fakeTimeline.pauseTimelineCount, 0)
        XCTAssertEqual(fakeHandler.suspendForLifecycleCount, 0)
    }

    func testLifecycleCoordinatorNormalizationFailureSkipsPreviewRecovery() {
        let fakeHandler = FakeLifecycleHandler()
        let fakeTimeline = FakeTimelineLifecycle()
        let coord = VGAudioLifecycleCoordinator(recordingHandler: fakeHandler,
                                                coordinator: coordinator,
                                                timelineLifecycle: fakeTimeline)

        backend.categoryShouldFail = true

        coord.interruptionBegan()
        coord.interruptionEnded()

        XCTAssertEqual(fakeTimeline.recoverPreviewCount, 0)
        XCTAssertEqual(fakeHandler.completeLifecycleRecoveryCount, 1)
        XCTAssertEqual(fakeHandler.lastLifecycleTransition?.sessionRestored, false)
    }

    func testLifecycleCoordinatorPreviewRecoveryFailureDeliveredToHandler() {
        let fakeHandler = FakeLifecycleHandler()
        let fakeTimeline = FakeTimelineLifecycle()
        let coord = VGAudioLifecycleCoordinator(recordingHandler: fakeHandler,
                                                coordinator: coordinator,
                                                timelineLifecycle: fakeTimeline)

        fakeTimeline.recoverPreviewErr = NSError(domain: "Test", code: 42)

        coord.interruptionBegan()
        coord.interruptionEnded()

        XCTAssertEqual(fakeTimeline.recoverPreviewCount, 1)
        XCTAssertEqual(fakeHandler.completeLifecycleRecoveryCount, 1)
        XCTAssertEqual(fakeHandler.lastLifecycleTransition?.previewRecovered, false)
    }

    func testLifecycleCoordinatorNoPathCallsTimelinePlay() {
        let fakeHandler = FakeLifecycleHandler()
        let fakeTimeline = FakeTimelineLifecycle()
        _ = VGAudioLifecycleCoordinator(recordingHandler: fakeHandler,
                                        coordinator: coordinator,
                                        timelineLifecycle: fakeTimeline)

        XCTAssertEqual(fakeTimeline.pauseTimelineCount, 0)
    }

}

#endif // VG_USE_V2_GRAPH
