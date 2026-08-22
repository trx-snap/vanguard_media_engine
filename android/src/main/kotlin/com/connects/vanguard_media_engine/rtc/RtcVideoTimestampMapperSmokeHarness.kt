package com.connects.vanguard_media_engine.rtc

/**
 * Diagnostic smoke harness validating [RtcVideoTimestampMapper] deterministic timestamp mapping,
 * non-monotonic correction behavior, baseline reset handling, and negative PTS argument rejection.
 *
 * ## Verification Invariants
 * - **Zero Room / Audio Dependencies**: Operates strictly within the video domain without audio or room coupling.
 * - **Deterministic Verification**: Tests synthetic sequences with duplicate and out-of-order PTS values.
 * - **Mechanical Safety**: Catches unexpected errors and returns structured result map with `pass=false`.
 */
object RtcVideoTimestampMapperSmokeHarness {

    /**
     * Executes the [RtcVideoTimestampMapper] smoke verification suite.
     *
     * @return Map containing test verdict `pass` (Boolean), diagnostic `raw` status string, and snapshot telemetry.
     */
    fun run(): Map<String, Any?> {
        try {
            val mapper = RtcVideoTimestampMapper(baseTimestampNs = 1_000_000_000L)

            // 1. Map sequence with duplicate and out-of-order PTS: [1000, 2000, 2000, 1500, 4000]
            val ptsSequence = listOf(1000L, 2000L, 2000L, 1500L, 4000L)
            val mappedSequence = mutableListOf<Long>()
            for (pts in ptsSequence) {
                mappedSequence.add(mapper.mapPtsUs(pts))
            }

            // Expected values:
            // mapped[0] = 1_000_000_000L (first map sets basePtsUs=1000, returns baseTimestampNs)
            // mapped[1] = 1_001_000_000L (deltaUs = 1000 -> +1_000_000 ns)
            // mapped[2] = 1_001_000_001L (duplicate PTS coerced to last + 1)
            // mapped[3] = 1_001_000_002L (out-of-order PTS coerced to last + 1)
            // mapped[4] = 1_003_000_000L (deltaUs = 3000 -> +3_000_000 ns)
            val expectedFirst = 1_000_000_000L
            val expectedSecond = 1_001_000_000L
            val expectedThird = 1_001_000_001L
            val expectedFourth = 1_001_000_002L
            val expectedFifth = 1_003_000_000L

            var isMonotonic = true
            for (i in 1 until mappedSequence.size) {
                if (mappedSequence[i] <= mappedSequence[i - 1]) {
                    isMonotonic = false
                }
            }

            val snapAfterSequence = mapper.snapshot()
            val corrections = (snapAfterSequence["droppedNonMonotonicCorrections"] as? Number)?.toLong() ?: -1L
            val mappedFrames = (snapAfterSequence["mappedFrames"] as? Number)?.toLong() ?: -1L

            val sequencePass = isMonotonic &&
                mappedSequence.size == 5 &&
                mappedSequence[0] == expectedFirst &&
                mappedSequence[1] == expectedSecond &&
                mappedSequence[2] == expectedThird &&
                mappedSequence[3] == expectedFourth &&
                mappedSequence[4] == expectedFifth &&
                corrections >= 2L &&
                mappedFrames == 5L

            // 2. Reset to base 2_000_000_000 and map pts 0
            val resetResult = mapper.reset(2_000_000_000L)
            val resetPass = (resetResult["pass"] == true)
            val mappedAfterReset = mapper.mapPtsUs(0L)
            val expectedAfterReset = 2_000_000_000L
            val resetMapPass = mappedAfterReset == expectedAfterReset

            // 3. Negative PTS rejection
            var negativeRejected = false
            try {
                mapper.mapPtsUs(-1L)
            } catch (_: IllegalArgumentException) {
                negativeRejected = true
            }

            val finalSnapshot = mapper.snapshot()
            val finalCorrections = (finalSnapshot["droppedNonMonotonicCorrections"] as? Number)?.toLong() ?: -1L
            val finalMappedFrames = (finalSnapshot["mappedFrames"] as? Number)?.toLong() ?: -1L

            val overallPass = sequencePass && resetPass && resetMapPass && negativeRejected

            val rawStatus = if (overallPass) {
                "status=OK;mappedFrames=$finalMappedFrames;corrections=$finalCorrections;isMonotonic=$isMonotonic;negativeRejected=$negativeRejected"
            } else {
                "status=TIMESTAMP_MAPPER_VERIFICATION_FAILED;sequencePass=$sequencePass;resetPass=$resetPass;resetMapPass=$resetMapPass;negativeRejected=$negativeRejected;isMonotonic=$isMonotonic;corrections=$corrections"
            }

            return mapOf(
                "pass" to overallPass,
                "raw" to rawStatus,
                "snapshot" to finalSnapshot,
                "mappedSequence" to mappedSequence,
                "mappedAfterReset" to mappedAfterReset,
                "negativeRejected" to negativeRejected,
                "sequencePass" to sequencePass,
                "resetPass" to resetPass,
                "resetMapPass" to resetMapPass,
                "isMonotonic" to isMonotonic,
            )
        } catch (t: Throwable) {
            return mapOf(
                "pass" to false,
                "raw" to "status=UNEXPECTED_ERROR;reason=${t.message}",
            )
        }
    }
}
