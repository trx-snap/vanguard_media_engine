#!/usr/bin/env python3
"""
test_offset.py - Offline unittests for live offset A/B (1200ms vs 1002ms) analyzer and harness.
Covers:
- distinguishing decoded time from playing startup time
- fail-closed evidence: malformed JSON, nonfinite numbers, timestamp errors, missing records
- all config fields: forward buffer 1.2, preserves=True, waits=True, requested_offset_ms (1200/1002)
- 1002 precision within 0.000001 tolerance and config readback
- target mismatch and clamp negative outcome (departure > 0.005)
- non-CRC decode failures and teardown failure_count > 0
- nonzero exit code and timeout negative outcomes
- native errors and exact CoreMediaErrorDomain/-15410 advisory whitelist with exact comment equality
- offset change detection and diagnostics
- state waits mismatch detection
- teardown requested_offset_ms mismatch
- aggregate regressions: B-fail with invalid A, B-only sub-2s vs A>2, missing B cannot sub-2s,
  duplicate/wrong trial assignment, incomplete 20 blocks claims,
  8 small-negative + median <= -100 satisfies directional gate
- write failure propagation on summary output
- preserved prior tests: events exclusion, waiting frames exclusion, interruption paused outcome,
  access log 404/mixed h2, cancellation/reaping retention via mocks, import causes no output,
  results directory collision refusal
- actual mocked run_trials captures 20 commands correct ABBA / true / offsets
- warmup verification: valid mature bodies vs immature / changed PHB / cancellation using
  historical playlist fixture results_retry04/playlists.jsonl
"""

import sys
sys.dont_write_bytecode = True

import importlib.util
import json
import math
import os
import shutil
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock, patch

OLD_ROOT = "/private/tmp/vg-startup-auto-20261020-1338"
BASE_ROOT = "/private/tmp/vg-startup-h2-capture-20261020"
NEW_ROOT = "/private/tmp/vg-startup-offset-ab-20261020"

for p in (OLD_ROOT, BASE_ROOT, NEW_ROOT):
    if p not in sys.path:
        sys.path.insert(0, p)

import analyze_offset

run_spec = importlib.util.spec_from_file_location("offset_run", os.path.join(NEW_ROOT, "run.py"))
offset_run = importlib.util.module_from_spec(run_spec)
sys.modules["offset_run"] = offset_run
run_spec.loader.exec_module(offset_run)

HISTORICAL_PLAYLISTS = "/private/tmp/vg-startup-h2-capture-20261020/results_retry04/playlists.jsonl"


