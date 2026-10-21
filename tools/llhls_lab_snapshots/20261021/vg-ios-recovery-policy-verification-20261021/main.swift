import Foundation

func assertNamed(_ condition: Bool, _ testName: String, _ detail: String = "") {
    if !condition {
        fputs("[FAIL] \(testName): \(detail)\n", stderr)
        exit(1)
    }
}

func runTest(_ name: String, _ block: () -> Void) {
    block()
    print("[PASS] \(name)")
}

// 1. Ineligible policy never aligns/rebuilds; Play remains ordinary.
runTest("testIneligiblePolicyNeverAlignsOrRebuilds") {
    var p = VGHLSRecoveryPolicy(eligible: false)
    assertNamed(p.isDisabled, "testIneligiblePolicyNeverAlignsOrRebuilds", "should be disabled")
    assertNamed(p.phase == .disabled, "testIneligiblePolicyNeverAlignsOrRebuilds", "phase should be .disabled")
    assertNamed(p.phaseName == "disabled", "testIneligiblePolicyNeverAlignsOrRebuilds", "phaseName mismatch")

    let dAlign = p.handle(.beginAlignment(generation: 1))
    assertNamed(dAlign == .none, "testIneligiblePolicyNeverAlignsOrRebuilds", "beginAlignment decision should be .none")
    assertNamed(p.phase == .disabled, "testIneligiblePolicyNeverAlignsOrRebuilds", "phase should stay .disabled")

    let dPlay = p.handle(.explicitPlay(applicationActive: true))
    assertNamed(dPlay == .ordinaryPlay, "testIneligiblePolicyNeverAlignsOrRebuilds", "explicitPlay decision should be .ordinaryPlay")
    assertNamed(p.phase == .disabled, "testIneligiblePolicyNeverAlignsOrRebuilds", "phase should stay .disabled")

    let dPlayInactive = p.handle(.explicitPlay(applicationActive: false))
    assertNamed(dPlayInactive == .ordinaryPlay, "testIneligiblePolicyNeverAlignsOrRebuilds", "inactive explicitPlay should be .ordinaryPlay")

    let dInt = p.handle(.interrupted(reason: .audioInterruption, generation: 1, readyLive: true))
    assertNamed(dInt == .none, "testIneligiblePolicyNeverAlignsOrRebuilds", "interrupted should be .none")
    assertNamed(p.phase == .disabled, "testIneligiblePolicyNeverAlignsOrRebuilds", "phase should stay .disabled")

    assertNamed(p.generation == 1, "testIneligiblePolicyNeverAlignsOrRebuilds", "generation should be 1")
    assertNamed(p.attemptCount == 0, "testIneligiblePolicyNeverAlignsOrRebuilds", "attemptCount should be 0")
    assertNamed(p.alignedCount == 0, "testIneligiblePolicyNeverAlignsOrRebuilds", "alignedCount should be 0")
}

// 2. Initial alignment begins once; duplicate Play is snapshotOnly.
runTest("testInitialAlignmentBeginsOnceDuplicatePlaySnapshotOnly") {
    var p = VGHLSRecoveryPolicy(eligible: true)
    assertNamed(p.phase == .unused, "testInitialAlignmentBeginsOnceDuplicatePlaySnapshotOnly", "initial phase should be .unused")
    assertNamed(!p.initialAttempted, "testInitialAlignmentBeginsOnceDuplicatePlaySnapshotOnly", "initialAttempted should be false")

    let d1 = p.handle(.beginAlignment(generation: 1))
    assertNamed(d1 == .startAlignment(generation: 1), "testInitialAlignmentBeginsOnceDuplicatePlaySnapshotOnly", "first beginAlignment should return .startAlignment(1)")
    assertNamed(p.phase == .aligning(generation: 1), "testInitialAlignmentBeginsOnceDuplicatePlaySnapshotOnly", "phase should be .aligning(1)")
    assertNamed(p.initialAttempted, "testInitialAlignmentBeginsOnceDuplicatePlaySnapshotOnly", "initialAttempted should be true")
    assertNamed(p.initialOutcome == "started", "testInitialAlignmentBeginsOnceDuplicatePlaySnapshotOnly", "initialOutcome should be started")
    assertNamed(p.lastHelperOutcome == "started", "testInitialAlignmentBeginsOnceDuplicatePlaySnapshotOnly", "lastHelperOutcome should be started")

    // Duplicate beginAlignment
    let d2 = p.handle(.beginAlignment(generation: 1))
    assertNamed(d2 == .none, "testInitialAlignmentBeginsOnceDuplicatePlaySnapshotOnly", "duplicate beginAlignment should return .none")
    assertNamed(p.phase == .aligning(generation: 1), "testInitialAlignmentBeginsOnceDuplicatePlaySnapshotOnly", "phase should remain .aligning(1)")

    // Duplicate Play while aligning
    let dPlayActive = p.handle(.explicitPlay(applicationActive: true))
    assertNamed(dPlayActive == .snapshotOnly, "testInitialAlignmentBeginsOnceDuplicatePlaySnapshotOnly", "duplicate active Play should return .snapshotOnly")
    assertNamed(p.phase == .aligning(generation: 1), "testInitialAlignmentBeginsOnceDuplicatePlaySnapshotOnly", "phase should remain .aligning(1)")

    let dPlayInactive = p.handle(.explicitPlay(applicationActive: false))
    assertNamed(dPlayInactive == .snapshotOnly, "testInitialAlignmentBeginsOnceDuplicatePlaySnapshotOnly", "duplicate inactive Play should return .snapshotOnly")
    assertNamed(p.generation == 1 && p.attemptCount == 0 && p.alignedCount == 0, "testInitialAlignmentBeginsOnceDuplicatePlaySnapshotOnly", "counters should remain 0")
}

