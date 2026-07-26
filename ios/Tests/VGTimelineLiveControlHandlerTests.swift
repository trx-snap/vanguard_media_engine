// VGTimelineLiveControlHandlerTests.swift
// vanguard_media_engine — Audio Track Interaction Programme S-P1
//
// Unit tests for VGTimelineLiveControlHandler.

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

private let testFlutterErrorFactory: VGTLCFlutterErrorFactory = { code, message, details in
    FakeFlutterError(code: code, message: message, details: details)
}

final class VGTimelineLiveControlHandlerTests: XCTestCase {

    func test1_missingTextureId_returnsInvalidArg() {
        var providerCalled = false
        let handler = VGTimelineLiveControlHandler(
            targetProvider: {
                providerCalled = true
                return VGTimelineLiveFilterTarget(textureId: 42) { _ in (true, nil) }
            },
            errorFactory: testFlutterErrorFactory
        )

        var resultCallCount = 0
        var receivedResult: Any? = nil

        handler.handle(args: ["filters": []]) { res in
            resultCallCount += 1
            receivedResult = res
        }

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertEqual(errorCode(receivedResult), "INVALID_ARG")
        XCTAssertFalse(providerCalled, "targetProvider must not be called when argument validation fails")
    }

    func test2_nonNumberTextureId_returnsInvalidArg() {
        var providerCalled = false
        let handler = VGTimelineLiveControlHandler(
            targetProvider: {
                providerCalled = true
                return VGTimelineLiveFilterTarget(textureId: 42) { _ in (true, nil) }
            },
            errorFactory: testFlutterErrorFactory
        )

        var resultCallCount = 0
        var receivedResult: Any? = nil

        handler.handle(args: ["textureId": "not_a_number", "filters": []]) { res in
            resultCallCount += 1
            receivedResult = res
        }

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertEqual(errorCode(receivedResult), "INVALID_ARG")
        XCTAssertFalse(providerCalled)
    }

    func test3a_swiftBoolTextureId_returnsInvalidArgWithoutCrash() {
        var providerCalled = false
        let handler = VGTimelineLiveControlHandler(
            targetProvider: {
                providerCalled = true
                return VGTimelineLiveFilterTarget(textureId: 1) { _ in (true, nil) }
            },
            errorFactory: testFlutterErrorFactory
        )

        var resultCallCount = 0
        var receivedResult: Any? = nil

        let swiftBool: Bool = true
        handler.handle(args: ["textureId": swiftBool, "filters": []]) { res in
            resultCallCount += 1
            receivedResult = res
        }

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertEqual(errorCode(receivedResult), "INVALID_ARG")
        XCTAssertFalse(providerCalled, "targetProvider must not be called for Swift Bool textureId")
    }

    func test3b_nsNumberBoolTextureId_returnsInvalidArgWithoutCrash() {
        var providerCalled = false
        let handler = VGTimelineLiveControlHandler(
            targetProvider: {
                providerCalled = true
                return VGTimelineLiveFilterTarget(textureId: 1) { _ in (true, nil) }
            },
            errorFactory: testFlutterErrorFactory
        )

        var resultCallCount = 0
        var receivedResult: Any? = nil

        let nsBool: NSNumber = NSNumber(value: true)
        handler.handle(args: ["textureId": nsBool, "filters": []]) { res in
            resultCallCount += 1
            receivedResult = res
        }

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertEqual(errorCode(receivedResult), "INVALID_ARG")
        XCTAssertFalse(providerCalled, "targetProvider must not be called for NSNumber(value: true) textureId")
    }

    func test4_floatAndDoubleTextureId_returnsInvalidArg() {
        var providerCalled = false
        let handler = VGTimelineLiveControlHandler(
            targetProvider: {
                providerCalled = true
                return VGTimelineLiveFilterTarget(textureId: 1) { _ in (true, nil) }
            },
            errorFactory: testFlutterErrorFactory
        )

        // Double 1.0 (integral double value passed as Double/Float)
        var resultCallCount = 0
        var receivedResult: Any? = nil

        handler.handle(args: ["textureId": Double(1.0), "filters": []]) { res in
            resultCallCount += 1
            receivedResult = res
        }

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertEqual(errorCode(receivedResult), "INVALID_ARG")
        XCTAssertFalse(providerCalled)

        // Fractional float 2.5
        resultCallCount = 0
        receivedResult = nil

        handler.handle(args: ["textureId": Float(2.5), "filters": []]) { res in
            resultCallCount += 1
            receivedResult = res
        }

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertEqual(errorCode(receivedResult), "INVALID_ARG")
        XCTAssertFalse(providerCalled)
    }

