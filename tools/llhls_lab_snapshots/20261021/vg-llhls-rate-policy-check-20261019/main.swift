// main.swift
// Standalone Foundation-only verification of VGHLSRatePolicy decisions.

import Foundation

func makeSample(
    mono: Double,
    wall: Double? = nil,
    ageMs: Int? = 2370,
    bufferMs: Int? = 1000,
    isReady: Bool = true,
    isFailed: Bool = false,
    isPlaying: Bool = true,
    isWaiting: Bool = false,
    stallCount: Int = 0
) -> VGHLSRateSample {
    return VGHLSRateSample(
        monotonicSeconds: mono,
        wallSeconds: wall ?? (1_700_000_000.0 + mono),
        ageMs: ageMs,
        contiguousForwardBufferMs: bufferMs,
        isReady: isReady,
        isFailed: isFailed,
        isPlaying: isPlaying,
        isWaiting: isWaiting,
        stallCount: stallCount
    )
}

// Case 1: At 250 ms intervals, age=2370, buffer=1000, ready/playing, stalls=0:
//         no entry before 2 seconds; entry at 2 seconds.
func testCase1() -> Bool {
    var policy = VGHLSRatePolicy()
    var enteredBefore2s = false
    var enteredAt2s = false

    for i in 0..<8 {
        let t = Double(i) * 0.25 // 0.00, 0.25, 0.50, 0.75, 1.00, 1.25, 1.50, 1.75
        let sample = makeSample(mono: t, ageMs: 2370, bufferMs: 1000)
        let d = policy.tick(sample)
        if d == .enterAccelerated {
            enteredBefore2s = true
        }
    }

    let sample2 = makeSample(mono: 2.0, ageMs: 2370, bufferMs: 1000)
    let d2 = policy.tick(sample2)
    if d2 == .enterAccelerated {
        enteredAt2s = true
    }

    return !enteredBefore2s && enteredAt2s
}

// Case 2: After acknowledging entry, age=1480: normal exit respects filtering
//         and the two-second write spacing.
func testCase2() -> Bool {
    var policy = VGHLSRatePolicy()

    for i in 0..<8 {
        let t = Double(i) * 0.25
        _ = policy.tick(makeSample(mono: t, ageMs: 2370, bufferMs: 1000))
    }
    let dEntry = policy.tick(makeSample(mono: 2.0, ageMs: 2370, bufferMs: 1000))
    guard dEntry == .enterAccelerated else { return false }

    policy.didEnterAccelerated(atMonotonicSeconds: 2.0)
    guard policy.mode == .accelerating else { return false }

    // Ticks at 2.25 and 2.50: median window not yet <= 1500
    let d2_25 = policy.tick(makeSample(mono: 2.25, ageMs: 1480, bufferMs: 1000))
    guard d2_25 == .none else { return false }

    let d2_50 = policy.tick(makeSample(mono: 2.50, ageMs: 1480, bufferMs: 1000))
    guard d2_50 == .none else { return false }

    // Tick at 2.75: median is 1480 <= 1500, but write spacing (0.75s < 2.0s) blocks exit
    let d2_75 = policy.tick(makeSample(mono: 2.75, ageMs: 1480, bufferMs: 1000))
    guard d2_75 == .none else { return false }

    // Intermediate ticks blocked by write spacing
    for i in 12...15 {
        let t = Double(i) * 0.25 // 3.00, 3.25, 3.50, 3.75
        let d = policy.tick(makeSample(mono: t, ageMs: 1480, bufferMs: 1000))
        guard d == .none else { return false }
    }

    // Tick at 4.00s: 4.00 - 2.00 = 2.00 >= 2.0s, normal exit allowed
    let d4_00 = policy.tick(makeSample(mono: 4.00, ageMs: 1480, bufferMs: 1000))
    guard d4_00 == .exitAccelerated(reason: "target_reached", safety: false) else { return false }

    return true
}

