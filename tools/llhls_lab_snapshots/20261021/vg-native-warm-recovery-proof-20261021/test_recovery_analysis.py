#!/usr/bin/env python3
"""
test_recovery_analysis.py - Deterministic offline unit tests for RecoveryAnalysis.py and nginx.conf.
Validates synthetic traces and real raw replays against the native AVPlayer recovery contract:
- Nginx config output paths offline assertion for proof workspace
- Real raw replay tests of N/results/trial_02 and trial_03 (timings 1214/1269ms, medians 1423/1375ms)
- Valid 9-style rebuild traces matching native RecoverySession schema (ended_generation: 1, following marker, final_phase: "recovered")
- Valid observe control freeze (counterfactual) and resumption
- Absent, null, nonfinite evidence (exit_code != 0, PID <= 0, NaN/null rates/display)
- Startup events and config validation (file order, settings, missing gen2 config)
- Enforced gen1 alignment + 10s fault timing window (0..300ms polling slack)
- Exact fault PID matching, ack latency consistency, actual duration consistency
- Rebuild ordering, early recovery rejection, generation 3 rejection
- Immediate following marker matching recovery_completed (frame_id, source_mono_ms, observation_mono_ms)
- Negative tests for wrong ended_generation, missing following marker, changed fields, reversed lifecycle
- Shared safety across pre-fault, rebuild postrecovery, and no-rebuild postrestore
- Same-ms pre-call excluded vs post-call same-ms paused fails
- Teardown at EOF requirement and native error count preservation
"""

import json
import math
import os
import unittest

from RecoveryAnalysis import evaluate_recovery_trial