// 3. Ready/live interruption arms without rebuilding automatically.
runTest("testReadyLiveInterruptionArmsWithoutRebuildingAutomatically") {
    var p = VGHLSRecoveryPolicy(eligible: true)
    _ = p.handle(.beginAlignment(generation: 1))
    let dInt = p.handle(.interrupted(reason: .audioInterruption, generation: 1, readyLive: true))
    assertNamed(dInt == .none, "testReadyLiveInterruptionArmsWithoutRebuildingAutomatically", "interruption must not rebuild automatically")
    assertNamed(p.phase == .armed(generation: 1, reason: .audioInterruption), "testReadyLiveInterruptionArmsWithoutRebuildingAutomatically", "phase should be .armed")
    assertNamed(p.triggerReason == .audioInterruption, "testReadyLiveInterruptionArmsWithoutRebuildingAutomatically", "triggerReason should be audioInterruption")
    assertNamed(p.generation == 1, "testReadyLiveInterruptionArmsWithoutRebuildingAutomatically", "generation should remain 1")
    assertNamed(p.attemptCount == 0, "testReadyLiveInterruptionArmsWithoutRebuildingAutomatically", "attemptCount should remain 0")
    assertNamed(p.lastHelperOutcome == VGHLSStartupEndReason.audioInterruption.rawValue, "testReadyLiveInterruptionArmsWithoutRebuildingAutomatically", "lastHelperOutcome should record audioInterruption")
}

// 4. Inactive Play preserves permission; foreground Play consumes it once.
runTest("testInactivePlayPreservesPermissionForegroundPlayConsumesOnce") {
    var p = VGHLSRecoveryPolicy(eligible: true)
    _ = p.handle(.beginAlignment(generation: 1))
    _ = p.handle(.interrupted(reason: .audioInterruption, generation: 1, readyLive: true))

    // Background/inactive Play
    let dInactive = p.handle(.explicitPlay(applicationActive: false))
    assertNamed(dInactive == .snapshotOnly, "testInactivePlayPreservesPermissionForegroundPlayConsumesOnce", "inactive play should be .snapshotOnly")
    assertNamed(p.phase == .armed(generation: 1, reason: .audioInterruption), "testInactivePlayPreservesPermissionForegroundPlayConsumesOnce", "permission should remain armed")
    assertNamed(p.generation == 1, "testInactivePlayPreservesPermissionForegroundPlayConsumesOnce", "generation should remain 1")
    assertNamed(p.attemptCount == 0, "testInactivePlayPreservesPermissionForegroundPlayConsumesOnce", "attemptCount should remain 0")

    // Foreground Play consumes permission
    let dActive = p.handle(.explicitPlay(applicationActive: true))
    assertNamed(dActive == .reconstruct(generation: 2), "testInactivePlayPreservesPermissionForegroundPlayConsumesOnce", "foreground play should return .reconstruct(2)")
    assertNamed(p.phase == .reconstructing(generation: 2), "testInactivePlayPreservesPermissionForegroundPlayConsumesOnce", "phase should be .reconstructing(2)")
    assertNamed(p.generation == 2, "testInactivePlayPreservesPermissionForegroundPlayConsumesOnce", "generation should advance to 2")
    assertNamed(p.attemptCount == 1, "testInactivePlayPreservesPermissionForegroundPlayConsumesOnce", "attemptCount should be 1")

    // Another Play while reconstructing does not reconstruct again
    let dActive2 = p.handle(.explicitPlay(applicationActive: true))
    assertNamed(dActive2 == .ordinaryPlay, "testInactivePlayPreservesPermissionForegroundPlayConsumesOnce", "second play while reconstructing should be ordinaryPlay")
    assertNamed(p.generation == 2, "testInactivePlayPreservesPermissionForegroundPlayConsumesOnce", "generation should remain 2")
    assertNamed(p.attemptCount == 1, "testInactivePlayPreservesPermissionForegroundPlayConsumesOnce", "attemptCount should remain 1")
}