// Case 3: Buffer 749 prevents entry; 750 permits it after other gates pass.
func testCase3() -> Bool {
    var policy = VGHLSRatePolicy()

    for i in 0..<8 {
        let t = Double(i) * 0.25
        _ = policy.tick(makeSample(mono: t, ageMs: 2370, bufferMs: 749))
    }

    let d749_at_2s = policy.tick(makeSample(mono: 2.00, ageMs: 2370, bufferMs: 749))
    guard d749_at_2s == .none else { return false }

    let d749_at_2_25 = policy.tick(makeSample(mono: 2.25, ageMs: 2370, bufferMs: 749))
    guard d749_at_2_25 == .none else { return false }

    let d750_at_2_50 = policy.tick(makeSample(mono: 2.50, ageMs: 2370, bufferMs: 750))
    guard d750_at_2_50 == .enterAccelerated else { return false }

    return true
}

// Case 4: Buffer 249 immediately requests a safety exit; 250 alone does not.
func testCase4() -> Bool {
    var policy = VGHLSRatePolicy()

    for i in 0..<8 {
        let t = Double(i) * 0.25
        _ = policy.tick(makeSample(mono: t, ageMs: 2370, bufferMs: 1000))
    }
    let dEntry = policy.tick(makeSample(mono: 2.0, ageMs: 2370, bufferMs: 1000))
    guard dEntry == .enterAccelerated else { return false }
    policy.didEnterAccelerated(atMonotonicSeconds: 2.0)
    guard policy.mode == .accelerating else { return false }

    // Buffer 250 does not request safety exit
    let d250 = policy.tick(makeSample(mono: 2.25, ageMs: 2370, bufferMs: 250))
    guard d250 == .none else { return false }

    // Buffer 249 immediately requests safety exit
    let d249 = policy.tick(makeSample(mono: 2.50, ageMs: 2370, bufferMs: 249))
    guard d249 == .exitAccelerated(reason: "buffer_low", safety: true) else { return false }

    return true
}

// Case 5: Waiting, not-ready, increased stalls, invalid ages/buffers, clock
//         steps and age discontinuities bypass normal exit spacing.
func testCase5() -> Bool {
    func createAcceleratingPolicy() -> VGHLSRatePolicy {
        var p = VGHLSRatePolicy()
        for i in 0..<8 {
            let t = Double(i) * 0.25
            _ = p.tick(makeSample(mono: t, ageMs: 2370, bufferMs: 1000))
        }
        _ = p.tick(makeSample(mono: 2.0, ageMs: 2370, bufferMs: 1000))
        p.didEnterAccelerated(atMonotonicSeconds: 2.0)
        return p
    }

    // At t=2.10s, write spacing (0.10s < 2.0s) would block normal exit.
    // Safety conditions bypass write spacing.

    // 1. Waiting
    var p1 = createAcceleratingPolicy()
    let d1 = p1.tick(makeSample(mono: 2.10, isPlaying: false, isWaiting: true))
    guard d1 == .exitAccelerated(reason: "waiting", safety: true) else { return false }

    // 2. Not-ready
    var p2 = createAcceleratingPolicy()
    let d2 = p2.tick(makeSample(mono: 2.10, isReady: false))
    guard d2 == .exitAccelerated(reason: "not_ready", safety: true) else { return false }

    // 3. Increased stalls
    var p3 = createAcceleratingPolicy()
    let d3 = p3.tick(makeSample(mono: 2.10, stallCount: 1))
    guard d3 == .exitAccelerated(reason: "stall_count_increased", safety: true) else { return false }

    // 4. Invalid age: nil
    var p4 = createAcceleratingPolicy()
    let d4 = p4.tick(makeSample(mono: 2.10, ageMs: nil))
    guard d4 == .exitAccelerated(reason: "invalid_age", safety: true) else { return false }

    // 5. Invalid age: negative
    var p5 = createAcceleratingPolicy()
    let d5 = p5.tick(makeSample(mono: 2.10, ageMs: -1))
    guard d5 == .exitAccelerated(reason: "invalid_age", safety: true) else { return false }

    // 6. Invalid age: > maxValidAgeMs (30000)
    var p6 = createAcceleratingPolicy()
    let d6 = p6.tick(makeSample(mono: 2.10, ageMs: 30001))
    guard d6 == .exitAccelerated(reason: "invalid_age", safety: true) else { return false }

    // 7. Invalid buffer: nil
    var p7 = createAcceleratingPolicy()
    let d7 = p7.tick(makeSample(mono: 2.10, bufferMs: nil))
    guard d7 == .exitAccelerated(reason: "invalid_buffer", safety: true) else { return false }

    // 8. Invalid buffer: negative
    var p8 = createAcceleratingPolicy()
    let d8 = p8.tick(makeSample(mono: 2.10, bufferMs: -1))
    guard d8 == .exitAccelerated(reason: "invalid_buffer", safety: true) else { return false }

    // 9. Clock step: elapsedWall vs elapsedMono > 0.25s
    var p9 = createAcceleratingPolicy()
    let d9 = p9.tick(makeSample(mono: 2.10, wall: 1_700_000_003.0))
    guard d9 == .exitAccelerated(reason: "clock_step", safety: true) else { return false }

    // 10. Discontinuity: consecutive valid ages diff > 1000ms
    var p10 = createAcceleratingPolicy()
    let d10 = p10.tick(makeSample(mono: 2.10, ageMs: 3500))
    guard d10 == .exitAccelerated(reason: "age_discontinuity", safety: true) else { return false }

    return true
}