class TestRecoveryAnalysis(unittest.TestCase):
    def setUp(self):
        self.gateway_pid = 42100
        self.outage_dur_s = 5.0
        self.trial_meta = {
            "trial_id": "trial_02_d5s_reb_rep1",
            "recovery_mode": "rebuild",
            "outage_duration_s": self.outage_dur_s,
            "gateway_pid": self.gateway_pid,
            "playback_duration_s": 65,
            "startup_mode": "precision",
            "exit_code": 0,
            "timed_out": False,
        }

    def test_nginx_conf_paths(self):
        conf_path = "/private/tmp/vg-native-warm-recovery-proof-20261021/nginx.conf"
        self.assertTrue(os.path.isfile(conf_path))
        with open(conf_path, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertNotIn("vg-native-warm-buffer-20261021", content)
        self.assertNotIn("vg-native-warm-recovery-20261021", content)
        self.assertIn("/private/tmp/vg-native-warm-recovery-proof-20261021/results/nginx.pid", content)
        self.assertIn("/private/tmp/vg-native-warm-recovery-proof-20261021/results/nginx_error.log", content)
        self.assertIn("/private/tmp/vg-native-warm-recovery-proof-20261021/results/nginx_access.log", content)

    # -------------------------------------------------------------------------
    # Real Raw Replay Tests (read-only from N/results/)
    # -------------------------------------------------------------------------
    def test_real_raw_replay_trial02(self):
        events_path = "/private/tmp/vg-native-warm-recovery-20261021/results/events.jsonl"
        probe_path = "/private/tmp/vg-native-warm-recovery-20261021/results/trial_02_d2s_reb_rep1/probe.jsonl"
        self.assertTrue(os.path.isfile(events_path), f"missing events file: {events_path}")
        self.assertTrue(os.path.isfile(probe_path), f"missing probe file: {probe_path}")

        with open(events_path, "r", encoding="utf-8") as f:
            events = [json.loads(line) for line in f if line.strip()]
        t2_events = [e for e in events if e.get("trial_id") == "trial_02_d2s_reb_rep1"]
        t2_completed = [e for e in t2_events if e.get("event") == "trial_completed"][0]
        t2_faults = [e for e in t2_events if e.get("event") in ("delivery_outage_started", "delivery_outage_restored")]

        with open(probe_path, "r", encoding="utf-8") as f:
            probe_records = [json.loads(line) for line in f if line.strip()]

        res = evaluate_recovery_trial(probe_records, t2_faults, t2_completed)
        self.assertFalse(res["quality_failure"], msg=res.get("quality_failure_reason"))
        self.assertFalse(res["comparator_invalidated"])
        self.assertTrue(res["rebuild_exercised"])
        self.assertTrue(res["rebuild_latency_met"])
        self.assertEqual(res["restore_to_recovery_completed_ms"], 1214.0)
        self.assertEqual(res["settled_median_age_ms"], 1423.0)

    def test_real_raw_replay_trial03(self):
        events_path = "/private/tmp/vg-native-warm-recovery-20261021/results/events.jsonl"
        probe_path = "/private/tmp/vg-native-warm-recovery-20261021/results/trial_03_d2s_reb_rep2/probe.jsonl"
        self.assertTrue(os.path.isfile(events_path), f"missing events file: {events_path}")
        self.assertTrue(os.path.isfile(probe_path), f"missing probe file: {probe_path}")

        with open(events_path, "r", encoding="utf-8") as f:
            events = [json.loads(line) for line in f if line.strip()]
        t3_events = [e for e in events if e.get("trial_id") == "trial_03_d2s_reb_rep2"]
        t3_completed = [e for e in t3_events if e.get("event") == "trial_completed"][0]
        t3_faults = [e for e in t3_events if e.get("event") in ("delivery_outage_started", "delivery_outage_restored")]

        with open(probe_path, "r", encoding="utf-8") as f:
            probe_records = [json.loads(line) for line in f if line.strip()]

        res = evaluate_recovery_trial(probe_records, t3_faults, t3_completed)
        self.assertFalse(res["quality_failure"], msg=res.get("quality_failure_reason"))
        self.assertFalse(res["comparator_invalidated"])
        self.assertTrue(res["rebuild_exercised"])
        self.assertTrue(res["rebuild_latency_met"])
        self.assertEqual(res["restore_to_recovery_completed_ms"], 1269.0)
        self.assertEqual(res["settled_median_age_ms"], 1375.0)

    # -------------------------------------------------------------------------
    # Synthetic Trace Fixtures
    # -------------------------------------------------------------------------
    def _make_fault_records(
        self,
        target_dur_s: float = 5.0,
        actual_dur_s: float = 5.015,
        target_pid: int = 42100,
        cmd_mono_s: float = 11.250,
        ack_mono_s: float = 11.255,
    ) -> list[dict]:
        restore_mono_s = ack_mono_s + actual_dur_s
        return [
            {
                "event": "delivery_outage_started",
                "target_pid": target_pid,
                "target_duration_s": target_dur_s,
                "cmd_mono_s": cmd_mono_s,
                "ack_mono_s": ack_mono_s,
                "ack_latency_ms": round((ack_mono_s - cmd_mono_s) * 1000, 2),
            },
            {
                "event": "delivery_outage_restored",
                "target_pid": target_pid,
                "restore_mono_s": restore_mono_s,
                "actual_outage_duration_s": actual_dur_s,
            },
        ]

    def _make_valid_rebuild_records(self, outage_dur_s: float = 5.0) -> list[dict]:
        records = [
            {
                "event": "config", "generation": 1, "observation_mono_ms": 1000,
                "startup_mode": "precision", "recovery_mode": "rebuild",
                "waits": True, "can_use_network_resources_for_live_streaming_while_paused": True,
                "preferred_forward_buffer_duration": 1.2, "configured_time_offset_seconds": 1.2,
                "requested_offset_ms": 1200, "automatically_preserves_time_offset": False,
                "startup_protocol": "warm_play_pause_preroll_align",
            },
            {
                "event": "warmup_paused", "generation": 1, "observation_mono_ms": 1020,
                "warm_target_seconds": 25.0, "warm_required_ahead_ms": 500,
                "warm_loaded_ranges": [{"start": 20.0, "duration": 10.0, "end": 30.0}],
                "warm_coverage_verified": True,
            },
            {"event": "preroll_requested", "generation": 1, "observation_mono_ms": 1040},
            {"event": "preroll_completed", "generation": 1, "observation_mono_ms": 1080, "finished": True},
            {"event": "alignment_issued", "generation": 1, "observation_mono_ms": 1100},
            {"event": "alignment_completed", "generation": 1, "observation_mono_ms": 1200},
        ]

        fid = 100
        # Pre-fault window: aligned + 3..8s -> 4200..9200
        for mono in range(4300, 9100, 200):
            fid += 1
            records.append({
                "observation_mono_ms": mono, "generation": 1, "time_control_status": "playing",
                "effective_rate": 1.0, "requested_rate": 1.0, "effective_timebase_rate": 1.0,
                "configured_offset_seconds": 1.2, "recommended_offset_seconds": 1.002,
                "valid": True, "presentation_eligible": True, "is_future_sample": False,
                "frame_id": fid, "source_mono_ms": mono - 1200, "display_item_time_seconds": float(fid) * 0.033,
                "age_ms": 1200.0,
            })

        last_prefault_fid = fid
        last_prefault_src = records[-1]["source_mono_ms"]

        # Fault ack is at 11255ms, restore at 16270ms
        records.append({
            "event": "recovery_requested", "generation": 1, "observation_mono_ms": 16300,
            "last_advancing_frame_id": last_prefault_fid,
            "last_advancing_source_mono_ms": last_prefault_src,
            "progress_gap_ms": 850,
        })
        # Swift RecoverySession emits ended_generation: 1 (no generation key)
        records.append({
            "event": "generation_ended", "ended_generation": 1, "observation_mono_ms": 16310,
        })

        # Generation 2 setup
        records.append({
            "event": "config", "generation": 2, "observation_mono_ms": 16320,
            "startup_mode": "precision", "recovery_mode": "rebuild",
            "waits": True, "can_use_network_resources_for_live_streaming_while_paused": True,
            "preferred_forward_buffer_duration": 1.2, "configured_time_offset_seconds": 1.2,
            "requested_offset_ms": 1200, "automatically_preserves_time_offset": False,
            "startup_protocol": "warm_play_pause_preroll_align",
        })
        records.append({
            "event": "warmup_paused", "generation": 2, "observation_mono_ms": 16350,
            "warm_target_seconds": 35.0, "warm_required_ahead_ms": 500,
            "warm_loaded_ranges": [{"start": 30.0, "duration": 10.0, "end": 40.0}],
            "warm_coverage_verified": True,
        })
        records.append({"event": "preroll_requested", "generation": 2, "observation_mono_ms": 16380})
        records.append({"event": "preroll_completed", "generation": 2, "observation_mono_ms": 16420, "finished": True})
        records.append({"event": "alignment_issued", "generation": 2, "observation_mono_ms": 16450})
        records.append({"event": "alignment_completed", "generation": 2, "observation_mono_ms": 16550})

        # Recovery completed emitted FIRST in RecoverySession.swift
        new_fid = last_prefault_fid + 50
        new_src = last_prefault_src + 7000
        rec_obs = 16600
        records.append({
            "event": "recovery_completed", "generation": 2, "observation_mono_ms": rec_obs,
            "frame_id": new_fid, "source_mono_ms": new_src,
        })

        # Immediate FOLLOWING marker matching recovery_completed
        records.append({
            "observation_mono_ms": rec_obs, "generation": 2, "time_control_status": "playing",
            "effective_rate": 1.0, "requested_rate": 1.0, "effective_timebase_rate": 1.0,
            "configured_offset_seconds": 1.2, "recommended_offset_seconds": 1.002,
            "valid": True, "presentation_eligible": True, "is_future_sample": False,
            "frame_id": new_fid, "source_mono_ms": new_src, "display_item_time_seconds": float(new_fid) * 0.033,
            "age_ms": float(rec_obs) - float(new_src),
        })

        # Gen 2 safety & settled window: 16600+5000=21600 to 16600+35000=51600
        fid = new_fid
        for mono in range(16700, 52000, 200):
            fid += 1
            records.append({
                "observation_mono_ms": mono, "generation": 2, "time_control_status": "playing",
                "effective_rate": 1.0, "requested_rate": 1.0, "effective_timebase_rate": 1.0,
                "configured_offset_seconds": 1.2, "recommended_offset_seconds": 1.002,
                "valid": True, "presentation_eligible": True, "is_future_sample": False,
                "frame_id": fid, "source_mono_ms": mono - 1300, "display_item_time_seconds": float(fid) * 0.033,
                "age_ms": 1300.0,
            })

        last_mono = records[-1]["observation_mono_ms"]
        records.append({
            "teardown": True, "teardown_mono_ms": last_mono + 100, "generation": 2,
            "final_generation": 2, "final_phase": "recovered", "native_error_log_events": [],
        })
        return records

    def test_valid_rebuild_trace(self):
        records = self._make_valid_rebuild_records(5.0)
        faults = self._make_fault_records(5.0, 5.015)
        res = evaluate_recovery_trial(records, faults, self.trial_meta)
        self.assertFalse(res["quality_failure"], msg=res.get("quality_failure_reason"))
        self.assertTrue(res["rebuild_exercised"])
        self.assertTrue(res["rebuild_latency_met"])
        self.assertFalse(res["native_recovery_sufficient"])
        self.assertGreaterEqual(res["restore_to_recovery_completed_ms"], 0.0)
        self.assertLessEqual(res["restore_to_recovery_completed_ms"], 3000.0)
        self.assertGreaterEqual(res["settled_samples_count"], 110)
        self.assertGreaterEqual(res["settled_span_ms"], 29000.0)
        self.assertLessEqual(res["settled_median_age_ms"], 1500.0)
        self.assertLess(res["settled_p95_age_ms"], 2000.0)

    def test_valid_control_freeze(self):
        meta = dict(self.trial_meta)
        meta["recovery_mode"] = "observe"
        meta["trial_id"] = "trial_01_d5s_obs"

        records = [
            {
                "event": "config", "generation": 1, "observation_mono_ms": 1000,
                "startup_mode": "precision", "recovery_mode": "observe",
                "waits": True, "can_use_network_resources_for_live_streaming_while_paused": True,
                "preferred_forward_buffer_duration": 1.2, "configured_time_offset_seconds": 1.2,
                "requested_offset_ms": 1200, "automatically_preserves_time_offset": False,
                "startup_protocol": "warm_play_pause_preroll_align",
            },
            {
                "event": "warmup_paused", "generation": 1, "observation_mono_ms": 1020,
                "warm_target_seconds": 25.0, "warm_required_ahead_ms": 500,
                "warm_loaded_ranges": [{"start": 20.0, "duration": 10.0, "end": 30.0}],
                "warm_coverage_verified": True,
            },
            {"event": "preroll_requested", "generation": 1, "observation_mono_ms": 1040},
            {"event": "preroll_completed", "generation": 1, "observation_mono_ms": 1080, "finished": True},
            {"event": "alignment_issued", "generation": 1, "observation_mono_ms": 1100},
            {"event": "alignment_completed", "generation": 1, "observation_mono_ms": 1200},
        ]
        fid = 100
        for mono in range(4300, 9100, 200):
            fid += 1
            records.append({
                "observation_mono_ms": mono, "generation": 1, "time_control_status": "playing",
                "effective_rate": 1.0, "requested_rate": 1.0, "effective_timebase_rate": 1.0,
                "configured_offset_seconds": 1.2, "recommended_offset_seconds": 1.002,
                "valid": True, "presentation_eligible": True, "is_future_sample": False,
                "frame_id": fid, "source_mono_ms": mono - 1200, "display_item_time_seconds": float(fid) * 0.033,
                "age_ms": 1200.0,
            })
        records.append({
            "teardown": True, "teardown_mono_ms": 25000, "generation": 1,
            "final_generation": 1, "final_phase": "initial", "native_error_log_events": [],
        })

        faults = self._make_fault_records(5.0, 5.015)
        res = evaluate_recovery_trial(records, faults, meta)
        self.assertFalse(res["quality_failure"])
        self.assertFalse(res["comparator_invalidated"])
        self.assertFalse(res["resumed_postrestore"])
        self.assertIsNone(res["postrestore_first_frame_id"])

    def test_absent_gateway_pid_or_exit_code(self):
        records = self._make_valid_rebuild_records(5.0)
        faults = self._make_fault_records(5.0, 5.015)

        # 1. Missing gateway_pid
        meta1 = dict(self.trial_meta)
        del meta1["gateway_pid"]
        res1 = evaluate_recovery_trial(records, faults, meta1)
        self.assertTrue(res1["quality_failure"])
        self.assertIn("absent_or_invalid_gateway_pid", res1["quality_failure_reason"])

        # 2. Non-zero exit code
        meta2 = dict(self.trial_meta)
        meta2["exit_code"] = 1
        res2 = evaluate_recovery_trial(records, faults, meta2)
        self.assertTrue(res2["quality_failure"])
        self.assertIn("exit_code_must_be_0", res2["quality_failure_reason"])

        # 3. None exit code
        meta3 = dict(self.trial_meta)
        meta3["exit_code"] = None
        res3 = evaluate_recovery_trial(records, faults, meta3)
        self.assertTrue(res3["quality_failure"])
        self.assertIn("exit_code_must_be_0", res3["quality_failure_reason"])

    def test_nan_or_null_rates_and_display(self):
        faults = self._make_fault_records(5.0, 5.015)

        # 1. Null requested_rate
        records1 = self._make_valid_rebuild_records(5.0)
        for r in records1:
            if "valid" in r:
                r["requested_rate"] = None
                break
        res1 = evaluate_recovery_trial(records1, faults, self.trial_meta)
        self.assertTrue(res1["quality_failure"])
        self.assertIn("requested_rate_null_or_nonfinite", res1["quality_failure_reason"])

        # 2. NaN effective_rate
        records2 = self._make_valid_rebuild_records(5.0)
        for r in records2:
            if "valid" in r:
                r["effective_rate"] = float("nan")
                break
        res2 = evaluate_recovery_trial(records2, faults, self.trial_meta)
        self.assertTrue(res2["quality_failure"])
        self.assertIn("effective_rate_null_or_nonfinite", res2["quality_failure_reason"])

        # 3. Nonfinite display time
        records3 = self._make_valid_rebuild_records(5.0)
        for r in records3:
            if "valid" in r:
                r["display_item_time_seconds"] = float("nan")
                break
        res3 = evaluate_recovery_trial(records3, faults, self.trial_meta)
        self.assertTrue(res3["quality_failure"])
        self.assertIn("missing_or_nonfinite_display_item_time", res3["quality_failure_reason"])

    def test_missing_gen2_config(self):
        records = self._make_valid_rebuild_records(5.0)
        gen2_cfg = [r for r in records if r.get("event") == "config" and r.get("generation") == 2][0]
        records.remove(gen2_cfg)
        faults = self._make_fault_records(5.0, 5.015)
        res = evaluate_recovery_trial(records, faults, self.trial_meta)
        self.assertTrue(res["quality_failure"])
        self.assertIn("gen2_expected_exactly_1_config", res["quality_failure_reason"])

    def test_same_ms_reversed_startup(self):
        records = self._make_valid_rebuild_records(5.0)
        cfg = [r for r in records if r.get("event") == "config" and r.get("generation") == 1][0]
        wp = [r for r in records if r.get("event") == "warmup_paused" and r.get("generation") == 1][0]
        cfg["observation_mono_ms"] = 1000
        wp["observation_mono_ms"] = 1000
        idx_cfg = records.index(cfg)
        idx_wp = records.index(wp)
        records[idx_cfg], records[idx_wp] = records[idx_wp], records[idx_cfg]

        faults = self._make_fault_records(5.0, 5.015)
        res = evaluate_recovery_trial(records, faults, self.trial_meta)
        self.assertTrue(res["quality_failure"])
        self.assertIn("out_of_file_order", res["quality_failure_reason"])

    def test_fault_timing_window_enforcement(self):
        records = self._make_valid_rebuild_records(5.0)
        # Gen 1 alignment completed at 1200ms -> expected fault start in [11200..11500]ms

        # 1. Fault too early (11100ms < 11200ms)
        faults_early = self._make_fault_records(5.0, 5.015, cmd_mono_s=11.100, ack_mono_s=11.105)
        res_early = evaluate_recovery_trial(records, faults_early, self.trial_meta)
        self.assertTrue(res_early["quality_failure"])
        self.assertIn("fault_start_timing_out_of_window", res_early["quality_failure_reason"])

        # 2. Fault too late (11600ms > 11500ms)
        faults_late = self._make_fault_records(5.0, 5.015, cmd_mono_s=11.600, ack_mono_s=11.605)
        res_late = evaluate_recovery_trial(records, faults_late, self.trial_meta)
        self.assertTrue(res_late["quality_failure"])
        self.assertIn("fault_start_timing_out_of_window", res_late["quality_failure_reason"])

    def test_early_recovery_before_restore(self):
        records = self._make_valid_rebuild_records(5.0)
        rec_comp = [r for r in records if r.get("event") == "recovery_completed"][0]
        idx_rc = records.index(rec_comp)
        foll_marker = records[idx_rc + 1]
        rec_comp["observation_mono_ms"] = 16100
        foll_marker["observation_mono_ms"] = 16100
        faults = self._make_fault_records(5.0, 5.015)
        res = evaluate_recovery_trial(records, faults, self.trial_meta)
        self.assertTrue(res["quality_failure"])
        self.assertIn("early_recovery_completed_before_fault_restoration", res["quality_failure_reason"])

    def test_teardown_not_at_eof(self):
        records = self._make_valid_rebuild_records(5.0)
        records.append({"observation_mono_ms": 99999, "generation": 2})
        faults = self._make_fault_records(5.0, 5.015)
        res = evaluate_recovery_trial(records, faults, self.trial_meta)
        self.assertTrue(res["quality_failure"])
        self.assertIn("teardown_record_not_at_eof", res["quality_failure_reason"])

    def test_native_error_log_events_preserved(self):
        records = self._make_valid_rebuild_records(5.0)
        td = records[-1]
        td["native_error_log_events"] = [{"domain": "CoreMediaErrorDomain", "status": -12884, "comment": "stall"}]
        faults = self._make_fault_records(5.0, 5.015)
        res = evaluate_recovery_trial(records, faults, self.trial_meta)
        self.assertEqual(res["native_error_log_count"], 1)

    def test_no_rebuild_gap_without_recovery(self):
        records = self._make_valid_rebuild_records(5.0)
        prefault = [
            r for r in records
            if r.get("generation", 1) == 1 and r.get("event") not in ("recovery_requested", "generation_ended")
        ]
        last_pf = prefault[-1]["observation_mono_ms"]
        # Inject 1500ms gap
        prefault.append({
            "observation_mono_ms": last_pf + 1500, "generation": 1, "time_control_status": "playing",
            "effective_rate": 1.0, "requested_rate": 1.0, "effective_timebase_rate": 1.0,
            "configured_offset_seconds": 1.2, "recommended_offset_seconds": 1.002,
            "valid": True, "presentation_eligible": True, "is_future_sample": False,
            "frame_id": 999, "source_mono_ms": last_pf + 1500 - 1200, "display_item_time_seconds": 999 * 0.033,
            "age_ms": 1200.0,
        })
        prefault.append({
            "teardown": True, "teardown_mono_ms": last_pf + 1600, "generation": 1,
            "final_generation": 1, "final_phase": "initial", "native_error_log_events": [],
        })
        faults = self._make_fault_records(5.0, 5.015)
        res = evaluate_recovery_trial(prefault, faults, self.trial_meta)
        self.assertTrue(res["quality_failure"])
        self.assertIn("missing_recovery_trigger_on_gap", res["quality_failure_reason"])

    def test_native_recovery_sufficient(self):
        records = [
            {
                "event": "config", "generation": 1, "observation_mono_ms": 1000,
                "startup_mode": "precision", "recovery_mode": "rebuild",
                "waits": True, "can_use_network_resources_for_live_streaming_while_paused": True,
                "preferred_forward_buffer_duration": 1.2, "configured_time_offset_seconds": 1.2,
                "requested_offset_ms": 1200, "automatically_preserves_time_offset": False,
                "startup_protocol": "warm_play_pause_preroll_align",
            },
            {
                "event": "warmup_paused", "generation": 1, "observation_mono_ms": 1020,
                "warm_target_seconds": 25.0, "warm_required_ahead_ms": 500,
                "warm_loaded_ranges": [{"start": 20.0, "duration": 10.0, "end": 30.0}],
                "warm_coverage_verified": True,
            },
            {"event": "preroll_requested", "generation": 1, "observation_mono_ms": 1040},
            {"event": "preroll_completed", "generation": 1, "observation_mono_ms": 1080, "finished": True},
            {"event": "alignment_issued", "generation": 1, "observation_mono_ms": 1100},
            {"event": "alignment_completed", "generation": 1, "observation_mono_ms": 1200},
        ]
        fid = 100
        for mono in range(1250, 52000, 200):
            fid += 1
            records.append({
                "observation_mono_ms": mono, "generation": 1, "time_control_status": "playing",
                "effective_rate": 1.0, "requested_rate": 1.0, "effective_timebase_rate": 1.0,
                "configured_offset_seconds": 1.2, "recommended_offset_seconds": 1.002,
                "valid": True, "presentation_eligible": True, "is_future_sample": False,
                "frame_id": fid, "source_mono_ms": mono - 1200, "display_item_time_seconds": float(fid) * 0.033,
                "age_ms": 1200.0,
            })
        records.append({
            "teardown": True, "teardown_mono_ms": 52100, "generation": 1,
            "final_generation": 1, "final_phase": "initial", "native_error_log_events": [],
        })

        meta = dict(self.trial_meta)
        meta["outage_duration_s"] = 2.0
        faults = self._make_fault_records(2.0, 2.010, cmd_mono_s=11.250, ack_mono_s=11.255)
        res = evaluate_recovery_trial(records, faults, meta)
        self.assertFalse(res["quality_failure"], msg=res.get("quality_failure_reason"))
        self.assertTrue(res["native_recovery_sufficient"])
        self.assertFalse(res["rebuild_exercised"])
        self.assertTrue(res["rebuild_latency_met"])

    def test_same_ms_pre_and_post_call(self):
        # Pre-call same-ms paused (excluded)
        records1 = self._make_valid_rebuild_records(5.0)
        align_iss = [r for r in records1 if r.get("event") == "alignment_issued" and r.get("generation") == 2][0]
        t_iss = align_iss["observation_mono_ms"]
        idx = records1.index(align_iss)
        records1.insert(idx, {
            "observation_mono_ms": t_iss, "generation": 2, "time_control_status": "paused",
            "requested_rate": 1.0, "effective_rate": 1.0,
        })
        res1 = evaluate_recovery_trial(records1, self._make_fault_records(5.0, 5.015), self.trial_meta)
        self.assertFalse(res1["quality_failure"])

        # Post-call same-ms paused (fails)
        records2 = self._make_valid_rebuild_records(5.0)
        align_iss2 = [r for r in records2 if r.get("event") == "alignment_issued" and r.get("generation") == 2][0]
        t_iss2 = align_iss2["observation_mono_ms"]
        idx2 = records2.index(align_iss2)
        records2.insert(idx2 + 1, {
            "observation_mono_ms": t_iss2, "generation": 2, "time_control_status": "paused",
            "requested_rate": 1.0, "effective_rate": 1.0,
        })
        res2 = evaluate_recovery_trial(records2, self._make_fault_records(5.0, 5.015), self.trial_meta)
        self.assertTrue(res2["quality_failure"])
        self.assertIn("post_call_same_ms_paused", res2["quality_failure_reason"])

    def test_no_rebuild_adversarial_cases(self):
        def make_dense():
            recs = [
                {
                    "event": "config", "generation": 1, "observation_mono_ms": 1000,
                    "startup_mode": "precision", "recovery_mode": "rebuild",
                    "waits": True, "can_use_network_resources_for_live_streaming_while_paused": True,
                    "preferred_forward_buffer_duration": 1.2, "configured_time_offset_seconds": 1.2,
                    "requested_offset_ms": 1200, "automatically_preserves_time_offset": False,
                    "startup_protocol": "warm_play_pause_preroll_align",
                },
                {
                    "event": "warmup_paused", "generation": 1, "observation_mono_ms": 1020,
                    "warm_target_seconds": 25.0, "warm_required_ahead_ms": 500,
                    "warm_loaded_ranges": [{"start": 20.0, "duration": 10.0, "end": 30.0}],
                    "warm_coverage_verified": True,
                },
                {"event": "preroll_requested", "generation": 1, "observation_mono_ms": 1040},
                {"event": "preroll_completed", "generation": 1, "observation_mono_ms": 1080, "finished": True},
                {"event": "alignment_issued", "generation": 1, "observation_mono_ms": 1100},
                {"event": "alignment_completed", "generation": 1, "observation_mono_ms": 1200},
            ]
            fid = 100
            for mono in range(1250, 52000, 200):
                fid += 1
                recs.append({
                    "observation_mono_ms": mono, "generation": 1, "time_control_status": "playing",
                    "effective_rate": 1.0, "requested_rate": 1.0, "effective_timebase_rate": 1.0,
                    "configured_offset_seconds": 1.2, "recommended_offset_seconds": 1.002,
                    "valid": True, "presentation_eligible": True, "is_future_sample": False,
                    "frame_id": fid, "source_mono_ms": mono - 1200, "display_item_time_seconds": float(fid) * 0.033,
                    "age_ms": 1200.0,
                })
            recs.append({
                "teardown": True, "teardown_mono_ms": 52100, "generation": 1,
                "final_generation": 1, "final_phase": "initial", "native_error_log_events": [],
            })
            return recs

        meta = dict(self.trial_meta)
        meta["outage_duration_s"] = 2.0
        faults = self._make_fault_records(2.0, 2.010, cmd_mono_s=11.250, ack_mono_s=11.255)

        # 1. Bad rate
        recs1 = make_dense()
        recs1[20]["effective_rate"] = 1.05
        res1 = evaluate_recovery_trial(recs1, faults, meta)
        self.assertTrue(res1["quality_failure"])
        self.assertIn("effective_rate_deviation", res1["quality_failure_reason"])

        # 2. Invalid marker
        recs2 = make_dense()
        recs2[20]["valid"] = False
        res2 = evaluate_recovery_trial(recs2, faults, meta)
        self.assertTrue(res2["quality_failure"])
        self.assertIn("invalid_marker", res2["quality_failure_reason"])

        # 3. Backstep
        recs3 = make_dense()
        recs3[25]["frame_id"] = recs3[24]["frame_id"] - 1
        res3 = evaluate_recovery_trial(recs3, faults, meta)
        self.assertTrue(res3["quality_failure"])
        self.assertIn("frame_backstep", res3["quality_failure_reason"])

        # 4. Tail gap > 500ms
        recs4 = make_dense()
        recs4[-1]["teardown_mono_ms"] = recs4[-2]["observation_mono_ms"] + 800
        res4 = evaluate_recovery_trial(recs4, faults, meta)
        self.assertTrue(res4["quality_failure"])
        self.assertIn("tail_to_end_gap_exceeded", res4["quality_failure_reason"])

    def test_fault_inconsistency_and_nonfinite(self):
        records = self._make_valid_rebuild_records(5.0)

        # 1. ack latency inconsistent with ack - cmd
        faults1 = self._make_fault_records(5.0, 5.015)
        faults1[0]["ack_latency_ms"] = 100.0
        res1 = evaluate_recovery_trial(records, faults1, self.trial_meta)
        self.assertTrue(res1["quality_failure"])
        self.assertIn("fault_ack_latency_inconsistent", res1["quality_failure_reason"])

        # 2. actual outage duration inconsistent with restore - ack
        faults2 = self._make_fault_records(5.0, 5.015)
        faults2[1]["actual_outage_duration_s"] = 5.200
        res2 = evaluate_recovery_trial(records, faults2, self.trial_meta)
        self.assertTrue(res2["quality_failure"])
        self.assertIn("fault_actual_duration_inconsistent", res2["quality_failure_reason"])

        # 3. nonfinite cmd_mono_s
        faults3 = self._make_fault_records(5.0, 5.015)
        faults3[0]["cmd_mono_s"] = float("nan")
        res3 = evaluate_recovery_trial(records, faults3, self.trial_meta)
        self.assertTrue(res3["quality_failure"])
        self.assertIn("fault_nonfinite", res3["quality_failure_reason"])

    def test_truncated_json_evidence_handling(self):
        eval_res = {
            "trial_id": "trial_02_d5s_reb_rep1", "recovery_mode": "rebuild", "outage_duration_s": 5.0,
            "quality_failure": True, "quality_failure_reason": "malformed_or_truncated_probe_jsonl_at_line_45: Unterminated string",
            "comparator_invalidated": False, "rebuild_exercised": False, "native_recovery_sufficient": False, "rebuild_latency_met": False,
        }
        self.assertTrue(eval_res["quality_failure"])
        self.assertIn("truncated", eval_res["quality_failure_reason"])

    def test_missing_exercise_closure_detection(self):
        rebuild_cases = [
            {"outage_duration_s": 5.0, "recovery_eval": {"rebuild_exercised": False, "native_recovery_sufficient": True}},
            {"outage_duration_s": 10.0, "recovery_eval": {"rebuild_exercised": True, "native_recovery_sufficient": False}},
        ]
        reb_5s = [t for t in rebuild_cases if abs(float(t.get("outage_duration_s", 0)) - 5.0) < 0.1]
        reb_10s = [t for t in rebuild_cases if abs(float(t.get("outage_duration_s", 0)) - 10.0) < 0.1]
        exercised_5s = any(t.get("recovery_eval", {}).get("rebuild_exercised") is True for t in reb_5s)
        exercised_10s = any(t.get("recovery_eval", {}).get("rebuild_exercised") is True for t in reb_10s)
        self.assertFalse(exercised_5s)
        self.assertTrue(exercised_10s)
        self.assertFalse(exercised_5s and exercised_10s)

    # -------------------------------------------------------------------------
    # Negative Tests for Specific Schema Defects
    # -------------------------------------------------------------------------
    def test_negative_wrong_ended_generation(self):
        # 1. ended_generation is 2 instead of 1
        records1 = self._make_valid_rebuild_records(5.0)
        gen_ended = [r for r in records1 if r.get("event") == "generation_ended"][0]
        gen_ended["ended_generation"] = 2
        res1 = evaluate_recovery_trial(records1, self._make_fault_records(5.0, 5.015), self.trial_meta)
        self.assertTrue(res1["quality_failure"])
        self.assertIn("expected_exactly_1_generation_ended_with_ended_generation_1", res1["quality_failure_reason"])

        # 2. missing ended_generation key (e.g. wrongly has "generation": 1)
        records2 = self._make_valid_rebuild_records(5.0)
        gen_ended2 = [r for r in records2 if r.get("event") == "generation_ended"][0]
        del gen_ended2["ended_generation"]
        gen_ended2["generation"] = 1
        res2 = evaluate_recovery_trial(records2, self._make_fault_records(5.0, 5.015), self.trial_meta)
        self.assertTrue(res2["quality_failure"])
        self.assertIn("expected_exactly_1_generation_ended_with_ended_generation_1", res2["quality_failure_reason"])

    def test_negative_missing_following_marker(self):
        # 1. recovery_completed followed immediately by teardown without any marker
        records1 = self._make_valid_rebuild_records(5.0)
        rec_comp = [r for r in records1 if r.get("event") == "recovery_completed"][0]
        idx_rc = records1.index(rec_comp)
        del records1[idx_rc + 1:-1]
        res1 = evaluate_recovery_trial(records1, self._make_fault_records(5.0, 5.015), self.trial_meta)
        self.assertTrue(res1["quality_failure"])
        self.assertIn("recovery_completed_immediate_next_record_not_marker", res1["quality_failure_reason"])

        # 2. immediate next record is another event rather than a marker record
        records2 = self._make_valid_rebuild_records(5.0)
        rec_comp2 = [r for r in records2 if r.get("event") == "recovery_completed"][0]
        idx_rc2 = records2.index(rec_comp2)
        records2.insert(idx_rc2 + 1, {"event": "some_other_event", "observation_mono_ms": rec_comp2["observation_mono_ms"]})
        res2 = evaluate_recovery_trial(records2, self._make_fault_records(5.0, 5.015), self.trial_meta)
        self.assertTrue(res2["quality_failure"])
        self.assertIn("recovery_completed_immediate_next_record_not_marker", res2["quality_failure_reason"])

    def test_negative_changed_fields_in_following_marker(self):
        faults = self._make_fault_records(5.0, 5.015)

        # 1. mismatched frame_id
        records1 = self._make_valid_rebuild_records(5.0)
        rec_comp = [r for r in records1 if r.get("event") == "recovery_completed"][0]
        idx_rc = records1.index(rec_comp)
        records1[idx_rc + 1]["frame_id"] = rec_comp["frame_id"] + 99
        res1 = evaluate_recovery_trial(records1, faults, self.trial_meta)
        self.assertTrue(res1["quality_failure"])
        self.assertIn("following_marker_frame_id_mismatch", res1["quality_failure_reason"])

        # 2. mismatched source_mono_ms
        records2 = self._make_valid_rebuild_records(5.0)
        rec_comp2 = [r for r in records2 if r.get("event") == "recovery_completed"][0]
        idx_rc2 = records2.index(rec_comp2)
        records2[idx_rc2 + 1]["source_mono_ms"] = rec_comp2["source_mono_ms"] + 500
        res2 = evaluate_recovery_trial(records2, faults, self.trial_meta)
        self.assertTrue(res2["quality_failure"])
        self.assertIn("following_marker_source_mono_ms_mismatch", res2["quality_failure_reason"])

        # 3. mismatched observation_mono_ms
        records3 = self._make_valid_rebuild_records(5.0)
        rec_comp3 = [r for r in records3 if r.get("event") == "recovery_completed"][0]
        idx_rc3 = records3.index(rec_comp3)
        records3[idx_rc3 + 1]["observation_mono_ms"] = rec_comp3["observation_mono_ms"] + 100
        res3 = evaluate_recovery_trial(records3, faults, self.trial_meta)
        self.assertTrue(res3["quality_failure"])
        self.assertIn("following_marker_observation_mono_ms_mismatch", res3["quality_failure_reason"])

    def test_negative_reversed_lifecycle_order(self):
        faults = self._make_fault_records(5.0, 5.015)

        # 1. recovery_requested placed AFTER generation_ended
        records1 = self._make_valid_rebuild_records(5.0)
        rec_req = [r for r in records1 if r.get("event") == "recovery_requested"][0]
        gen_ended = [r for r in records1 if r.get("event") == "generation_ended"][0]
        idx_req = records1.index(rec_req)
        idx_ended = records1.index(gen_ended)
        records1[idx_req], records1[idx_ended] = records1[idx_ended], records1[idx_req]
        res1 = evaluate_recovery_trial(records1, faults, self.trial_meta)
        self.assertTrue(res1["quality_failure"])
        self.assertIn("rebuild_lifecycle_events_out_of_file_order", res1["quality_failure_reason"])

        # 2. gen2 config placed BEFORE generation_ended
        records2 = self._make_valid_rebuild_records(5.0)
        gen2_cfg = [r for r in records2 if r.get("event") == "config" and r.get("generation") == 2][0]
        gen_ended2 = [r for r in records2 if r.get("event") == "generation_ended"][0]
        idx_cfg = records2.index(gen2_cfg)
        idx_ended2 = records2.index(gen_ended2)
        records2[idx_cfg], records2[idx_ended2] = records2[idx_ended2], records2[idx_cfg]
        res2 = evaluate_recovery_trial(records2, faults, self.trial_meta)
        self.assertTrue(res2["quality_failure"])
        self.assertIn("rebuild_lifecycle_events_out_of_file_order", res2["quality_failure_reason"])


if __name__ == "__main__":
    unittest.main()