// 5. Repeated g1->g2->g3 recovery; exact attempt/aligned counts.
runTest("testRepeatedRecoveryGenerationsAndCounters") {
    var p = VGHLSRecoveryPolicy(eligible: true)
    // g1
    assertNamed(p.handle(.beginAlignment(generation: 1)) == .startAlignment(generation: 1), "testRepeatedRecoveryGenerationsAndCounters", "start g1")
    assertNamed(p.handle(.aligned(generation: 1)) == .none, "testRepeatedRecoveryGenerationsAndCounters", "align g1")
    assertNamed(p.phase == .aligned(generation: 1), "testRepeatedRecoveryGenerationsAndCounters", "phase aligned g1")
    assertNamed(p.attemptCount == 0, "testRepeatedRecoveryGenerationsAndCounters", "g1 attempts should be 0")
    assertNamed(p.alignedCount == 0, "testRepeatedRecoveryGenerationsAndCounters", "g1 alignedCount should be 0")

    // interrupt g1
    assertNamed(p.handle(.interrupted(reason: .audioInterruption, generation: 1, readyLive: true)) == .none, "testRepeatedRecoveryGenerationsAndCounters", "interrupt g1")
    assertNamed(p.phase == .armed(generation: 1, reason: .audioInterruption), "testRepeatedRecoveryGenerationsAndCounters", "armed g1")

    // reconstruct g2
    assertNamed(p.handle(.explicitPlay(applicationActive: true)) == .reconstruct(generation: 2), "testRepeatedRecoveryGenerationsAndCounters", "reconstruct g2")
    assertNamed(p.generation == 2, "testRepeatedRecoveryGenerationsAndCounters", "gen should be 2")
    assertNamed(p.attemptCount == 1, "testRepeatedRecoveryGenerationsAndCounters", "attempts should be 1")
    assertNamed(p.alignedCount == 0, "testRepeatedRecoveryGenerationsAndCounters", "alignedCount should be 0")

    assertNamed(p.handle(.beginAlignment(generation: 2)) == .startAlignment(generation: 2), "testRepeatedRecoveryGenerationsAndCounters", "start g2")
    assertNamed(p.phase == .aligning(generation: 2), "testRepeatedRecoveryGenerationsAndCounters", "aligning g2")
    assertNamed(p.handle(.aligned(generation: 2)) == .none, "testRepeatedRecoveryGenerationsAndCounters", "align g2")
    assertNamed(p.phase == .aligned(generation: 2), "testRepeatedRecoveryGenerationsAndCounters", "aligned g2")
    assertNamed(p.alignedCount == 1, "testRepeatedRecoveryGenerationsAndCounters", "alignedCount should be 1")

    // interrupt g2
    assertNamed(p.handle(.interrupted(reason: .externalPause, generation: 2, readyLive: true)) == .none, "testRepeatedRecoveryGenerationsAndCounters", "interrupt g2")
    assertNamed(p.phase == .armed(generation: 2, reason: .externalPause), "testRepeatedRecoveryGenerationsAndCounters", "armed g2")

    // reconstruct g3
    assertNamed(p.handle(.explicitPlay(applicationActive: true)) == .reconstruct(generation: 3), "testRepeatedRecoveryGenerationsAndCounters", "reconstruct g3")
    assertNamed(p.generation == 3, "testRepeatedRecoveryGenerationsAndCounters", "gen should be 3")
    assertNamed(p.attemptCount == 2, "testRepeatedRecoveryGenerationsAndCounters", "attempts should be 2")
    assertNamed(p.alignedCount == 1, "testRepeatedRecoveryGenerationsAndCounters", "alignedCount should be 1")

    assertNamed(p.handle(.beginAlignment(generation: 3)) == .startAlignment(generation: 3), "testRepeatedRecoveryGenerationsAndCounters", "start g3")
    assertNamed(p.handle(.aligned(generation: 3)) == .none, "testRepeatedRecoveryGenerationsAndCounters", "align g3")
    assertNamed(p.phase == .aligned(generation: 3), "testRepeatedRecoveryGenerationsAndCounters", "aligned g3")
    assertNamed(p.alignedCount == 2, "testRepeatedRecoveryGenerationsAndCounters", "alignedCount should be 2")
}

// 6. Duplicate alignment/outcome events do not increment counts.
runTest("testDuplicateAlignmentAndOutcomeEventsDoNotIncrementCounts") {
    var p = VGHLSRecoveryPolicy(eligible: true)
    _ = p.handle(.beginAlignment(generation: 1))
    _ = p.handle(.aligned(generation: 1))
    _ = p.handle(.interrupted(reason: .audioInterruption, generation: 1, readyLive: true))
    _ = p.handle(.explicitPlay(applicationActive: true)) // gen 2
    _ = p.handle(.beginAlignment(generation: 2))
    _ = p.handle(.aligned(generation: 2))
    assertNamed(p.alignedCount == 1, "testDuplicateAlignmentAndOutcomeEventsDoNotIncrementCounts", "alignedCount should be 1")

    // Duplicate aligned event
    let dDup = p.handle(.aligned(generation: 2))
    assertNamed(dDup == .none, "testDuplicateAlignmentAndOutcomeEventsDoNotIncrementCounts", "duplicate aligned should return .none")
    assertNamed(p.alignedCount == 1, "testDuplicateAlignmentAndOutcomeEventsDoNotIncrementCounts", "alignedCount must not increment on duplicate")
    assertNamed(p.phase == .aligned(generation: 2), "testDuplicateAlignmentAndOutcomeEventsDoNotIncrementCounts", "phase remains .aligned(2)")
}