    func test5_negativeInteger_returnsInvalidArg() {
        var providerCalled = false
        let handler = VGTimelineLiveControlHandler(
            targetProvider: {
                providerCalled = true
                return VGTimelineLiveFilterTarget(textureId: 1) { _ in (true, nil) }
            },
            errorFactory: testFlutterErrorFactory
        )

        var resultCallCount = 0
        var receivedResult: Any? = nil

        handler.handle(args: ["textureId": -5, "filters": []]) { res in
            resultCallCount += 1
            receivedResult = res
        }

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertEqual(errorCode(receivedResult), "INVALID_ARG")
        XCTAssertFalse(providerCalled)
    }

    func test6a_nsNumberUInt64MaxTextureId_returnsInvalidArgWithoutTruncationOrCrash() {
        var providerCalled = false
        let handler = VGTimelineLiveControlHandler(
            targetProvider: {
                providerCalled = true
                return VGTimelineLiveFilterTarget(textureId: 1) { _ in (true, nil) }
            },
            errorFactory: testFlutterErrorFactory
        )

        var resultCallCount = 0
        var receivedResult: Any? = nil

        let nsUInt64Max = NSNumber(value: UInt64.max)
        handler.handle(args: ["textureId": nsUInt64Max, "filters": []]) { res in
            resultCallCount += 1
            receivedResult = res
        }

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertEqual(errorCode(receivedResult), "INVALID_ARG")
        XCTAssertFalse(providerCalled, "targetProvider must not be called when textureId overflows Int64")
    }

    func test6b_nsDecimalNumberOverflowTextureId_returnsInvalidArgWithoutCrash() {
        var providerCalled = false
        let handler = VGTimelineLiveControlHandler(
            targetProvider: {
                providerCalled = true
                return VGTimelineLiveFilterTarget(textureId: 1) { _ in (true, nil) }
            },
            errorFactory: testFlutterErrorFactory
        )

        var resultCallCount = 0
        var receivedResult: Any? = nil

        // Value strictly greater than Int64.max (9223372036854775807)
        let overflowVal = Decimal(string: "999999999999999999999999999")!
        handler.handle(args: ["textureId": NSDecimalNumber(decimal: overflowVal), "filters": []]) { res in
            resultCallCount += 1
            receivedResult = res
        }

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertEqual(errorCode(receivedResult), "INVALID_ARG")
        XCTAssertFalse(providerCalled)
    }

    func test7_int64MaxAcceptedWhenMatchingTarget() {
        var applyCalled = false
        let handler = VGTimelineLiveControlHandler(
            targetProvider: {
                return VGTimelineLiveFilterTarget(textureId: Int64.max) { _ in
                    applyCalled = true
                    return (true, nil)
                }
            },
            errorFactory: testFlutterErrorFactory
        )

        var resultCallCount = 0
        var receivedResult: Any? = "not_set"

        handler.handle(args: ["textureId": Int64.max, "filters": []]) { res in
            resultCallCount += 1
            receivedResult = res
        }

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertNil(receivedResult) // nil indicates success
        XCTAssertTrue(applyCalled)
    }

    func test8_missingOrMalformedFilters_returnsInvalidArg() {
        var providerCalled = false
        let handler = VGTimelineLiveControlHandler(
            targetProvider: {
                providerCalled = true
                return VGTimelineLiveFilterTarget(textureId: 10) { _ in (true, nil) }
            },
            errorFactory: testFlutterErrorFactory
        )

        // Missing filters key
        var resultCallCount = 0
        var receivedResult: Any? = nil

        handler.handle(args: ["textureId": 10]) { res in
            resultCallCount += 1
            receivedResult = res
        }

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertEqual(errorCode(receivedResult), "INVALID_ARG")
        XCTAssertFalse(providerCalled)

        // Malformed filters (string instead of array)
        resultCallCount = 0
        receivedResult = nil

        handler.handle(args: ["textureId": 10, "filters": "not_an_array"]) { res in
            resultCallCount += 1
            receivedResult = res
        }

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertEqual(errorCode(receivedResult), "INVALID_ARG")
        XCTAssertFalse(providerCalled)
    }