// Case 6: Safety exit, declined entry and time jump require fresh settling.
func testCase6() -> Bool {
    // 6a: Safety exit requires fresh settling
    var pA = VGHLSRatePolicy()
    for i in 0..<8 {
        let t = Double(i) * 0.25
        _ = pA.tick(makeSample(mono: t, ageMs: 2370, bufferMs: 1000))
    }
    _ = pA.tick(makeSample(mono: 2.0, ageMs: 2370, bufferMs: 1000))
    pA.didEnterAccelerated(atMonotonicSeconds: 2.0)

    let dSafe = pA.tick(makeSample(mono: 2.50, ageMs: 2370, bufferMs: 200))
    guard dSafe == .exitAccelerated(reason: "buffer_low", safety: true) else { return false }
    pA.didExitAccelerated(atMonotonicSeconds: 2.50, safety: true)
    guard pA.mode == .normal else { return false }

    for i in 11...17 {
        let t = Double(i) * 0.25 // 2.75 to 4.25
        let d = pA.tick(makeSample(mono: t, ageMs: 2370, bufferMs: 1000))
        guard d == .none else { return false }
    }
    let dReenterA = pA.tick(makeSample(mono: 4.50, ageMs: 2370, bufferMs: 1000))
    guard dReenterA == .enterAccelerated else { return false }

    // 6b: Declined entry requires fresh settling
    var pB = VGHLSRatePolicy()
    for i in 0..<8 {
        let t = Double(i) * 0.25
        _ = pB.tick(makeSample(mono: t, ageMs: 2370, bufferMs: 1000))
    }
    let dEntryB = pB.tick(makeSample(mono: 2.0, ageMs: 2370, bufferMs: 1000))
    guard dEntryB == .enterAccelerated else { return false }
    pB.didDeclineEntry(atMonotonicSeconds: 2.0)
    guard pB.mode == .normal else { return false }

    for i in 9...15 {
        let t = Double(i) * 0.25 // 2.25 to 3.75
        let d = pB.tick(makeSample(mono: t, ageMs: 2370, bufferMs: 1000))
        guard d == .none else { return false }
    }
    let dReenterB = pB.tick(makeSample(mono: 4.00, ageMs: 2370, bufferMs: 1000))
    guard dReenterB == .enterAccelerated else { return false }

    // 6c: Time jump requires fresh settling
    var pC = VGHLSRatePolicy()
    for i in 0..<8 {
        let t = Double(i) * 0.25
        _ = pC.tick(makeSample(mono: t, ageMs: 2370, bufferMs: 1000))
    }
    let dJump = pC.noteTimeJump(atMonotonicSeconds: 2.00)
    guard dJump == .none else { return false }
    guard pC.mode == .normal else { return false }

    for i in 9...15 {
        let t = Double(i) * 0.25 // 2.25 to 3.75
        let d = pC.tick(makeSample(mono: t, ageMs: 2370, bufferMs: 1000))
        guard d == .none else { return false }
    }
    let dReenterC = pC.tick(makeSample(mono: 4.00, ageMs: 2370, bufferMs: 1000))
    guard dReenterC == .enterAccelerated else { return false }

    return true
}