// 7. Stale-generation events leave current state unchanged.
runTest("testStaleGenerationEventsLeaveStateUnchanged") {
    var p = VGHLSRecoveryPolicy(eligible: true)
    _ = p.handle(.beginAlignment(generation: 1))
    _ = p.handle(.interrupted(reason: .audioInterruption, generation: 1, readyLive: true))
    _ = p.handle(.explicitPlay(applicationActive: true)) // gen 2
    _ = p.handle(.beginAlignment(generation: 2)) // phase .aligning(2)
    let outcomeBefore = p.lastHelperOutcome

    assertNamed(p.handle(.beginAlignment(generation: 1)) == .none, "testStaleGenerationEventsLeaveStateUnchanged", "stale beginAlignment")
    assertNamed(p.handle(.interrupted(reason: .audioInterruption, generation: 1, readyLive: true)) == .none, "testStaleGenerationEventsLeaveStateUnchanged", "stale interrupted")
    assertNamed(p.handle(.aligned(generation: 1)) == .none, "testStaleGenerationEventsLeaveStateUnchanged", "stale aligned")
    assertNamed(p.handle(.fallback(reason: .warmTimeout, generation: 1)) == .none, "testStaleGenerationEventsLeaveStateUnchanged", "stale fallback")
    assertNamed(p.handle(.cancelled(reason: "test", generation: 1)) == .none, "testStaleGenerationEventsLeaveStateUnchanged", "stale cancelled")
    assertNamed(p.handle(.failed(generation: 1)) == .none, "testStaleGenerationEventsLeaveStateUnchanged", "stale failed")
    assertNamed(p.handle(.eof(generation: 1)) == .none, "testStaleGenerationEventsLeaveStateUnchanged", "stale eof")

    assertNamed(p.generation == 2, "testStaleGenerationEventsLeaveStateUnchanged", "generation should remain 2")
    assertNamed(p.phase == .aligning(generation: 2), "testStaleGenerationEventsLeaveStateUnchanged", "phase should remain .aligning(2)")
    assertNamed(p.lastHelperOutcome == outcomeBefore, "testStaleGenerationEventsLeaveStateUnchanged", "lastHelperOutcome should remain unchanged")
}

// 8. Interruption before readiness, both initial and rebuilt: enters unarmed fallback; subsequent Play is ordinary, never stuck.
runTest("testInterruptionBeforeReadinessEntersUnarmedFallbackAndSubsequentPlayIsOrdinary") {
    // Initial (g1)
    var p1 = VGHLSRecoveryPolicy(eligible: true)
    _ = p1.handle(.beginAlignment(generation: 1))
    let dInt1 = p1.handle(.interrupted(reason: .audioInterruption, generation: 1, readyLive: false))
    assertNamed(dInt1 == .none, "testInterruptionBeforeReadinessEntersUnarmedFallbackAndSubsequentPlayIsOrdinary", "int before ready return .none")
    assertNamed(p1.phase == .fallback(generation: 1), "testInterruptionBeforeReadinessEntersUnarmedFallbackAndSubsequentPlayIsOrdinary", "phase should be fallback(1)")
    let dPlay1 = p1.handle(.explicitPlay(applicationActive: true))
    assertNamed(dPlay1 == .ordinaryPlay, "testInterruptionBeforeReadinessEntersUnarmedFallbackAndSubsequentPlayIsOrdinary", "subsequent play must be ordinaryPlay, not stuck")
    assertNamed(p1.phase == .fallback(generation: 1), "testInterruptionBeforeReadinessEntersUnarmedFallbackAndSubsequentPlayIsOrdinary", "phase remains fallback(1)")

    // Rebuilt (g2)
    var p2 = VGHLSRecoveryPolicy(eligible: true)
    _ = p2.handle(.beginAlignment(generation: 1))
    _ = p2.handle(.interrupted(reason: .audioInterruption, generation: 1, readyLive: true))
    _ = p2.handle(.explicitPlay(applicationActive: true)) // gen 2
    _ = p2.handle(.beginAlignment(generation: 2))
    let dInt2 = p2.handle(.interrupted(reason: .audioInterruption, generation: 2, readyLive: false))
    assertNamed(dInt2 == .none, "testInterruptionBeforeReadinessEntersUnarmedFallbackAndSubsequentPlayIsOrdinary", "int g2 before ready return .none")
    assertNamed(p2.phase == .fallback(generation: 2), "testInterruptionBeforeReadinessEntersUnarmedFallbackAndSubsequentPlayIsOrdinary", "phase should be fallback(2)")
    let dPlay2 = p2.handle(.explicitPlay(applicationActive: true))
    assertNamed(dPlay2 == .ordinaryPlay, "testInterruptionBeforeReadinessEntersUnarmedFallbackAndSubsequentPlayIsOrdinary", "g2 play must be ordinaryPlay, not stuck")
}