    func test9_emptyFilterArrayReachesApplyClosureUnchanged() {
        var receivedSpecs: [[String: Any]]? = nil
        let handler = VGTimelineLiveControlHandler(
            targetProvider: {
                return VGTimelineLiveFilterTarget(textureId: 10) { specs in
                    receivedSpecs = specs
                    return (true, nil)
                }
            },
            errorFactory: testFlutterErrorFactory
        )

        var resultCallCount = 0
        var receivedResult: Any? = "not_set"

        handler.handle(args: ["textureId": 10, "filters": []]) { res in
            resultCallCount += 1
            receivedResult = res
        }

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertNil(receivedResult)
        XCTAssertNotNil(receivedSpecs)
        XCTAssertEqual(receivedSpecs?.count, 0)
    }

    func test10_noTarget_returnsNoTimeline() {
        let handler = VGTimelineLiveControlHandler(
            targetProvider: {
                return nil // NO_TIMELINE
            },
            errorFactory: testFlutterErrorFactory
        )

        var resultCallCount = 0
        var receivedResult: Any? = nil

        handler.handle(args: ["textureId": 10, "filters": []]) { res in
            resultCallCount += 1
            receivedResult = res
        }

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertEqual(errorCode(receivedResult), "NO_TIMELINE")
    }

    func test11_mismatchedTextureId_returnsStaleTimelineAndApplyNotCalled() {
        var applyCalled = false
        let handler = VGTimelineLiveControlHandler(
            targetProvider: {
                return VGTimelineLiveFilterTarget(textureId: 100) { _ in
                    applyCalled = true
                    return (true, nil)
                }
            },
            errorFactory: testFlutterErrorFactory
        )

        var resultCallCount = 0
        var receivedResult: Any? = nil

        handler.handle(args: ["textureId": 99, "filters": []]) { res in
            resultCallCount += 1
            receivedResult = res
        }

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertEqual(errorCode(receivedResult), "STALE_TIMELINE")
        XCTAssertFalse(applyCalled, "apply closure must not be called when textureId is stale")
    }

    func test12_replacementTargetResolvedAtCallTime_stalePriorIdCannotMutate() {
        var activeTextureId: Int64 = 1
        var applyCallCount = 0

        let handler = VGTimelineLiveControlHandler(
            targetProvider: {
                let currentId = activeTextureId
                return VGTimelineLiveFilterTarget(textureId: currentId) { _ in
                    applyCallCount += 1
                    return (true, nil)
                }
            },
            errorFactory: testFlutterErrorFactory
        )

        // Call 1 with textureId 1 -> success
        var resultCount1 = 0
        handler.handle(args: ["textureId": 1, "filters": []]) { res in
            resultCount1 += 1
            XCTAssertNil(res)
        }
        XCTAssertEqual(resultCount1, 1)
        XCTAssertEqual(applyCallCount, 1)

        // Timeline replaced: textureId changes to 2
        activeTextureId = 2

        // Call 2 with stale textureId 1 -> STALE_TIMELINE, apply NOT called
        var resultCount2 = 0
        handler.handle(args: ["textureId": 1, "filters": []]) { res in
            resultCount2 += 1
            XCTAssertEqual(errorCode(res), "STALE_TIMELINE")
        }
        XCTAssertEqual(resultCount2, 1)
        XCTAssertEqual(applyCallCount, 1) // still 1

        // Call 3 with new active textureId 2 -> success
        var resultCount3 = 0
        handler.handle(args: ["textureId": 2, "filters": []]) { res in
            resultCount3 += 1
            XCTAssertNil(res)
        }
        XCTAssertEqual(resultCount3, 1)
        XCTAssertEqual(applyCallCount, 2)
    }

    func test13_unknownRuntimeResult_returnsUnknownFilterWithoutDuplicateValidationPolicy() {
        let handler = VGTimelineLiveControlHandler(
            targetProvider: {
                return VGTimelineLiveFilterTarget(textureId: 5) { _ in
                    return (false, "custom_unsupported_filter")
                }
            },
            errorFactory: testFlutterErrorFactory
        )

        var resultCallCount = 0
        var receivedResult: Any? = nil

        let specs: [[String: Any]] = [
            ["type": "custom_unsupported_filter", "enabled": true]
        ]

        handler.handle(args: ["textureId": 5, "filters": specs]) { res in
            resultCallCount += 1
            receivedResult = res
        }

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertEqual(errorCode(receivedResult), "UNKNOWN_FILTER")
    }

