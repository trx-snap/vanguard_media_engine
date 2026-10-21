import Foundation
import CoreMedia

// Required monotonic clock function for linking with PrecisionStartup
func getMonotonicMs() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) * 1000 + UInt64(ts.tv_nsec) / 1_000_000
}

func makeRange(start: Double, end: Double) -> CMTimeRange {
    let startTicks = Int64((start * 1000).rounded())
    let endTicks = Int64((end * 1000).rounded())
    let s = CMTime(value: startTicks, timescale: 1000)
    let d = CMTime(value: endTicks - startTicks, timescale: 1000)
    return CMTimeRange(start: s, duration: d)
}

func runTests() {
    fputs("[Test] Testing REAL PrecisionStartup.hasLoadedCoverage static predicate...\n", stderr)

    // --- Retained 350ms Tests (default requiredAheadSeconds = 0.350) ---

    // 1. Exact 350ms boundary (start = 10.0, end = 10.350, target = 10.0) -> must PASS
    let rExact = makeRange(start: 10.0, end: 10.350)
    assert(
        PrecisionStartup.hasLoadedCoverage(targetSeconds: 10.0, ranges: [rExact]) == true,
        "Exact 350ms boundary must be true"
    )

    // 2. 349ms failure (start = 10.0, end = 10.349, target = 10.0) -> must FAIL
    let r349 = makeRange(start: 10.0, end: 10.349)
    assert(
        PrecisionStartup.hasLoadedCoverage(targetSeconds: 10.0, ranges: [r349]) == false,
        "349ms forward coverage must be false"
    )

    // 3. Holes: ranges do not individually contain target..target+0.350, even if combined
    // [10.0 .. 10.200] and [10.201 .. 10.500] -> hole/gap at 10.200..10.201
    let rHole1 = makeRange(start: 10.0, end: 10.200)
    let rHole2 = makeRange(start: 10.201, end: 10.500)
    assert(
        PrecisionStartup.hasLoadedCoverage(targetSeconds: 10.0, ranges: [rHole1, rHole2]) == false,
        "Holes between disjoint ranges must not be joined"
    )

    // 4. Disjoint later containing range: target is contained in a later range in the array
    let rDisjointEarly = makeRange(start: 0.0, end: 5.0)
    let rDisjointLate = makeRange(start: 10.0, end: 20.0)
    assert(
        PrecisionStartup.hasLoadedCoverage(targetSeconds: 12.0, ranges: [rDisjointEarly, rDisjointLate]) == true,
        "Disjoint later containing range must satisfy coverage"
    )

    // 5. Invalid / negative / nonfinite ranges / target
    // Negative target
    assert(
        PrecisionStartup.hasLoadedCoverage(targetSeconds: -1.0, ranges: [rDisjointLate]) == false,
        "Negative target must fail"
    )
    // Nonfinite target (NaN, Infinity)
    assert(
        PrecisionStartup.hasLoadedCoverage(targetSeconds: Double.nan, ranges: [rDisjointLate]) == false,
        "NaN target must fail"
    )
    assert(
        PrecisionStartup.hasLoadedCoverage(targetSeconds: Double.infinity, ranges: [rDisjointLate]) == false,
        "Infinite target must fail"
    )

    // Empty ranges
    assert(
        PrecisionStartup.hasLoadedCoverage(targetSeconds: 10.0, ranges: []) == false,
        "Empty ranges must fail"
    )

    // Negative range start
    let rBadStart = CMTimeRange(
        start: CMTime(seconds: -5.0, preferredTimescale: 1000),
        duration: CMTime(seconds: 10.0, preferredTimescale: 1000)
    )
    assert(
        PrecisionStartup.hasLoadedCoverage(targetSeconds: 1.0, ranges: [rBadStart]) == false,
        "Negative start range must fail"
    )

    // Zero duration range
    let rZeroDur = CMTimeRange(
        start: CMTime(seconds: 10.0, preferredTimescale: 1000),
        duration: CMTime.zero
    )
    assert(
        PrecisionStartup.hasLoadedCoverage(targetSeconds: 10.0, ranges: [rZeroDur]) == false,
        "Zero duration range must fail"
    )

    // Indefinite/invalid duration range
    let rIndefDur = CMTimeRange(
        start: CMTime(seconds: 10.0, preferredTimescale: 1000),
        duration: CMTime.indefinite
    )
    assert(
        PrecisionStartup.hasLoadedCoverage(targetSeconds: 10.0, ranges: [rIndefDur]) == false,
        "Indefinite range duration must fail"
    )

    // --- Warm 499ms vs 500ms Predicate Tests (requiredAheadSeconds = 0.500) ---

    // Exact 500ms boundary (start = 10.0, end = 10.500, target = 10.0) -> must PASS
    let rExact500 = makeRange(start: 10.0, end: 10.500)
    assert(
        PrecisionStartup.hasLoadedCoverage(targetSeconds: 10.0, ranges: [rExact500], requiredAheadSeconds: 0.500) == true,
        "Exact 500ms boundary must be true"
    )

    // 499ms failure (start = 10.0, end = 10.499, target = 10.0) -> must FAIL
    let r499 = makeRange(start: 10.0, end: 10.499)
    assert(
        PrecisionStartup.hasLoadedCoverage(targetSeconds: 10.0, ranges: [r499], requiredAheadSeconds: 0.500) == false,
        "499ms forward coverage must be false for 500ms requirement"
    )

    // --- Invalid requiredAhead Parameter Validation ---

    assert(
        PrecisionStartup.hasLoadedCoverage(targetSeconds: 10.0, ranges: [rExact500], requiredAheadSeconds: 0.0) == false,
        "Zero requiredAhead must fail"
    )
    assert(
        PrecisionStartup.hasLoadedCoverage(targetSeconds: 10.0, ranges: [rExact500], requiredAheadSeconds: -0.350) == false,
        "Negative requiredAhead must fail"
    )
    assert(
        PrecisionStartup.hasLoadedCoverage(targetSeconds: 10.0, ranges: [rExact500], requiredAheadSeconds: Double.nan) == false,
        "NaN requiredAhead must fail"
    )
    assert(
        PrecisionStartup.hasLoadedCoverage(targetSeconds: 10.0, ranges: [rExact500], requiredAheadSeconds: Double.infinity) == false,
        "Infinite requiredAhead must fail"
    )

    // --- One-Range & Disjoint Semantics ---

    // Two abutting ranges [10.0 .. 10.250] and [10.250 .. 10.500] covering 500ms across two ranges
    // ONE range must cover target..target+0.500 entirely; joining across ranges is forbidden
    let rSplit1 = makeRange(start: 10.0, end: 10.250)
    let rSplit2 = makeRange(start: 10.250, end: 10.500)
    assert(
        PrecisionStartup.hasLoadedCoverage(targetSeconds: 10.0, ranges: [rSplit1, rSplit2], requiredAheadSeconds: 0.500) == false,
        "Coverage split across two abutting ranges must fail one-range requirement"
    )

    // Disjoint earlier range with subsequent range satisfying 500ms
    let rEarlier = makeRange(start: 0.0, end: 5.0)
    let rCovering = makeRange(start: 10.0, end: 10.600)
    assert(
        PrecisionStartup.hasLoadedCoverage(targetSeconds: 10.0, ranges: [rEarlier, rCovering], requiredAheadSeconds: 0.500) == true,
        "Coverage satisfied by single range in multi-range list must succeed"
    )

    // --- Offline Trace Replay: Hypothetical Warming with 259ms Deficit ---
    // Verified runtime evidence C/results/startup_06/probe.jsonl:
    // target = 25.711667849, loaded range = [24.464 .. 25.970988889] -> 259ms ahead
    let rTrace06 = makeRange(start: 24.464, end: 25.970988889)
    let target06 = 25.711667849
    let ahead06 = 25.970988889 - target06 // ~0.25932s (259ms)
    assert(ahead06 < 0.500, "Trace 06 ahead must be < 500ms")
    let canPause06 = PrecisionStartup.hasLoadedCoverage(targetSeconds: target06, ranges: [rTrace06], requiredAheadSeconds: 0.500)
    assert(
        canPause06 == false,
        "Offline replay 06: 259ms ahead cannot pause under 500ms warming gate"
    )

    // Verified runtime evidence C/results/startup_08/probe.jsonl:
    // target = 25.675641991, loaded range = [23.984 .. 25.934770833] -> 259ms ahead
    let rTrace08 = makeRange(start: 23.984, end: 25.934770833)
    let target08 = 25.675641991
    let ahead08 = 25.934770833 - target08 // ~0.25913s (259ms)
    assert(ahead08 < 0.500, "Trace 08 ahead must be < 500ms")
    let canPause08 = PrecisionStartup.hasLoadedCoverage(targetSeconds: target08, ranges: [rTrace08], requiredAheadSeconds: 0.500)
    assert(
        canPause08 == false,
        "Offline replay 08: 259ms ahead cannot pause under 500ms warming gate"
    )

    // Offline trace replay: With 500ms forward buffer satisfied (e.g. loaded range up to 26.250), gate allows pause
    let rTraceValid = makeRange(start: 24.464, end: 26.250)
    let canPauseValid = PrecisionStartup.hasLoadedCoverage(targetSeconds: target06, ranges: [rTraceValid], requiredAheadSeconds: 0.500)
    assert(
        canPauseValid == true,
        "Offline replay: 500ms+ ahead allows warming pause"
    )

    fputs("[Test] All static coverage predicate and offline replay assertions PASSED.\n", stderr)
}

runTests()