// 9. Every helper end disposition has a terminating transition: fallback, notLive disable, external interruption, native failure.
runTest("testEveryHelperEndDispositionHasTerminatingTransition") {
    // .fallback disposition -> enters .fallback
    var pFallback = VGHLSRecoveryPolicy(eligible: true)
    _ = pFallback.handle(.beginAlignment(generation: 1))
    assertNamed(VGHLSStartupEndReason.warmTimeout.disposition == .fallback, "testEveryHelperEndDispositionHasTerminatingTransition", "warmTimeout is fallback")
    let dFallback = pFallback.handle(.fallback(reason: .warmTimeout, generation: 1))
    assertNamed(dFallback == .none, "testEveryHelperEndDispositionHasTerminatingTransition", "fallback returns .none")
    assertNamed(pFallback.phase == .fallback(generation: 1), "testEveryHelperEndDispositionHasTerminatingTransition", "phase is fallback(1)")

    // .notLive -> enters .disabled
    var pNotLive = VGHLSRecoveryPolicy(eligible: true)
    _ = pNotLive.handle(.beginAlignment(generation: 1))
    assertNamed(VGHLSStartupEndReason.notLive.disposition == .fallback, "testEveryHelperEndDispositionHasTerminatingTransition", "notLive disposition is fallback")
    let dNotLive = pNotLive.handle(.fallback(reason: .notLive, generation: 1))
    assertNamed(dNotLive == .none, "testEveryHelperEndDispositionHasTerminatingTransition", "notLive returns .none")
    assertNamed(pNotLive.phase == .disabled, "testEveryHelperEndDispositionHasTerminatingTransition", "phase is .disabled")
    assertNamed(pNotLive.isDisabled, "testEveryHelperEndDispositionHasTerminatingTransition", "isDisabled is true")

    // .externalInterruption -> enters .armed (when readyLive)
    var pExt = VGHLSRecoveryPolicy(eligible: true)
    _ = pExt.handle(.beginAlignment(generation: 1))
    assertNamed(VGHLSStartupEndReason.playbackStalled.disposition == .externalInterruption, "testEveryHelperEndDispositionHasTerminatingTransition", "playbackStalled is externalInterruption")
    let dExt = pExt.handle(.interrupted(reason: .playbackStalled, generation: 1, readyLive: true))
    assertNamed(dExt == .none, "testEveryHelperEndDispositionHasTerminatingTransition", "ext interruption returns .none")
    assertNamed(pExt.phase == .armed(generation: 1, reason: .playbackStalled), "testEveryHelperEndDispositionHasTerminatingTransition", "phase is .armed")

    // .nativeFailure -> enters .failed
    var pFail = VGHLSRecoveryPolicy(eligible: true)
    _ = pFail.handle(.beginAlignment(generation: 1))
    assertNamed(VGHLSStartupEndReason.nativeFailed.disposition == .nativeFailure, "testEveryHelperEndDispositionHasTerminatingTransition", "nativeFailed is nativeFailure")
    let dFail = pFail.handle(.failed(generation: 1))
    assertNamed(dFail == .none, "testEveryHelperEndDispositionHasTerminatingTransition", "failed returns .none")
    assertNamed(pFail.phase == .failed, "testEveryHelperEndDispositionHasTerminatingTransition", "phase is .failed")
}

// 10. Fallback can arm after a later ready/live interruption.
runTest("testFallbackCanArmAfterLaterReadyLiveInterruption") {
    var p = VGHLSRecoveryPolicy(eligible: true)
    _ = p.handle(.beginAlignment(generation: 1))
    _ = p.handle(.fallback(reason: .warmTimeout, generation: 1))
    assertNamed(p.phase == .fallback(generation: 1), "testFallbackCanArmAfterLaterReadyLiveInterruption", "phase should be fallback(1)")

    let dArm = p.handle(.interrupted(reason: .audioInterruption, generation: 1, readyLive: true))
    assertNamed(dArm == .none, "testFallbackCanArmAfterLaterReadyLiveInterruption", "decision is .none")
    assertNamed(p.phase == .armed(generation: 1, reason: .audioInterruption), "testFallbackCanArmAfterLaterReadyLiveInterruption", "phase should be .armed")
    assertNamed(p.triggerReason == .audioInterruption, "testFallbackCanArmAfterLaterReadyLiveInterruption", "triggerReason is audioInterruption")

    let dRec = p.handle(.explicitPlay(applicationActive: true))
    assertNamed(dRec == .reconstruct(generation: 2), "testFallbackCanArmAfterLaterReadyLiveInterruption", "should reconstruct gen 2")
    assertNamed(p.generation == 2, "testFallbackCanArmAfterLaterReadyLiveInterruption", "generation is 2")
}