    func test14_validOrderedSpecs_callsApplyExactlyOnceAndReturnsSuccess() {
        var capturedSpecs: [[String: Any]]? = nil
        var applyCallCount = 0

        let handler = VGTimelineLiveControlHandler(
            targetProvider: {
                return VGTimelineLiveFilterTarget(textureId: 10) { specs in
                    applyCallCount += 1
                    capturedSpecs = specs
                    return (true, nil)
                }
            },
            errorFactory: testFlutterErrorFactory
        )

        let specs: [[String: Any]] = [
            ["type": "lut", "parameters": ["intensity": 0.8]],
            ["type": "beauty", "parameters": ["intensity": 0.5]],
            ["type": "segmentation"]
        ]

        var resultCallCount = 0
        var receivedResult: Any? = "not_set"

        handler.handle(args: ["textureId": 10, "filters": specs]) { res in
            resultCallCount += 1
            receivedResult = res
        }

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertNil(receivedResult)
        XCTAssertEqual(applyCallCount, 1)
        XCTAssertEqual(capturedSpecs?.count, 3)
        XCTAssertEqual(capturedSpecs?[0]["type"] as? String, "lut")
        XCTAssertEqual(capturedSpecs?[1]["type"] as? String, "beauty")
        XCTAssertEqual(capturedSpecs?[2]["type"] as? String, "segmentation")
    }

    func test15_onMainInvocation_returnsExactlyOnceOnMain() {
        let handler = VGTimelineLiveControlHandler(
            targetProvider: {
                return VGTimelineLiveFilterTarget(textureId: 10) { _ in (true, nil) }
            },
            errorFactory: testFlutterErrorFactory
        )

        XCTAssertTrue(Thread.isMainThread)

        var resultCallCount = 0
        var wasOnMain = false

        handler.handle(args: ["textureId": 10, "filters": []]) { res in
            resultCallCount += 1
            wasOnMain = Thread.isMainThread
        }

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertTrue(wasOnMain)
    }

    func test16_offMainInvocation_dispatchesExactlyOnceAndReturnsExactlyOnceOnMain() {
        var providerOnMain = false
        var providerCallCount = 0
        let handler = VGTimelineLiveControlHandler(
            targetProvider: {
                providerCallCount += 1
                providerOnMain = Thread.isMainThread
                return VGTimelineLiveFilterTarget(textureId: 10) { _ in (true, nil) }
            },
            errorFactory: testFlutterErrorFactory
        )

        let firstResultExpectation = expectation(description: "first result delivered on main")
        let duplicateResultExpectation = expectation(description: "duplicate result delivered")
        duplicateResultExpectation.isInverted = true

        var resultCallCount = 0
        var callbackOnMain = false

        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertFalse(Thread.isMainThread)
            handler.handle(args: ["textureId": 10, "filters": []]) { res in
                resultCallCount += 1
                callbackOnMain = Thread.isMainThread
                if resultCallCount == 1 {
                    firstResultExpectation.fulfill()
                } else {
                    duplicateResultExpectation.fulfill()
                }
            }
        }

