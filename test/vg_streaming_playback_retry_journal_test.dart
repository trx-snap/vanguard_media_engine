// Copyright (c) Connects — Vanguard Phase 4C7AS.
// Public streaming playback retry journal unit tests.

import 'package:flutter_test/flutter_test.dart';
import 'package:vanguard_media_engine/vanguard_media_engine.dart';

void main() {
  group('VGStreamingPlaybackRetryJournal', () {
    // Helper to create mock playback options
    VGStreamingPlaybackOptions createOptions() {
      return VGStreamingPlaybackOptions(
        uri: Uri.parse('https://cdn.example.com/live/master.m3u8'),
        initialWidth: 1080,
        initialHeight: 1920,
        networkProfile: VGStreamingNetworkProfile.constrained,
      );
    }

    // Helper to create mock recovery plan
    VGStreamingPlaybackRecoveryPlan createPlan({
      VGStreamingPlaybackRecoveryIntent intent =
          VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
      VGStreamingPlaybackRecoveryUrgency urgency =
          VGStreamingPlaybackRecoveryUrgency.active,
      bool shouldReopenPlayback = true,
      bool requiresHostAction = false,
      bool canBuildPlaybackOptions = true,
      VGStreamingPlaybackOptions? playbackOptions,
      int? resumePositionMs,
      int retryDelayMs = 750,
      bool advisoryOnly = true,
      bool playbackMutation = false,
      List<String> reasons = const ['test_reason'],
    }) {
      return VGStreamingPlaybackRecoveryPlan(
        intent: intent,
        urgency: urgency,
        shouldReopenPlayback: shouldReopenPlayback,
        requiresHostAction: requiresHostAction,
        canBuildPlaybackOptions: canBuildPlaybackOptions,
        playbackOptions: playbackOptions ?? createOptions(),
        resumePositionMs: resumePositionMs,
        retryDelayMs: retryDelayMs,
        advisoryOnly: advisoryOnly,
        playbackMutation: playbackMutation,
        reasons: reasons,
      );
    }

    test('1. Config validation and defaults', () {
      const config = VGStreamingPlaybackRetryJournalConfig();
      expect(config.maxStoredAttempts, equals(64));
      expect(config.defaultWindowMs, isNull);

      const customConfig = VGStreamingPlaybackRetryJournalConfig(
        maxStoredAttempts: 10,
        defaultWindowMs: 60000,
      );
      expect(customConfig.maxStoredAttempts, equals(10));
      expect(customConfig.defaultWindowMs, equals(60000));

      final json = customConfig.toJson();
      expect(json['maxStoredAttempts'], equals(10));
      expect(json['defaultWindowMs'], equals(60000));
      expect(
        customConfig.toString(),
        contains('VGStreamingPlaybackRetryJournalConfig'),
      );

      // Assertions on invalid bounds
      expect(
        () => VGStreamingPlaybackRetryJournalConfig(maxStoredAttempts: 0),
        throwsAssertionError,
      );
      expect(
        () => VGStreamingPlaybackRetryJournalConfig(maxStoredAttempts: -1),
        throwsAssertionError,
      );
      expect(
        () => VGStreamingPlaybackRetryJournalConfig(defaultWindowMs: 0),
        throwsAssertionError,
      );
      expect(
        () => VGStreamingPlaybackRetryJournalConfig(defaultWindowMs: -100),
        throwsAssertionError,
      );
    });

    test('2. Initial attempts are defensively copied and capped', () {
      final initial = [
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 1000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
        ),
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 2000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
        ),
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 3000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
        ),
      ];

      // Constructor with maxStoredAttempts = 2 trims oldest (1000)
      final journal = VGStreamingPlaybackRetryJournal(
        initialAttempts: initial,
        config: const VGStreamingPlaybackRetryJournalConfig(
          maxStoredAttempts: 2,
        ),
      );

      expect(journal.length, equals(2));
      expect(journal.isEmpty, isFalse);
      expect(journal.isNotEmpty, isTrue);
      expect(journal.attempts()[0].timestampMs, equals(2000));
      expect(journal.attempts()[1].timestampMs, equals(3000));

      // Modifying initial list does not affect journal
      initial.clear();
      expect(journal.length, equals(2));
    });

    test('3. record appends and trims oldest FIFO when limit exceeded', () {
      final journal = VGStreamingPlaybackRetryJournal(
        config: const VGStreamingPlaybackRetryJournalConfig(
          maxStoredAttempts: 3,
        ),
      );

      expect(journal.isEmpty, isTrue);

      journal.record(
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 1000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: 'streamA',
        ),
      );
      journal.record(
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 2000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: 'streamA',
        ),
      );
      journal.record(
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 3000,
          intent: VGStreamingPlaybackRecoveryIntent.retryConstrainedProfile,
          streamKey: 'streamB',
        ),
      );

      expect(journal.length, equals(3));

      // Adding a 4th trims oldest (1000)
      journal.record(
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 4000,
          intent: VGStreamingPlaybackRecoveryIntent.reopenStandardLatency,
          streamKey: 'streamB',
        ),
      );

      expect(journal.length, equals(3));
      final all = journal.attempts();
      expect(all[0].timestampMs, equals(2000));
      expect(all[1].timestampMs, equals(3000));
      expect(all[2].timestampMs, equals(4000));
    });

    test('4. recordNow constructs and records attempt', () {
      final journal = VGStreamingPlaybackRetryJournal();

      final attempt = journal.recordNow(
        nowMs: 50000,
        intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
        streamKey: 'stream_primary',
        reason: 'rebuffer_timeout',
      );

      expect(attempt.timestampMs, equals(50000));
      expect(
        attempt.intent,
        equals(VGStreamingPlaybackRecoveryIntent.retryCurrentProfile),
      );
      expect(attempt.streamKey, equals('stream_primary'));
      expect(attempt.reason, equals('rebuffer_timeout'));

      expect(journal.length, equals(1));
      expect(journal.attempts().first, equals(attempt));
    });

    test('5. attempts returns immutable copy and filters by streamKey', () {
      final journal = VGStreamingPlaybackRetryJournal();

      journal.record(
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 1000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: 'streamA',
        ),
      );
      journal.record(
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 2000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: 'streamB',
        ),
      );
      journal.record(
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 3000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: 'streamA',
        ),
      );

      // Unmodifiable check
      final all = journal.attempts();
      expect(
        () => all.add(
          const VGStreamingPlaybackRetryAttempt(
            timestampMs: 4000,
            intent: VGStreamingPlaybackRecoveryIntent.none,
          ),
        ),
        throwsUnsupportedError,
      );

      // Filter by streamKey
      final streamA = journal.attempts(streamKey: 'streamA');
      expect(streamA.length, equals(2));
      expect(streamA[0].timestampMs, equals(1000));
      expect(streamA[1].timestampMs, equals(3000));

      final streamB = journal.attempts(streamKey: 'streamB');
      expect(streamB.length, equals(1));
      expect(streamB[0].timestampMs, equals(2000));

      final streamC = journal.attempts(streamKey: 'streamC');
      expect(streamC.isEmpty, isTrue);
    });

    test('6. clear and clearStream operations', () {
      final journal = VGStreamingPlaybackRetryJournal();

      journal.record(
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 1000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: 'streamA',
        ),
      );
      journal.record(
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 2000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: 'streamB',
        ),
      );
      journal.record(
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 3000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: 'streamA',
        ),
      );

      // clearStream removes matching stream
      final removed = journal.clearStream('streamA');
      expect(removed, equals(2));
      expect(journal.length, equals(1));
      expect(journal.attempts().first.streamKey, equals('streamB'));

      // clear empties journal
      journal.clear();
      expect(journal.length, equals(0));
      expect(journal.isEmpty, isTrue);
    });

    test('7. prune with explicit window and default window', () {
      final journal = VGStreamingPlaybackRetryJournal(
        config: const VGStreamingPlaybackRetryJournalConfig(
          defaultWindowMs: 5000,
        ),
      );

      // Attempts at 10000, 12000, 16000, 19000
      journal.record(
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 10000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: 'streamA',
        ),
      );
      journal.record(
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 12000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: 'streamA',
        ),
      );
      journal.record(
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 16000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: 'streamB',
        ),
      );
      journal.record(
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 19000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: 'streamA',
        ),
      );

      // Prune at nowMs = 20000 with defaultWindowMs (5000) -> cutoff = 15000.
      // Attempts at 10000 and 12000 (< 15000) are removed.
      final removed = journal.prune(nowMs: 20000);
      expect(removed, equals(2));
      expect(journal.length, equals(2));
      expect(journal.attempts()[0].timestampMs, equals(16000));
      expect(journal.attempts()[1].timestampMs, equals(19000));

      // Explicit window prune: nowMs = 20000, windowMs = 2000 -> cutoff = 18000.
      // Attempt at 16000 is removed.
      final removed2 = journal.prune(nowMs: 20000, windowMs: 2000);
      expect(removed2, equals(1));
      expect(journal.length, equals(1));
      expect(journal.attempts().first.timestampMs, equals(19000));

      // Prune on journal without defaultWindowMs and no windowMs returns 0
      final noWindowJournal = VGStreamingPlaybackRetryJournal();
      noWindowJournal.record(
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 1000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
        ),
      );
      final removed3 = noWindowJournal.prune(nowMs: 50000);
      expect(removed3, equals(0));
      expect(noWindowJournal.length, equals(1));
    });

    test('8. prune with streamKey filter only removes matching stream', () {
      final journal = VGStreamingPlaybackRetryJournal();

      journal.record(
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 10000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: 'streamA',
        ),
      );
      journal.record(
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 10000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: 'streamB',
        ),
      );

      // Prune only streamA older than 15000 at nowMs = 20000 (window 5000 -> cutoff 15000)
      final removed = journal.prune(
        nowMs: 20000,
        windowMs: 5000,
        streamKey: 'streamA',
      );

      expect(removed, equals(1));
      expect(journal.length, equals(1));
      expect(journal.attempts().first.streamKey, equals('streamB'));
    });

    test('9. snapshot serialization and invariants', () {
      final journal = VGStreamingPlaybackRetryJournal(
        config: const VGStreamingPlaybackRetryJournalConfig(
          maxStoredAttempts: 16,
          defaultWindowMs: 60000,
        ),
      );

      journal.record(
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 1000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: 'streamA',
        ),
      );

      final snapshot = journal.snapshot(streamKey: 'streamA');
      expect(snapshot.count, equals(1));
      expect(snapshot.streamKey, equals('streamA'));
      expect(snapshot.advisoryOnly, isTrue);
      expect(snapshot.playbackMutation, isFalse);
      expect(snapshot.diagnostics['totalCount'], equals(1));
      expect(snapshot.diagnostics['snapshotCount'], equals(1));
      expect(snapshot.diagnostics['maxStoredAttempts'], equals(16));
      expect(snapshot.diagnostics['defaultWindowMs'], equals(60000));
      expect(snapshot.diagnostics['streamKey'], equals('streamA'));

      final json = snapshot.toJson();
      expect(json['count'], equals(1));
      expect(json['streamKey'], equals('streamA'));
      expect(json['advisoryOnly'], isTrue);
      expect(json['playbackMutation'], isFalse);
      expect((json['attempts'] as List).length, equals(1));
      expect(
        snapshot.toString(),
        contains('VGStreamingPlaybackRetryJournalSnapshot'),
      );
    });

    test('10. evaluateBudget evaluates planner without mutating journal', () {
      final journal = VGStreamingPlaybackRetryJournal();

      // Record 1 attempt at 45000
      journal.record(
        const VGStreamingPlaybackRetryAttempt(
          timestampMs: 45000,
          intent: VGStreamingPlaybackRecoveryIntent.retryCurrentProfile,
          streamKey: 'streamA',
        ),
      );

      final plan = createPlan();

      // Case A: Evaluate at nowMs = 50000 (delay elapsed) -> allow
      final resultAllowed = journal.evaluateBudget(
        recoveryPlan: plan,
        nowMs: 50000,
        streamKey: 'streamA',
      );

      expect(
        resultAllowed.decision,
        equals(VGStreamingPlaybackRetryBudgetDecision.allow),
      );
      expect(resultAllowed.canRetry, isTrue);
      expect(resultAllowed.attemptsInWindow, equals(1));
      expect(resultAllowed.remainingAttempts, equals(1)); // max 3 - 1 - 1 = 1
      expect(journal.length, equals(1)); // Journal not mutated

      // Case B: Evaluate with host action required plan -> block
      final planHostAction = createPlan(requiresHostAction: true);
      final resultBlocked = journal.evaluateBudget(
        recoveryPlan: planHostAction,
        nowMs: 50000,
        streamKey: 'streamA',
      );

      expect(
        resultBlocked.decision,
        equals(VGStreamingPlaybackRetryBudgetDecision.block),
      );
      expect(resultBlocked.canRetry, isFalse);
      expect(
        resultBlocked.reasons,
        contains(VGStreamingPlaybackRetryBudgetReason.hostActionRequired),
      );
      expect(journal.length, equals(1)); // Journal not mutated

      // Case C: Cooldown not elapsed -> delay
      final resultDelayed = journal.evaluateBudget(
        recoveryPlan: plan,
        nowMs: 45200, // only 200ms elapsed, min is 750ms
        streamKey: 'streamA',
      );

      expect(
        resultDelayed.decision,
        equals(VGStreamingPlaybackRetryBudgetDecision.delay),
      );
      expect(resultDelayed.canRetry, isFalse);
      expect(resultDelayed.retryAfterMs, equals(550));
      expect(journal.length, equals(1)); // Journal not mutated
    });

    test('11. fromJson parses valid entries and skips malformed entries', () {
      final validJson = <String, Object?>{
        'attempts': [
          {
            'timestampMs': 10000,
            'intent': 'retryCurrentProfile',
            'streamKey': 'streamA',
            'reason': 'rebuffer',
          },
          {
            'timestampMs': 20000,
            'intent': 'retryConstrainedProfile',
            'streamKey': 'streamB',
          },
          // Malformed entries (should be skipped defensively)
          {
            'timestampMs': -1, // Negative timestamp
            'intent': 'retryCurrentProfile',
          },
          {
            'timestampMs': 30000,
            'intent': 'unknownIntentName', // Unknown intent enum
          },
          {
            'invalidKey': 'corruptedData', // Missing timestamp & intent
          },
          'justAStringNotAMap', // Non-map element
        ],
      };

      final journal = VGStreamingPlaybackRetryJournal.fromJson(
        validJson,
        config: const VGStreamingPlaybackRetryJournalConfig(
          maxStoredAttempts: 10,
        ),
      );

      expect(journal.length, equals(2));
      expect(journal.attempts()[0].timestampMs, equals(10000));
      expect(
        journal.attempts()[0].intent,
        equals(VGStreamingPlaybackRecoveryIntent.retryCurrentProfile),
      );
      expect(journal.attempts()[0].streamKey, equals('streamA'));
      expect(journal.attempts()[0].reason, equals('rebuffer'));

      expect(journal.attempts()[1].timestampMs, equals(20000));
      expect(
        journal.attempts()[1].intent,
        equals(VGStreamingPlaybackRecoveryIntent.retryConstrainedProfile),
      );
      expect(journal.attempts()[1].streamKey, equals('streamB'));

      // fromJson with empty map or missing attempts key
      final emptyJournal = VGStreamingPlaybackRetryJournal.fromJson({});
      expect(emptyJournal.isEmpty, isTrue);
    });

    test(
      '12. fromJson defensively skips entries with non-string optional fields without throwing',
      () {
        final json = <String, Object?>{
          'attempts': [
            // Valid entry with null optional fields
            {
              'timestampMs': 1000,
              'intent': 'retryCurrentProfile',
              'streamKey': null,
              'reason': null,
            },
            // Valid entry with String optional fields
            {
              'timestampMs': 2000,
              'intent': 'retryCurrentProfile',
              'streamKey': 'validStream',
              'reason': 'validReason',
            },
            // Malformed optional field: streamKey is int
            {
              'timestampMs': 3000,
              'intent': 'retryCurrentProfile',
              'streamKey': 12345,
              'reason': 'validReason',
            },
            // Malformed optional field: streamKey is bool
            {
              'timestampMs': 4000,
              'intent': 'retryCurrentProfile',
              'streamKey': true,
            },
            // Malformed optional field: streamKey is List
            {
              'timestampMs': 5000,
              'intent': 'retryCurrentProfile',
              'streamKey': ['invalidList'],
            },
            // Malformed optional field: reason is int
            {
              'timestampMs': 6000,
              'intent': 'retryCurrentProfile',
              'streamKey': 'validStream',
              'reason': 500,
            },
            // Malformed optional field: reason is Map
            {
              'timestampMs': 7000,
              'intent': 'retryCurrentProfile',
              'reason': {'error': 'fatal'},
            },
            // Malformed optional field: reason is bool
            {
              'timestampMs': 8000,
              'intent': 'retryCurrentProfile',
              'reason': false,
            },
          ],
        };

        late VGStreamingPlaybackRetryJournal journal;
        expect(
          () => journal = VGStreamingPlaybackRetryJournal.fromJson(json),
          returnsNormally,
        );

        expect(journal.length, equals(2));
        expect(journal.attempts()[0].timestampMs, equals(1000));
        expect(journal.attempts()[0].streamKey, isNull);
        expect(journal.attempts()[0].reason, isNull);

        expect(journal.attempts()[1].timestampMs, equals(2000));
        expect(journal.attempts()[1].streamKey, equals('validStream'));
        expect(journal.attempts()[1].reason, equals('validReason'));
      },
    );
  });
}