// 11. Pause/Seek/Stop disqualification prevents future rebuilding.
runTest("testPauseSeekStopDisqualificationPreventsFutureRebuilding") {
    for reason in ["pause", "seek", "stop"] {
        var p = VGHLSRecoveryPolicy(eligible: true)
        _ = p.handle(.beginAlignment(generation: 1))
        let dDisq = p.handle(.disqualify(reason: reason))
        assertNamed(dDisq == .none, "testPauseSeekStopDisqualificationPreventsFutureRebuilding", "disqualify returns .none")
        assertNamed(p.phase == .disqualified(reason: reason), "testPauseSeekStopDisqualificationPreventsFutureRebuilding", "phase is disqualified(\(reason))")

        // Play is ordinary
        let dPlay = p.handle(.explicitPlay(applicationActive: true))
        assertNamed(dPlay == .ordinaryPlay, "testPauseSeekStopDisqualificationPreventsFutureRebuilding", "play must be ordinaryPlay")
        assertNamed(p.phase == .disqualified(reason: reason), "testPauseSeekStopDisqualificationPreventsFutureRebuilding", "phase remains disqualified")

        // Interruption does not arm
        let dInt = p.handle(.interrupted(reason: .audioInterruption, generation: 1, readyLive: true))
        assertNamed(dInt == .none, "testPauseSeekStopDisqualificationPreventsFutureRebuilding", "interruption returns .none")
        assertNamed(p.phase == .disqualified(reason: reason), "testPauseSeekStopDisqualificationPreventsFutureRebuilding", "interruption cannot arm disqualified")

        // beginAlignment does not start
        let dAlign = p.handle(.beginAlignment(generation: 1))
        assertNamed(dAlign == .none, "testPauseSeekStopDisqualificationPreventsFutureRebuilding", "alignment cannot begin")
    }
}

// 12. Failure and EOF prevent rebuilding; failure may supersede EOF/disqualification.
runTest("testFailureAndEOFPreventRebuildingAndFailureSupersedes") {
    // Failure prevents rebuilding
    var pFail = VGHLSRecoveryPolicy(eligible: true)
    _ = pFail.handle(.beginAlignment(generation: 1))
    _ = pFail.handle(.failed(generation: 1))
    assertNamed(pFail.phase == .failed, "testFailureAndEOFPreventRebuildingAndFailureSupersedes", "phase is .failed")
    assertNamed(pFail.handle(.explicitPlay(applicationActive: true)) == .ordinaryPlay, "testFailureAndEOFPreventRebuildingAndFailureSupersedes", "failed play is ordinaryPlay")
    assertNamed(pFail.handle(.interrupted(reason: .audioInterruption, generation: 1, readyLive: true)) == .none, "testFailureAndEOFPreventRebuildingAndFailureSupersedes", "failed cannot arm")
    assertNamed(pFail.phase == .failed, "testFailureAndEOFPreventRebuildingAndFailureSupersedes", "phase remains .failed")

    // EOF prevents rebuilding
    var pEOF = VGHLSRecoveryPolicy(eligible: true)
    _ = pEOF.handle(.beginAlignment(generation: 1))
    _ = pEOF.handle(.eof(generation: 1))
    assertNamed(pEOF.phase == .ended, "testFailureAndEOFPreventRebuildingAndFailureSupersedes", "phase is .ended")
    assertNamed(pEOF.handle(.explicitPlay(applicationActive: true)) == .ordinaryPlay, "testFailureAndEOFPreventRebuildingAndFailureSupersedes", "ended play is ordinaryPlay")
    assertNamed(pEOF.handle(.interrupted(reason: .audioInterruption, generation: 1, readyLive: true)) == .none, "testFailureAndEOFPreventRebuildingAndFailureSupersedes", "ended cannot arm")

    // Disqualify cannot overwrite EOF or failure
    assertNamed(pEOF.handle(.disqualify(reason: "pause")) == .none, "testFailureAndEOFPreventRebuildingAndFailureSupersedes", "disqualify on EOF is .none")
    assertNamed(pEOF.phase == .ended, "testFailureAndEOFPreventRebuildingAndFailureSupersedes", "phase remains .ended")
    assertNamed(pFail.handle(.disqualify(reason: "pause")) == .none, "testFailureAndEOFPreventRebuildingAndFailureSupersedes", "disqualify on failure is .none")
    assertNamed(pFail.phase == .failed, "testFailureAndEOFPreventRebuildingAndFailureSupersedes", "phase remains .failed")

    // Failure supersedes EOF
    var pEOFThenFail = VGHLSRecoveryPolicy(eligible: true)
    _ = pEOFThenFail.handle(.eof(generation: 1))
    assertNamed(pEOFThenFail.phase == .ended, "testFailureAndEOFPreventRebuildingAndFailureSupersedes", "phase is .ended")
    _ = pEOFThenFail.handle(.failed(generation: 1))
    assertNamed(pEOFThenFail.phase == .failed, "testFailureAndEOFPreventRebuildingAndFailureSupersedes", "failure supersedes .ended")

    // Failure supersedes disqualification
    var pDisqThenFail = VGHLSRecoveryPolicy(eligible: true)
    _ = pDisqThenFail.handle(.disqualify(reason: "seek"))
    assertNamed(pDisqThenFail.phase == .disqualified(reason: "seek"), "testFailureAndEOFPreventRebuildingAndFailureSupersedes", "phase is disqualified")
    _ = pDisqThenFail.handle(.failed(generation: 1))
    assertNamed(pDisqThenFail.phase == .failed, "testFailureAndEOFPreventRebuildingAndFailureSupersedes", "failure supersedes disqualification")

    // EOF cannot supersede failure
    assertNamed(pFail.handle(.eof(generation: 1)) == .none, "testFailureAndEOFPreventRebuildingAndFailureSupersedes", "EOF cannot overwrite failure")
    assertNamed(pFail.phase == .failed, "testFailureAndEOFPreventRebuildingAndFailureSupersedes", "phase remains .failed")
}