// Case 7: Failed playback disables irreversibly; subsequent ticks return none.
func testCase7() -> Bool {
    var policy = VGHLSRatePolicy()

    _ = policy.tick(makeSample(mono: 0.0, ageMs: 2370, bufferMs: 1000))

    let dFail = policy.tick(makeSample(mono: 0.25, isFailed: true))
    guard dFail == .disable(reason: "playback_failed") else { return false }
    guard policy.isDisabled else { return false }
    guard policy.mode == .disabled else { return false }
    guard policy.disabledReason == "playback_failed" else { return false }

    for i in 2...10 {
        let t = Double(i) * 0.25
        let d = policy.tick(makeSample(mono: t, ageMs: 2370, bufferMs: 1000, isReady: true, isFailed: false, isPlaying: true))
        guard d == .none else { return false }
    }

    let dJump = policy.noteTimeJump(atMonotonicSeconds: 3.0)
    guard dJump == .none else { return false }

    guard policy.isDisabled else { return false }
    guard policy.mode == .disabled else { return false }
    return true
}

// Case 8: A decision alone does not acknowledge an applied rate change.
func testCase8() -> Bool {
    var policy = VGHLSRatePolicy()

    for i in 0..<8 {
        let t = Double(i) * 0.25
        _ = policy.tick(makeSample(mono: t, ageMs: 2370, bufferMs: 1000))
    }
    let d1 = policy.tick(makeSample(mono: 2.0, ageMs: 2370, bufferMs: 1000))
    guard d1 == .enterAccelerated else { return false }

    // Mode remains .normal before acknowledgment
    guard policy.mode == .normal else { return false }

    let d2 = policy.tick(makeSample(mono: 2.25, ageMs: 2370, bufferMs: 1000))
    guard d2 == .enterAccelerated else { return false }
    guard policy.mode == .normal else { return false }

    // Acknowledge entry
    policy.didEnterAccelerated(atMonotonicSeconds: 2.25)
    guard policy.mode == .accelerating else { return false }

    // Advance to normal exit
    for i in 10...17 {
        let t = Double(i) * 0.25
        _ = policy.tick(makeSample(mono: t, ageMs: 1480, bufferMs: 1000))
    }
    let dExit = policy.tick(makeSample(mono: 4.50, ageMs: 1480, bufferMs: 1000))
    guard dExit == .exitAccelerated(reason: "target_reached", safety: false) else { return false }

    // Mode remains .accelerating before acknowledgment
    guard policy.mode == .accelerating else { return false }

    // Acknowledge exit
    policy.didExitAccelerated(atMonotonicSeconds: 4.50, safety: false)
    guard policy.mode == .normal else { return false }

    return true
}

// ── Runner ───────────────────────────────────────────────────────────────────

let cases: [(name: String, run: () -> Bool)] = [
    ("entry_timing_2s",                     testCase1),
    ("normal_exit_filtering_and_spacing",   testCase2),
    ("buffer_entry_threshold_749_vs_750",   testCase3),
    ("buffer_safety_exit_249_vs_250",       testCase4),
    ("safety_conditions_bypass_spacing",    testCase5),
    ("fresh_settle_after_safety_decline_jump", testCase6),
    ("playback_failed_irreversible_disable", testCase7),
    ("decision_alone_does_not_acknowledge", testCase8)
]

var failedCount = 0
for test in cases {
    let passed = test.run()
    if passed {
        print("\(test.name): PASS")
    } else {
        print("\(test.name): FAIL")
        failedCount += 1
    }
}

if failedCount > 0 {
    print("TOTAL: \(cases.count - failedCount)/\(cases.count) passed (\(failedCount) failed)")
    exit(1)
} else {
    print("TOTAL: \(cases.count)/\(cases.count) passed")
    exit(0)
}