class TestOffsetAB(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix="test_offset_ab_")
        self.room_id = "test_room_123"
        self.run_id = "test_run_123"

    def tearDown(self):
        if os.path.exists(self.test_dir):
            shutil.rmtree(self.test_dir, ignore_errors=True)

    def _create_mock_access_log(self, trial_dir: str, include_404: bool = False, http1: bool = False):
        access_path = os.path.join(trial_dir, "access.log")
        proto, status = ("HTTP/1.1" if http1 else "HTTP/2.0"), (404 if include_404 else 200)
        lines = [
            f'2026-10-20T18:00:00.000Z client=127.0.0.1 protocol={proto} http3= ssl_proto=TLSv1.3 ssl_cipher=TLS_AES_256_GCM_SHA384 method=GET uri="/live/{self.room_id}/master.m3u8" status={status} bytes=500 request_time=0.002 ua="AppleCoreMedia/1.0" msec=1729447200.000 connection=1 request_id=abc1',
            f'2026-10-20T18:00:00.050Z client=127.0.0.1 protocol={proto} http3= ssl_proto=TLSv1.3 ssl_cipher=TLS_AES_256_GCM_SHA384 method=GET uri="/media/{self.run_id}/part0.mp4" status=200 bytes=15000 request_time=0.005 ua="AppleCoreMedia/1.0" msec=1729447200.050 connection=1 request_id=abc2',
        ]
        with open(access_path, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")

    def _build_full_probe_jsonl(
        self,
        trial_dir: str,
        arm: str = "A",
        waits: bool = True,
        offset_ms: int = None,
        probe_start_mono: int = 1000,
        startup_elapsed_ms: int = 200,
        strict_play_offset_ms: int = 150,
        settled_age_ms: float = 600.0,
        failure_count: int = 0,
        native_errors: list = None,
        config_override: dict = None,
        teardown_override: dict = None,
        extra_lines_after_teardown: list = None,
        malformed_json_line: str = None,
        nonfinite_val: float = None,
        invalid_marker: bool = False,
        state_waits_override: bool = None,
        sample_offset_override: float = None,
        add_offset_change: bool = False,
    ):
        if offset_ms is None:
            offset_ms = 1200 if arm == "A" else 1002
        probe_jsonl = os.path.join(trial_dir, "probe.jsonl")
        lines = []

        cfg = {
            "event": "config", "utc": "2026-10-20T18:00:00.000Z",
            "observation_mono_ms": probe_start_mono + 5, "waits": waits,
            "preferred_forward_buffer_duration": 1.2, "configured_time_offset_seconds": offset_ms / 1000.0,
            "requested_offset_ms": offset_ms, "automatically_preserves_time_offset": True,
        }
        if config_override:
            cfg.update(config_override)
        lines.append(json.dumps(cfg))
        if malformed_json_line:
            lines.append(malformed_json_line)

        st_waits = state_waits_override if state_waits_override is not None else waits
        lines.append(json.dumps({
            "event": "state", "utc": "2026-10-20T18:00:00.050Z", "observation_mono_ms": probe_start_mono + 50,
            "time_control_status": "waiting", "player_status": "readyToPlay",
            "reason_for_waiting_to_play": "AVPlayerWaitingToMinimizeStallsReason",
            "requested_rate": 1.0, "effective_rate": 0.0, "item_time_seconds": 0.0,
            "buffer_empty": True, "likely_to_keep_up": False, "waits": st_waits,
            "has_reached_playing": False, "nonplaying_transition_count": 0,
        }))
        lines.append(json.dumps({
            "event": "state", "utc": "2026-10-20T18:00:00.150Z", "observation_mono_ms": probe_start_mono + strict_play_offset_ms,
            "time_control_status": "playing", "player_status": "readyToPlay",
            "reason_for_waiting_to_play": "", "requested_rate": 1.0, "effective_rate": 1.0,
            "item_time_seconds": 0.1, "buffer_empty": False, "likely_to_keep_up": True,
            "waits": st_waits, "has_reached_playing": True, "nonplaying_transition_count": 0,
        }))

        conf_off = sample_offset_override if sample_offset_override is not None else (offset_ms / 1000.0)
        sample1 = {
            "utc": "2026-10-20T18:00:00.200Z", "observation_mono_ms": probe_start_mono + startup_elapsed_ms,
            "item_time_seconds": 0.15, "effective_timebase_rate": 1.0, "time_control_status": "playing",
            "player_status": "readyToPlay", "configured_offset_seconds": conf_off,
            "recommended_offset_seconds": offset_ms / 1000.0, "valid": not invalid_marker,
            "failure_count": failure_count, "frame_id": 1, "source_mono_ms": probe_start_mono - 400,
            "age_ms": 600, "item_date_age_ms": 610.0, "startup_elapsed_ms": startup_elapsed_ms,
        }
        if invalid_marker:
            sample1["error"] = "Buffer not portrait 9:16"
        if nonfinite_val is not None:
            sample1["configured_offset_seconds"] = nonfinite_val
        lines.append(json.dumps(sample1))

        sample2_offset = 1.8 if add_offset_change else conf_off
        sample2 = {
            "utc": "2026-10-20T18:00:06.200Z", "observation_mono_ms": probe_start_mono + startup_elapsed_ms + 5500,
            "item_time_seconds": 5.65, "effective_timebase_rate": 1.0, "time_control_status": "playing",
            "player_status": "readyToPlay", "configured_offset_seconds": sample2_offset,
            "recommended_offset_seconds": offset_ms / 1000.0, "valid": True,
            "failure_count": failure_count, "frame_id": 160,
            "source_mono_ms": probe_start_mono + startup_elapsed_ms + 5500 - int(settled_age_ms),
            "age_ms": int(settled_age_ms), "item_date_age_ms": settled_age_ms + 10.0,
            "startup_elapsed_ms": startup_elapsed_ms,
        }
        lines.append(json.dumps(sample2))

        td = {
            "teardown": True, "utc": "2026-10-20T18:00:15.000Z",
            "probe_start_mono_ms": probe_start_mono, "teardown_mono_ms": probe_start_mono + 15000,
            "first_valid_frame": True, "startup_elapsed_ms": startup_elapsed_ms,
            "first_effective_playing_mono_ms": probe_start_mono + strict_play_offset_ms,
            "nonplaying_transition_count": 0, "failure_count": failure_count,
            "waits": waits, "requested_offset_ms": offset_ms,
            "native_error_log_events": native_errors or [],
        }
        if teardown_override:
            td.update(teardown_override)
        lines.append(json.dumps(td))

        if extra_lines_after_teardown:
            lines.extend(extra_lines_after_teardown)

        with open(probe_jsonl, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")

    def test_distinguish_decoded_time_from_playing_time(self):
        trial_dir = os.path.join(self.test_dir, "trial_01")
        os.makedirs(trial_dir, exist_ok=True)
        self._create_mock_access_log(trial_dir)
        self._build_full_probe_jsonl(
            trial_dir, arm="A", waits=True, offset_ms=1200, probe_start_mono=1000,
            startup_elapsed_ms=250, strict_play_offset_ms=120
        )
        meta = {
            "trial_id": "trial_01", "trial_index": 1, "arm": "A", "pair_index": 1,
            "waits": True, "offset_ms": 1200, "exit_code": 0, "timed_out": False
        }
        res = analyze_offset.validate_and_summarize_trial(meta, self.test_dir, self.room_id, self.run_id)
        self.assertTrue(res["measurement_integrity"])
        self.assertTrue(res["playback_success"])
        self.assertEqual(res["startup_time_ms"], 120)
        self.assertEqual(res["time_to_first_decoded_ms"], 250)
        self.assertNotEqual(res["startup_time_ms"], res["time_to_first_decoded_ms"])
        self.assertEqual(res["startup_waiting_ms"], 70)

    def test_malformed_nonfinite_missing_evidence(self):
        d1 = os.path.join(self.test_dir, "t_malformed")
        os.makedirs(d1, exist_ok=True); self._create_mock_access_log(d1)
        self._build_full_probe_jsonl(d1, arm="A", malformed_json_line="NOT_JSON_CORRUPT_LINE")
        r1 = analyze_offset.validate_and_summarize_trial({"trial_id": "t_malformed", "trial_index": 1, "arm": "A", "pair_index": 1, "waits": True, "offset_ms": 1200}, self.test_dir, self.room_id, self.run_id)
        self.assertFalse(r1["measurement_integrity"])
        self.assertTrue(any("malformed_json" in s for s in r1["integrity_reasons"]))

        d2 = os.path.join(self.test_dir, "t_nonfinite")
        os.makedirs(d2, exist_ok=True); self._create_mock_access_log(d2)
        self._build_full_probe_jsonl(d2, arm="A", nonfinite_val=float("nan"))
        r2 = analyze_offset.validate_and_summarize_trial({"trial_id": "t_nonfinite", "trial_index": 1, "arm": "A", "pair_index": 1, "waits": True, "offset_ms": 1200}, self.test_dir, self.room_id, self.run_id)
        self.assertFalse(r2["measurement_integrity"])
        self.assertTrue(any("nonfinite_value" in s for s in r2["integrity_reasons"]))

        d3 = os.path.join(self.test_dir, "t_missing_probe")
        os.makedirs(d3, exist_ok=True); self._create_mock_access_log(d3)
        r3 = analyze_offset.validate_and_summarize_trial({"trial_id": "t_missing_probe", "trial_index": 1, "arm": "A", "pair_index": 1, "waits": True, "offset_ms": 1200}, self.test_dir, self.room_id, self.run_id)
        self.assertFalse(r3["measurement_integrity"])
        self.assertIn("missing_probe_jsonl", r3["integrity_reasons"])

    def test_all_config_fields(self):
        d1 = os.path.join(self.test_dir, "t_bad_buf")
        os.makedirs(d1, exist_ok=True); self._create_mock_access_log(d1)
        self._build_full_probe_jsonl(d1, arm="A", config_override={"preferred_forward_buffer_duration": 2.0})
        r1 = analyze_offset.validate_and_summarize_trial({"trial_id": "t_bad_buf", "trial_index": 1, "arm": "A", "pair_index": 1, "waits": True, "offset_ms": 1200}, self.test_dir, self.room_id, self.run_id)
        self.assertFalse(r1["measurement_integrity"])
        self.assertTrue(any("config_invalid_forward_buffer" in s for s in r1["integrity_reasons"]))

        d2 = os.path.join(self.test_dir, "t_bad_preserves")
        os.makedirs(d2, exist_ok=True); self._create_mock_access_log(d2)
        self._build_full_probe_jsonl(d2, arm="A", config_override={"automatically_preserves_time_offset": False})
        r2 = analyze_offset.validate_and_summarize_trial({"trial_id": "t_bad_preserves", "trial_index": 1, "arm": "A", "pair_index": 1, "waits": True, "offset_ms": 1200}, self.test_dir, self.room_id, self.run_id)
        self.assertFalse(r2["measurement_integrity"])
        self.assertTrue(any("config_invalid_preserves" in s for s in r2["integrity_reasons"]))

    def test_config_readback_and_precision_1002(self):
        d1 = os.path.join(self.test_dir, "t_b_exact")
        os.makedirs(d1, exist_ok=True); self._create_mock_access_log(d1)
        self._build_full_probe_jsonl(d1, arm="B", offset_ms=1002, config_override={"requested_offset_ms": 1002, "configured_time_offset_seconds": 1.0020000})
        r1 = analyze_offset.validate_and_summarize_trial({"trial_id": "t_b_exact", "trial_index": 2, "arm": "B", "pair_index": 1, "waits": True, "offset_ms": 1002, "exit_code": 0}, self.test_dir, self.room_id, self.run_id)
        self.assertTrue(r1["measurement_integrity"])

        d2 = os.path.join(self.test_dir, "t_b_imprecise")
        os.makedirs(d2, exist_ok=True); self._create_mock_access_log(d2)
        self._build_full_probe_jsonl(d2, arm="B", offset_ms=1002, config_override={"configured_time_offset_seconds": 1.002010})
        r2 = analyze_offset.validate_and_summarize_trial({"trial_id": "t_b_imprecise", "trial_index": 2, "arm": "B", "pair_index": 1, "waits": True, "offset_ms": 1002}, self.test_dir, self.room_id, self.run_id)
        self.assertFalse(r2["measurement_integrity"])
        self.assertTrue(any("config_invalid_offset" in s for s in r2["integrity_reasons"]))

    def test_target_mismatch_and_clamp_negative(self):
        d1 = os.path.join(self.test_dir, "t_clamp_negative")
        os.makedirs(d1, exist_ok=True)
        self._create_mock_access_log(d1)
        self._build_full_probe_jsonl(d1, arm="B", offset_ms=1002, sample_offset_override=1.200)
        res = analyze_offset.validate_and_summarize_trial(
            {"trial_id": "t_clamp_negative", "trial_index": 2, "arm": "B", "pair_index": 1, "waits": True, "offset_ms": 1002, "exit_code": 0},
            self.test_dir, self.room_id, self.run_id
        )
        self.assertTrue(res["measurement_integrity"])
        self.assertFalse(res["playback_success"])
        self.assertTrue(any("runtime_offset_departure" in s for s in res["negative_playback_reasons"]))

    def test_non_crc_decode_failure_and_teardown_failure_count(self):
        d1 = os.path.join(self.test_dir, "t_bad_marker")
        os.makedirs(d1, exist_ok=True)
        self._create_mock_access_log(d1)
        self._build_full_probe_jsonl(d1, arm="A", invalid_marker=True)
        r1 = analyze_offset.validate_and_summarize_trial(
            {"trial_id": "t_bad_marker", "trial_index": 1, "arm": "A", "pair_index": 1, "waits": True, "offset_ms": 1200},
            self.test_dir, self.room_id, self.run_id
        )
        self.assertFalse(r1["measurement_integrity"])
        self.assertTrue(any("invalid_marker_samples" in s for s in r1["integrity_reasons"]))

        d2 = os.path.join(self.test_dir, "t_bad_fc")
        os.makedirs(d2, exist_ok=True)
        self._create_mock_access_log(d2)
        self._build_full_probe_jsonl(d2, arm="A", failure_count=3)
        r2 = analyze_offset.validate_and_summarize_trial(
            {"trial_id": "t_bad_fc", "trial_index": 1, "arm": "A", "pair_index": 1, "waits": True, "offset_ms": 1200},
            self.test_dir, self.room_id, self.run_id
        )
        self.assertFalse(r2["measurement_integrity"])
        self.assertTrue(any("teardown_failure_count_3" in s for s in r2["integrity_reasons"]))

    def test_nonzero_exit_negative_outcome(self):
        d1 = os.path.join(self.test_dir, "t_nonzero_exit")
        os.makedirs(d1, exist_ok=True)
        self._create_mock_access_log(d1)
        self._build_full_probe_jsonl(d1, arm="B", offset_ms=1002)
        r1 = analyze_offset.validate_and_summarize_trial(
            {"trial_id": "t_nonzero_exit", "trial_index": 2, "arm": "B", "pair_index": 1, "waits": True, "offset_ms": 1002, "exit_code": 1},
            self.test_dir, self.room_id, self.run_id
        )
        self.assertTrue(r1["measurement_integrity"])
        self.assertFalse(r1["playback_success"])
        self.assertTrue(any("nonzero_exit_code_1" in s for s in r1["negative_playback_reasons"]))

    def test_native_errors_and_exact_advisory_whitelist(self):
        d1 = os.path.join(self.test_dir, "t_whitelisted")
        os.makedirs(d1, exist_ok=True)
        self._create_mock_access_log(d1)
        whitelisted_err = [{"domain": "CoreMediaErrorDomain", "status": -15410, "comment": "Server should support ECN for Low Latency", "date": ""}]
        self._build_full_probe_jsonl(d1, arm="A", native_errors=whitelisted_err)
        r1 = analyze_offset.validate_and_summarize_trial(
            {"trial_id": "t_whitelisted", "trial_index": 1, "arm": "A", "pair_index": 1, "waits": True, "offset_ms": 1200, "exit_code": 0},
            self.test_dir, self.room_id, self.run_id
        )
        self.assertTrue(r1["measurement_integrity"])
        self.assertTrue(r1["playback_success"])
        self.assertEqual(len(r1["non_whitelisted_native_errors"]), 0)

        d2 = os.path.join(self.test_dir, "t_suffix_rejected")
        os.makedirs(d2, exist_ok=True)
        self._create_mock_access_log(d2)
        suffix_err = [{"domain": "CoreMediaErrorDomain", "status": -15410, "comment": "Server should support ECN for Low Latency extra suffix", "date": ""}]
        self._build_full_probe_jsonl(d2, arm="A", native_errors=suffix_err)
        r2 = analyze_offset.validate_and_summarize_trial(
            {"trial_id": "t_suffix_rejected", "trial_index": 1, "arm": "A", "pair_index": 1, "waits": True, "offset_ms": 1200, "exit_code": 0},
            self.test_dir, self.room_id, self.run_id
        )
        self.assertTrue(r2["measurement_integrity"])
        self.assertFalse(r2["playback_success"])
        self.assertEqual(len(r2["non_whitelisted_native_errors"]), 1)

    def test_offset_changes_diagnostics(self):
        trial_dir = os.path.join(self.test_dir, "t_offset_change")
        os.makedirs(trial_dir, exist_ok=True)
        self._create_mock_access_log(trial_dir)
        self._build_full_probe_jsonl(trial_dir, arm="A", add_offset_change=True)
        res = analyze_offset.validate_and_summarize_trial(
            {"trial_id": "t_offset_change", "trial_index": 1, "arm": "A", "pair_index": 1, "waits": True, "offset_ms": 1200, "exit_code": 0},
            self.test_dir, self.room_id, self.run_id
        )
        self.assertTrue(res["offset_diagnostics"]["offset_changes_detected"])
        self.assertEqual(res["offset_diagnostics"]["distinct_configured_offsets"], [1.2, 1.8])

    def test_state_waits_mismatch(self):
        trial_dir = os.path.join(self.test_dir, "t_state_waits_mismatch")
        os.makedirs(trial_dir, exist_ok=True)
        self._create_mock_access_log(trial_dir)
        self._build_full_probe_jsonl(trial_dir, arm="A", waits=True, state_waits_override=False)
        res = analyze_offset.validate_and_summarize_trial(
            {"trial_id": "t_state_waits_mismatch", "trial_index": 1, "arm": "A", "pair_index": 1, "waits": True, "offset_ms": 1200, "exit_code": 0},
            self.test_dir, self.room_id, self.run_id
        )
        self.assertFalse(res["measurement_integrity"])
        self.assertTrue(any("state_waits_mismatch" in s for s in res["integrity_reasons"]))

    def test_teardown_not_terminal(self):
        trial_dir = os.path.join(self.test_dir, "t_td_not_last")
        os.makedirs(trial_dir, exist_ok=True)
        self._create_mock_access_log(trial_dir)
        extra = [json.dumps({"event": "state", "observation_mono_ms": 99999, "waits": True})]
        self._build_full_probe_jsonl(trial_dir, arm="A", extra_lines_after_teardown=extra)
        res = analyze_offset.validate_and_summarize_trial(
            {"trial_id": "t_td_not_last", "trial_index": 1, "arm": "A", "pair_index": 1, "waits": True, "offset_ms": 1200, "exit_code": 0},
            self.test_dir, self.room_id, self.run_id
        )
        self.assertFalse(res["measurement_integrity"])
        self.assertTrue(any("teardown_not_terminal" in s for s in res["integrity_reasons"]))

    def test_teardown_requested_offset_mismatch(self):
        trial_dir = os.path.join(self.test_dir, "t_td_off_mismatch")
        os.makedirs(trial_dir, exist_ok=True)
        self._create_mock_access_log(trial_dir)
        self._build_full_probe_jsonl(trial_dir, arm="A", offset_ms=1200, teardown_override={"requested_offset_ms": 1002})
        res = analyze_offset.validate_and_summarize_trial(
            {"trial_id": "t_td_off_mismatch", "trial_index": 1, "arm": "A", "pair_index": 1, "waits": True, "offset_ms": 1200, "exit_code": 0},
            self.test_dir, self.room_id, self.run_id
        )
        self.assertFalse(res["measurement_integrity"])
        self.assertTrue(any("teardown_mismatch_requested_offset_ms" in s for s in res["integrity_reasons"]))

    def test_b_fail_with_invalid_a_regression(self):
        trials = self._generate_20_trials()
        trials[0]["measurement_integrity"] = False
        trials[0]["playback_success"] = False
        trials[1]["measurement_integrity"] = True
        trials[1]["playback_success"] = False
        trials[1]["median_age_after_5s"] = None

        summary = analyze_offset.summarize_trials(trials)
        pair1 = summary["pairs"][0]
        self.assertFalse(pair1["is_clean_pair"])
        self.assertTrue(pair1["b_failed_with_invalid_a"])
        self.assertFalse(summary["directional_criteria_met"])
        self.assertEqual(summary["verdict"], "directional_improvement_rejected_additional_b_failures")

    def test_b_only_sub_2s_vs_a_greater_than_2(self):
        trials = self._generate_20_trials()
        for t in trials:
            t["median_age_after_5s"] = 2500.0 if t["arm"] == "A" else 1500.0
        summary = analyze_offset.summarize_trials(trials)
        self.assertTrue(summary["candidate_all_sub_2s"])

    def test_missing_b_cannot_sub_2s(self):
        trials = self._generate_20_trials()
        for t in trials:
            t["median_age_after_5s"] = 1500.0
        trials[1]["playback_success"] = False
        trials[1]["median_age_after_5s"] = None
        summary = analyze_offset.summarize_trials(trials)
        self.assertFalse(summary["candidate_all_sub_2s"])

    def test_duplicate_wrong_assignment_incomplete_20_blocks_claims(self):
        t19 = self._generate_20_trials()[:-1]
        s1 = analyze_offset.summarize_trials(t19)
        self.assertFalse(s1["complete_20_accounting"])
        self.assertFalse(s1["directional_criteria_met"])
        self.assertEqual(s1["verdict"], "incomplete_or_invalid_20_trial_accounting")

        t_dup = self._generate_20_trials()
        t_dup[1]["meta"]["trial_index"] = 1
        t_dup[1]["trial_index"] = 1
        s2 = analyze_offset.summarize_trials(t_dup)
        self.assertFalse(s2["complete_20_accounting"])
        self.assertFalse(s2["directional_criteria_met"])

    def test_eight_small_negative_and_median_le_minus_100_satisfies_gate(self):
        trials = self._generate_20_trials()
        deltas = [-100.0, -110.0, -120.0, -130.0, -140.0, -150.0, -160.0, -170.0]
        for p_idx in range(1, 9):
            t_a = next(t for t in trials if t["pair_index"] == p_idx and t["arm"] == "A")
            t_b = next(t for t in trials if t["pair_index"] == p_idx and t["arm"] == "B")
            t_a["median_age_after_5s"] = 1000.0
            t_b["median_age_after_5s"] = 1000.0 + deltas[p_idx - 1]

        for p_idx in (9, 10):
            t_a = next(t for t in trials if t["pair_index"] == p_idx and t["arm"] == "A")
            t_b = next(t for t in trials if t["pair_index"] == p_idx and t["arm"] == "B")
            t_a["median_age_after_5s"] = 1000.0
            t_b["median_age_after_5s"] = 1000.0

        summary = analyze_offset.summarize_trials(trials)
        self.assertEqual(summary["clean_pairs_count"], 10)
        self.assertEqual(summary["improving_pairs_count"], 8)
        self.assertLessEqual(summary["median_paired_delta_ms"], -100.0)
        self.assertTrue(summary["directional_criteria_met"])
        self.assertEqual(summary["verdict"], "directional_improvement_criteria_met")

    def test_invalid_b_integrity_blocks_improvement_claim(self):
        trials = self._generate_20_trials()
        deltas = [-100.0, -110.0, -120.0, -130.0, -140.0, -150.0, -160.0, -170.0]
        for p_idx in range(1, 9):
            t_a = next(t for t in trials if t["pair_index"] == p_idx and t["arm"] == "A")
            t_b = next(t for t in trials if t["pair_index"] == p_idx and t["arm"] == "B")
            t_a["median_age_after_5s"] = 1000.0
            t_b["median_age_after_5s"] = 1000.0 + deltas[p_idx - 1]

        # Pair 9: A is clean, B has measurement_integrity=False but playback_success=True
        t_b9 = next(t for t in trials if t["pair_index"] == 9 and t["arm"] == "B")
        t_b9["measurement_integrity"] = False
        t_b9["playback_success"] = True
        t_b9["median_age_after_5s"] = 800.0

        summary = analyze_offset.summarize_trials(trials)
        self.assertGreaterEqual(summary["clean_pairs_count"], 8)
        self.assertFalse(summary["directional_criteria_met"])
        self.assertEqual(summary["verdict"], "directional_improvement_blocked_invalid_b_quality")

    def test_probe_run_calibration_byte_identical_to_baseline(self):
        def extract_calib(path):
            with open(path, "r", encoding="utf-8") as f:
                lines = f.readlines()
            start, res = False, []
            for l in lines:
                if l.startswith("func runCalibration("):
                    start = True
                if start:
                    res.append(l)
                    if l.startswith("}"):
                        break
            return "".join(res)
        base_calib = extract_calib("/private/tmp/vg-startup-wait-ab-20261020/Probe.swift")
        new_calib = extract_calib(os.path.join(NEW_ROOT, "Probe.swift"))
        self.assertEqual(base_calib, new_calib)

    def test_write_failure_propagates(self):
        trials = self._generate_20_trials()
        invalid_path = "/nonexistent_dir_99999/nested/summary"
        with self.assertRaises((OSError, IOError)):
            analyze_offset.summarize_trials(trials, results_dir=invalid_path)

    def test_events_exclusion(self):
        trial_dir = os.path.join(self.test_dir, "t_ev_ex")
        os.makedirs(trial_dir, exist_ok=True)
        self._create_mock_access_log(trial_dir)
        self._build_full_probe_jsonl(trial_dir, arm="A", offset_ms=1200)

        meta = {"trial_id": "t_ev_ex", "trial_index": 1, "arm": "A", "pair_index": 1, "waits": True, "offset_ms": 1200, "exit_code": 0}
        res = analyze_offset.validate_and_summarize_trial(meta, self.test_dir, self.room_id, self.run_id)
        self.assertTrue(res["measurement_integrity"])
        self.assertEqual(res["total_marker_samples"], 2)
        self.assertEqual(res["playing_marker_samples"], 2)
        self.assertEqual(res["total_state_events"], 2)

    def test_waiting_frames_exclusion(self):
        trial_dir = os.path.join(self.test_dir, "t_wait_ex")
        os.makedirs(trial_dir, exist_ok=True)
        self._create_mock_access_log(trial_dir)
        probe_jsonl = os.path.join(trial_dir, "probe.jsonl")
        lines = [
            json.dumps({"event": "config", "utc": "2026-10-20T18:00:00Z", "observation_mono_ms": 1000, "waits": True, "preferred_forward_buffer_duration": 1.2, "configured_time_offset_seconds": 1.002, "requested_offset_ms": 1002, "automatically_preserves_time_offset": True}),
            json.dumps({"event": "state", "observation_mono_ms": 1050, "time_control_status": "playing", "effective_rate": 1.0, "waits": True}),
            json.dumps({"utc": "2026-10-20T18:00:01Z", "observation_mono_ms": 1100, "valid": True, "time_control_status": "waiting", "effective_timebase_rate": 0.0, "frame_id": 1, "age_ms": 9999, "configured_offset_seconds": 1.002}),
            json.dumps({"utc": "2026-10-20T18:00:02Z", "observation_mono_ms": 1200, "valid": True, "time_control_status": "playing", "effective_timebase_rate": 1.0, "frame_id": 2, "age_ms": 500, "configured_offset_seconds": 1.002}),
            json.dumps({"utc": "2026-10-20T18:00:08Z", "observation_mono_ms": 7000, "valid": True, "time_control_status": "playing", "effective_timebase_rate": 1.0, "frame_id": 150, "age_ms": 510, "configured_offset_seconds": 1.002}),
            json.dumps({"teardown": True, "startup_elapsed_ms": 200, "first_valid_frame": True, "probe_start_mono_ms": 1000, "failure_count": 0, "waits": True, "requested_offset_ms": 1002}),
        ]
        with open(probe_jsonl, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")

        meta = {"trial_id": "t_wait_ex", "trial_index": 2, "arm": "B", "pair_index": 1, "waits": True, "offset_ms": 1002, "exit_code": 0}
        res = analyze_offset.validate_and_summarize_trial(meta, self.test_dir, self.room_id, self.run_id)
        self.assertTrue(res["measurement_integrity"])
        self.assertEqual(res["total_marker_samples"], 3)
        self.assertEqual(res["playing_marker_samples"], 2)
        self.assertEqual(res["first_age_ms"], 500)
        self.assertEqual(res["median_age_after_5s"], 510.0)

    def test_interruption_paused_outcome(self):
        trial_dir = os.path.join(self.test_dir, "t_paused")
        os.makedirs(trial_dir, exist_ok=True)
        self._create_mock_access_log(trial_dir)
        probe_jsonl = os.path.join(trial_dir, "probe.jsonl")
        lines = [
            json.dumps({"event": "config", "waits": True, "utc": "2026-10-20T18:00:00Z", "observation_mono_ms": 1000, "preferred_forward_buffer_duration": 1.2, "configured_time_offset_seconds": 1.002, "requested_offset_ms": 1002, "automatically_preserves_time_offset": True}),
            json.dumps({"event": "state", "observation_mono_ms": 1100, "time_control_status": "playing", "effective_rate": 1.0, "waits": True}),
            json.dumps({"event": "state", "observation_mono_ms": 2000, "time_control_status": "paused", "effective_rate": 0.0, "waits": True}),
            json.dumps({"utc": "2026-10-20T18:00:01Z", "observation_mono_ms": 1100, "valid": True, "time_control_status": "playing", "effective_timebase_rate": 1.0, "frame_id": 1, "age_ms": 400, "configured_offset_seconds": 1.002}),
            json.dumps({"utc": "2026-10-20T18:00:07Z", "observation_mono_ms": 7000, "valid": True, "time_control_status": "playing", "effective_timebase_rate": 1.0, "frame_id": 150, "age_ms": 410, "configured_offset_seconds": 1.002}),
            json.dumps({"teardown": True, "startup_elapsed_ms": 100, "first_valid_frame": True, "probe_start_mono_ms": 1000, "failure_count": 0, "waits": True, "requested_offset_ms": 1002}),
        ]
        with open(probe_jsonl, "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")

        meta = {"trial_id": "t_paused", "trial_index": 3, "arm": "B", "pair_index": 2, "waits": True, "offset_ms": 1002, "exit_code": 0}
        res = analyze_offset.validate_and_summarize_trial(meta, self.test_dir, self.room_id, self.run_id)
        self.assertTrue(res["measurement_integrity"])
        self.assertFalse(res["playback_success"])
        self.assertEqual(res["post_first_playing_interruption_count"], 1)

    def test_access_log_404_and_mixed_h2(self):
        d1 = os.path.join(self.test_dir, "t_404")
        os.makedirs(d1, exist_ok=True)
        self._create_mock_access_log(d1, include_404=True)
        self._build_full_probe_jsonl(d1, arm="A", offset_ms=1200)
        r1 = analyze_offset.validate_and_summarize_trial(
            {"trial_id": "t_404", "trial_index": 1, "arm": "A", "pair_index": 1, "waits": True, "offset_ms": 1200},
            self.test_dir, self.room_id, self.run_id
        )
        self.assertFalse(r1["measurement_integrity"])

        d2 = os.path.join(self.test_dir, "t_mixed")
        os.makedirs(d2, exist_ok=True)
        self._create_mock_access_log(d2, http1=True)
        self._build_full_probe_jsonl(d2, arm="A", offset_ms=1200)
        r2 = analyze_offset.validate_and_summarize_trial(
            {"trial_id": "t_mixed", "trial_index": 1, "arm": "A", "pair_index": 1, "waits": True, "offset_ms": 1200},
            self.test_dir, self.room_id, self.run_id
        )
        self.assertFalse(r2["measurement_integrity"])

    def test_cancellation_and_reaping_retention_via_mocks(self):
        harness = offset_run.StartupOffsetABHarness(nonce=12345)
        self.assertIsNone(harness.cancelled_signal)
        harness.check_cancellation()

        harness.cancelled_signal = signal.SIGINT
        with self.assertRaises(offset_run.base_module.HarnessCancelledError):
            harness.check_cancellation()

        mock_proc = MagicMock()
        mock_proc.pid = 99999
        mock_proc.poll.return_value = None
        mock_proc.wait.side_effect = subprocess.TimeoutExpired(cmd="Probe", timeout=2)

        harness.probe_proc = mock_proc
        harness.cancelled_signal = None
        harness.tested_probe_bin = "/nonexistent/Probe"

        with patch.object(offset_run, "NEW_RESULTS_DIR", self.test_dir):
            with patch("subprocess.Popen", return_value=mock_proc):
                with patch("time.sleep"):
                    with patch("time.monotonic", side_effect=[0.0, 55.0, 55.0, 55.0, 55.0, 55.0]):
                        with self.assertRaises(RuntimeError) as cm:
                            harness.run_trials()
                        self.assertIn("unconfirmed reaping", str(cm.exception))
                        self.assertIsNotNone(harness.probe_proc)

    def test_import_causes_no_output(self):
        cmd = [
            sys.executable, "-B", "-c",
            "import sys; sys.path.insert(0, '/private/tmp/vg-startup-offset-ab-20261020'); import analyze_offset; import run"
        ]
        res = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(res.returncode, 0)
        self.assertEqual(res.stdout, "")
        self.assertEqual(res.stderr, "")

    def test_results_collision(self):
        harness = offset_run.StartupOffsetABHarness(nonce=99999)
        test_res_dir = os.path.join(self.test_dir, "existing_results")
        os.makedirs(test_res_dir, exist_ok=True)

        with patch.object(offset_run.base_module, "NEW_RESULTS_DIR", test_res_dir):
            with self.assertRaises(RuntimeError) as cm:
                harness.acquire_results_directory()
            self.assertIn("already exists", str(cm.exception))
            self.assertTrue(os.path.exists(test_res_dir))

    def test_mocked_run_trials_captures_20_commands_correct_abba_true_offsets(self):
        harness = offset_run.StartupOffsetABHarness(nonce=54321)
        harness.tested_probe_bin = "/mock/Probe"
        captured = []

        def mock_popen(cmd, **kwargs):
            captured.append(cmd)
            proc = MagicMock(pid=12345 + len(captured))
            proc.poll.return_value = 0
            proc.wait.return_value = 0
            return proc

        with patch.object(offset_run, "NEW_RESULTS_DIR", self.test_dir):
            with patch("subprocess.Popen", side_effect=mock_popen):
                with patch("time.sleep"):
                    harness.run_trials()

        self.assertEqual(len(captured), 20)
        pattern = ["A", "B", "B", "A"] * 5
        for i, cmd in enumerate(captured):
            expected_arm = pattern[i]
            expected_offset = "1200" if expected_arm == "A" else "1002"
            self.assertEqual(cmd[cmd.index("--waits") + 1], "true")
            self.assertEqual(cmd[cmd.index("--offset-ms") + 1], expected_offset)

        self.assertEqual(len(harness.trials_meta), 20)
        for i, meta in enumerate(harness.trials_meta):
            self.assertTrue(meta["waits"])
            exp_arm = pattern[i]
            self.assertEqual(meta["arm"], exp_arm)
            self.assertEqual(meta["offset_ms"], 1200 if exp_arm == "A" else 1002)

    def test_warmup_verification_mature_vs_immature_and_changed_phb(self):
        with open(HISTORICAL_PLAYLISTS, "r", encoding="utf-8") as f:
            lines = [json.loads(line) for line in f if line.strip()]

        audio_body = next(r["body_text"] for r in lines if r.get("role") == "audio" and r.get("is_initial"))
        video_body = next(r["body_text"] for r in lines if r.get("role") == "video" and r.get("is_initial"))

        harness = offset_run.StartupOffsetABHarness(nonce=77777)
        harness.results_acquired = True

        class MockResp:
            def __init__(self, text, status=200):
                self.text, self.status = text, status
            def read(self):
                return self.text.encode("utf-8")
            def __enter__(self):
                return self
            def __exit__(self, *args):
                pass

        def mock_urlopen(req, timeout=None, context=None):
            url = req.full_url
            if "vhi.m3u8" in url:
                return MockResp(video_body)
            elif "a.m3u8" in url:
                return MockResp(audio_body)
            return MockResp("", 404)

        with patch.object(offset_run, "NEW_RESULTS_DIR", self.test_dir), \
             patch.object(offset_run.base_module, "NEW_RESULTS_DIR", self.test_dir):
            with patch("urllib.request.urlopen", side_effect=mock_urlopen):
                harness.verify_stream_parameters_and_warmup()

            self.assertTrue(os.path.exists(os.path.join(self.test_dir, "pretrial_video.m3u8")))
            self.assertTrue(os.path.exists(os.path.join(self.test_dir, "pretrial_audio.m3u8")))
            events_path = os.path.join(self.test_dir, "events.jsonl")
            self.assertTrue(os.path.exists(events_path))
            with open(events_path, "r", encoding="utf-8") as ef:
                ev_records = [json.loads(line) for line in ef if line.strip()]
            warmup_evs = [ev for ev in ev_records if ev.get("event") == "warmup_verified"]
            self.assertEqual(len(warmup_evs), 1)
            self.assertEqual(warmup_evs[0]["can_block_reload"], "YES")
            self.assertEqual(warmup_evs[0]["video_part_hold_back"], 1.002)

        bad_phb_video = video_body.replace("PART-HOLD-BACK=1.002", "PART-HOLD-BACK=1.500")
        with patch.object(offset_run, "NEW_RESULTS_DIR", self.test_dir):
            with patch("urllib.request.urlopen", side_effect=lambda req, **kw: MockResp(bad_phb_video) if "vhi.m3u8" in req.full_url else MockResp(audio_body)):
                with self.assertRaises(RuntimeError) as cm:
                    harness.verify_stream_parameters_and_warmup()
                self.assertIn("PART-HOLD-BACK", str(cm.exception))

        # 2b. Nonfinite (NaN / Inf) PART-HOLD-BACK rejection
        for bad_val in ("nan", "inf"):
            bad_nonfinite = video_body.replace("PART-HOLD-BACK=1.002", f"PART-HOLD-BACK={bad_val}")
            with patch.object(offset_run, "NEW_RESULTS_DIR", self.test_dir):
                with patch("urllib.request.urlopen", side_effect=lambda req, **kw: MockResp(bad_nonfinite) if "vhi.m3u8" in req.full_url else MockResp(audio_body)):
                    with self.assertRaises(RuntimeError) as cm:
                        harness.verify_stream_parameters_and_warmup()
                    self.assertIn("nonfinite", str(cm.exception))

        bad_cbr_video = video_body.replace("CAN-BLOCK-RELOAD=YES", "CAN-BLOCK-RELOAD=NO")
        with patch.object(offset_run, "NEW_RESULTS_DIR", self.test_dir):
            with patch("urllib.request.urlopen", side_effect=lambda req, **kw: MockResp(bad_cbr_video) if "vhi.m3u8" in req.full_url else MockResp(audio_body)):
                with self.assertRaises(RuntimeError) as cm:
                    harness.verify_stream_parameters_and_warmup()
                self.assertIn("CAN-BLOCK-RELOAD", str(cm.exception))

        immature_video = "#EXTM3U\n#EXT-X-VERSION:9\n#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=1.002\n#EXT-X-PROGRAM-DATE-TIME:2026-10-20T18:00:00Z\n#EXTINF:2.0,\nseg1.mp4\n"
        clock = [0.0]
        def advance_clock():
            clock[0] += 16.0
            return clock[0]

        with patch.object(offset_run, "NEW_RESULTS_DIR", self.test_dir):
            with patch("urllib.request.urlopen", side_effect=lambda req, **kw: MockResp(immature_video) if "vhi.m3u8" in req.full_url else MockResp(audio_body)):
                with patch("time.sleep"):
                    with patch("time.monotonic", side_effect=advance_clock):
                        with self.assertRaises(RuntimeError) as cm:
                            harness.verify_stream_parameters_and_warmup()
                        self.assertIn("Timed out after 45s", str(cm.exception))

        # 4b. Exhausted shared budget before completion aborts
        fast_clock = [0.0]
        def advance_fast():
            fast_clock[0] += 25.0
            return fast_clock[0]

        with patch.object(offset_run, "NEW_RESULTS_DIR", self.test_dir):
            with patch("urllib.request.urlopen", side_effect=mock_urlopen):
                with patch("time.sleep"):
                    with patch("time.monotonic", side_effect=advance_fast):
                        with self.assertRaises(RuntimeError) as cm:
                            harness.verify_stream_parameters_and_warmup()
                        self.assertIn("Timed out after 45s", str(cm.exception))

        harness.cancelled_signal = signal.SIGINT
        with patch.object(offset_run, "NEW_RESULTS_DIR", self.test_dir):
            with self.assertRaises(offset_run.base_module.HarnessCancelledError):
                harness.verify_stream_parameters_and_warmup()

    def _generate_20_trials(self):
        pattern = ["A", "B", "B", "A"] * 5
        trials = []
        for idx in range(1, 21):
            arm = pattern[idx - 1]
            pair_idx = (idx - 1) // 2 + 1
            waits = True
            offset_ms = 1200 if arm == "A" else 1002
            trials.append({
                "trial_id": f"trial_{idx:02d}", "trial_index": idx, "arm": arm,
                "pair_index": pair_idx, "waits": waits, "offset_ms": offset_ms,
                "measurement_integrity": True, "playback_success": True,
                "median_age_after_5s": 500.0, "startup_time_ms": 150,
                "meta": {
                    "trial_id": f"trial_{idx:02d}", "trial_index": idx, "arm": arm,
                    "pair_index": pair_idx, "waits": waits, "offset_ms": offset_ms,
                }
            })
        return trials


if __name__ == "__main__":
    unittest.main()