// 13. Dispose dominates every subsequent event.
runTest("testDisposeDominatesEverySubsequentEvent") {
    var p = VGHLSRecoveryPolicy(eligible: true)
    _ = p.handle(.beginAlignment(generation: 1))
    _ = p.handle(.interrupted(reason: .audioInterruption, generation: 1, readyLive: true))
    assertNamed(p.phase == .armed(generation: 1, reason: .audioInterruption), "testDisposeDominatesEverySubsequentEvent", "armed before dispose")

    let dDispose = p.handle(.dispose)
    assertNamed(dDispose == .none, "testDisposeDominatesEverySubsequentEvent", "dispose returns .none")
    assertNamed(p.phase == .disposed, "testDisposeDominatesEverySubsequentEvent", "phase is .disposed")

    // Every subsequent event returns .none and phase remains .disposed
    assertNamed(p.handle(.explicitPlay(applicationActive: true)) == .none, "testDisposeDominatesEverySubsequentEvent", "play after dispose")
    assertNamed(p.handle(.beginAlignment(generation: 1)) == .none, "testDisposeDominatesEverySubsequentEvent", "beginAlignment after dispose")
    assertNamed(p.handle(.interrupted(reason: .audioInterruption, generation: 1, readyLive: true)) == .none, "testDisposeDominatesEverySubsequentEvent", "interrupted after dispose")
    assertNamed(p.handle(.aligned(generation: 1)) == .none, "testDisposeDominatesEverySubsequentEvent", "aligned after dispose")
    assertNamed(p.handle(.fallback(reason: .warmTimeout, generation: 1)) == .none, "testDisposeDominatesEverySubsequentEvent", "fallback after dispose")
    assertNamed(p.handle(.cancelled(reason: "test", generation: 1)) == .none, "testDisposeDominatesEverySubsequentEvent", "cancelled after dispose")
    assertNamed(p.handle(.disqualify(reason: "pause")) == .none, "testDisposeDominatesEverySubsequentEvent", "disqualify after dispose")
    assertNamed(p.handle(.failed(generation: 1)) == .none, "testDisposeDominatesEverySubsequentEvent", "failed after dispose")
    assertNamed(p.handle(.eof(generation: 1)) == .none, "testDisposeDominatesEverySubsequentEvent", "eof after dispose")
    assertNamed(p.handle(.dispose) == .none, "testDisposeDominatesEverySubsequentEvent", "second dispose")
    assertNamed(p.phase == .disposed, "testDisposeDominatesEverySubsequentEvent", "phase remains .disposed")
}