        wait(for: [firstResultExpectation, duplicateResultExpectation], timeout: 1.0)

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertEqual(providerCallCount, 1)
        XCTAssertTrue(callbackOnMain, "MethodChannel callback must execute on main thread")
        XCTAssertTrue(providerOnMain, "targetProvider must execute on main thread")
    }

    func test17_eachErrorBranchReturnsExactlyOnce() {
        let handler = VGTimelineLiveControlHandler(
            targetProvider: {
                return VGTimelineLiveFilterTarget(textureId: 10) { _ in (false, "unknown") }
            },
            errorFactory: testFlutterErrorFactory
        )

        let testCases: [[String: Any]?] = [
            nil,                                         // INVALID_ARG missing args
            ["textureId": -1],                           // INVALID_ARG negative
            ["textureId": 10],                           // INVALID_ARG missing filters
            ["textureId": 10, "filters": "invalid"],     // INVALID_ARG bad filters
            ["textureId": 10, "filters": []],            // UNKNOWN_FILTER (from apply returning false)
        ]

        for (idx, testArgs) in testCases.enumerated() {
            var callCount = 0
            handler.handle(args: testArgs) { _ in
                callCount += 1
            }
            XCTAssertEqual(callCount, 1, "Test case index \(idx) did not execute result exactly once")
        }
    }

    func test18_targetProviderAndApplyClosureNotCalledWhenArgumentValidationFails() {
        var providerCallCount = 0
        var applyCallCount = 0

        let handler = VGTimelineLiveControlHandler(
            targetProvider: {
                providerCallCount += 1
                return VGTimelineLiveFilterTarget(textureId: 10) { _ in
                    applyCallCount += 1
                    return (true, nil)
                }
            },
            errorFactory: testFlutterErrorFactory
        )

        let invalidArgsList: [[String: Any]?] = [
            nil,
            ["textureId": -1],
            ["textureId": "abc"],
            ["textureId": true],
            ["textureId": NSNumber(value: true)],
            ["textureId": Float(1.0)],
            ["textureId": Double(2.5)],
            ["textureId": NSNumber(value: UInt64.max)],
            ["textureId": 10], // missing filters
        ]

        for invalidArgs in invalidArgsList {
            handler.handle(args: invalidArgs) { _ in }
        }

        XCTAssertEqual(providerCallCount, 0, "targetProvider must not be called when argument validation fails")
        XCTAssertEqual(applyCallCount, 0, "apply closure must not be called when argument validation fails")
    }

    func test19_nsNumberInt32ZeroAndOneAndInt64AcceptedAndBoolRejected() {
        // 1. NSNumber(value: Int32(0)) accepted for target textureId 0
        var providerCallCount = 0
        var applyCallCount = 0
        var handler = VGTimelineLiveControlHandler(
            targetProvider: {
                providerCallCount += 1
                return VGTimelineLiveFilterTarget(textureId: 0) { _ in
                    applyCallCount += 1
                    return (true, nil)
                }
            },
            errorFactory: testFlutterErrorFactory
        )

        var resultCallCount = 0
        var receivedResult: Any? = "not_set"
        handler.handle(args: ["textureId": NSNumber(value: Int32(0)), "filters": []]) { res in
            resultCallCount += 1
            receivedResult = res
        }

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertNil(receivedResult)
        XCTAssertEqual(providerCallCount, 1)
        XCTAssertEqual(applyCallCount, 1)

        // 2. NSNumber(value: Int32(1)) accepted for target textureId 1
        providerCallCount = 0
        applyCallCount = 0
        handler = VGTimelineLiveControlHandler(
            targetProvider: {
                providerCallCount += 1
                return VGTimelineLiveFilterTarget(textureId: 1) { _ in
                    applyCallCount += 1
                    return (true, nil)
                }
            },
            errorFactory: testFlutterErrorFactory
        )

        resultCallCount = 0
        receivedResult = "not_set"
        handler.handle(args: ["textureId": NSNumber(value: Int32(1)), "filters": []]) { res in
            resultCallCount += 1
            receivedResult = res
        }

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertNil(receivedResult)
        XCTAssertEqual(providerCallCount, 1)
        XCTAssertEqual(applyCallCount, 1)

        // 3. Int64(1) accepted for target textureId 1
        providerCallCount = 0
        applyCallCount = 0
        resultCallCount = 0
        receivedResult = "not_set"
        handler.handle(args: ["textureId": Int64(1), "filters": []]) { res in
            resultCallCount += 1
            receivedResult = res
        }

        XCTAssertEqual(resultCallCount, 1)
        XCTAssertNil(receivedResult)
        XCTAssertEqual(providerCallCount, 1)
        XCTAssertEqual(applyCallCount, 1)

        // 4. NSNumber(value: true) and NSNumber(value: false) rejected as INVALID_ARG
        providerCallCount = 0
        applyCallCount = 0
        let boolCases: [NSNumber] = [NSNumber(value: true), NSNumber(value: false)]
        for boolVal in boolCases {
            var callCount = 0
            var errRes: Any? = nil
            handler.handle(args: ["textureId": boolVal, "filters": []]) { res in
                callCount += 1
                errRes = res
            }
            XCTAssertEqual(callCount, 1)
            XCTAssertEqual(errorCode(errRes), "INVALID_ARG")
        }
        XCTAssertEqual(providerCallCount, 0, "targetProvider must not be called for NSNumber bool values")
        XCTAssertEqual(applyCallCount, 0, "apply closure must not be called for NSNumber bool values")
    }
}