// 14. Cancellation is diagnostic-only, preserves phase/permission, and records cancelled_<reason>.
runTest("testCancellationIsDiagnosticOnlyAndPreservesPhaseAndPermission") {
    // In .aligning
    var pAligning = VGHLSRecoveryPolicy(eligible: true)
    _ = pAligning.handle(.beginAlignment(generation: 1))
    assertNamed(pAligning.phase == .aligning(generation: 1), "testCancellationIsDiagnosticOnlyAndPreservesPhaseAndPermission", "aligning")
    let dCancel1 = pAligning.handle(.cancelled(reason: "helper_timeout", generation: 1))
    assertNamed(dCancel1 == .none, "testCancellationIsDiagnosticOnlyAndPreservesPhaseAndPermission", "cancelled returns .none")
    assertNamed(pAligning.phase == .aligning(generation: 1), "testCancellationIsDiagnosticOnlyAndPreservesPhaseAndPermission", "phase remains .aligning(1)")
    assertNamed(pAligning.lastHelperOutcome == "cancelled_helper_timeout", "testCancellationIsDiagnosticOnlyAndPreservesPhaseAndPermission", "outcome recorded")

    // In .armed
    var pArmed = VGHLSRecoveryPolicy(eligible: true)
    _ = pArmed.handle(.beginAlignment(generation: 1))
    _ = pArmed.handle(.interrupted(reason: .audioInterruption, generation: 1, readyLive: true))
    assertNamed(pArmed.phase == .armed(generation: 1, reason: .audioInterruption), "testCancellationIsDiagnosticOnlyAndPreservesPhaseAndPermission", "armed")
    let dCancel2 = pArmed.handle(.cancelled(reason: "recovery_rebuild", generation: 1))
    assertNamed(dCancel2 == .none, "testCancellationIsDiagnosticOnlyAndPreservesPhaseAndPermission", "cancelled in armed returns .none")
    assertNamed(pArmed.phase == .armed(generation: 1, reason: .audioInterruption), "testCancellationIsDiagnosticOnlyAndPreservesPhaseAndPermission", "permission preserved")
    assertNamed(pArmed.lastHelperOutcome == "cancelled_recovery_rebuild", "testCancellationIsDiagnosticOnlyAndPreservesPhaseAndPermission", "outcome recorded")

    // Permission still consumes normally
    let dPlay = pArmed.handle(.explicitPlay(applicationActive: true))
    assertNamed(dPlay == .reconstruct(generation: 2), "testCancellationIsDiagnosticOnlyAndPreservesPhaseAndPermission", "can still reconstruct")
}

// 15. Initial outcome history survives later generations; lastHelperOutcome follows later outcomes.
runTest("testInitialOutcomeHistorySurvivesLaterGenerationsAndLastHelperOutcomeFollows") {
    var p = VGHLSRecoveryPolicy(eligible: true)
    _ = p.handle(.beginAlignment(generation: 1))
    assertNamed(p.initialOutcome == "started", "testInitialOutcomeHistorySurvivesLaterGenerationsAndLastHelperOutcomeFollows", "initial started")
    _ = p.handle(.aligned(generation: 1))
    assertNamed(p.initialOutcome == "aligned", "testInitialOutcomeHistorySurvivesLaterGenerationsAndLastHelperOutcomeFollows", "initial aligned")
    assertNamed(p.lastHelperOutcome == "aligned", "testInitialOutcomeHistorySurvivesLaterGenerationsAndLastHelperOutcomeFollows", "last aligned")

    // Interruption on g1
    _ = p.handle(.interrupted(reason: .audioInterruption, generation: 1, readyLive: true))
    assertNamed(p.initialOutcome == "aligned", "testInitialOutcomeHistorySurvivesLaterGenerationsAndLastHelperOutcomeFollows", "initial remains aligned")
    assertNamed(p.lastHelperOutcome == VGHLSStartupEndReason.audioInterruption.rawValue, "testInitialOutcomeHistorySurvivesLaterGenerationsAndLastHelperOutcomeFollows", "last updated to audioInterruption")

    // Recovery to g2
    _ = p.handle(.explicitPlay(applicationActive: true)) // gen 2
    _ = p.handle(.beginAlignment(generation: 2))
    assertNamed(p.initialOutcome == "aligned", "testInitialOutcomeHistorySurvivesLaterGenerationsAndLastHelperOutcomeFollows", "initial still aligned")
    assertNamed(p.lastHelperOutcome == "started", "testInitialOutcomeHistorySurvivesLaterGenerationsAndLastHelperOutcomeFollows", "last updated to started for g2")

    // g2 fallback
    _ = p.handle(.fallback(reason: .warmTimeout, generation: 2))
    assertNamed(p.initialOutcome == "aligned", "testInitialOutcomeHistorySurvivesLaterGenerationsAndLastHelperOutcomeFollows", "initial survives as aligned")
    assertNamed(p.lastHelperOutcome == VGHLSStartupEndReason.warmTimeout.rawValue, "testInitialOutcomeHistorySurvivesLaterGenerationsAndLastHelperOutcomeFollows", "last updated to warmTimeout")

    // g2 interruption and recovery to g3
    _ = p.handle(.interrupted(reason: .externalPause, generation: 2, readyLive: true))
    _ = p.handle(.explicitPlay(applicationActive: true)) // gen 3
    _ = p.handle(.beginAlignment(generation: 3))
    _ = p.handle(.aligned(generation: 3))
    assertNamed(p.initialOutcome == "aligned", "testInitialOutcomeHistorySurvivesLaterGenerationsAndLastHelperOutcomeFollows", "initial still survives")
    assertNamed(p.lastHelperOutcome == "aligned", "testInitialOutcomeHistorySurvivesLaterGenerationsAndLastHelperOutcomeFollows", "last is aligned")
}

print("ALL 15 POLICY VERIFICATION TESTS PASSED")
