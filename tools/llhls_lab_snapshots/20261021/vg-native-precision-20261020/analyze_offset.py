#!/usr/bin/env python3
"""
analyze_offset.py - Pure analyzer for AVPlayer live offset (1200ms vs 1002ms) experiment.
Evaluates startup waiting duration, post-first-playing interruptions at 50ms resolution,
settled decode age after 5s, paired B-A deltas, and directional acceptance gates.
"""

import sys
sys.dont_write_bytecode = True

from datetime import datetime, timezone
import json
import math
import os

BASE_ROOT = "/private/tmp/vg-startup-h2-capture-20261020"
if BASE_ROOT not in sys.path:
    sys.path.insert(0, BASE_ROOT)

import analyze

parse_access_log_slice = analyze.parse_access_log_slice
calc_median = analyze.calc_median
calc_p95 = analyze.calc_p95


def _has_nonfinite(obj) -> bool:
    if isinstance(obj, float):
        return math.isnan(obj) or math.isinf(obj)
    if isinstance(obj, dict):
        return any(_has_nonfinite(v) for v in obj.values())
    if isinstance(obj, list):
        return any(_has_nonfinite(v) for v in obj)
    return False


def validate_and_summarize_trial(
    meta: dict,
    results_dir: str,
    room_id: str,
    run_id: str,
) -> dict:
    """
    Validates trial data and extracts startup waiting, post-first-playing interruptions,
    and settled marker age statistics for live offset A/B trials.
    Separates measurement integrity (fail-closed data validity) from playback outcome.
    """
    trial_id = meta.get("trial_id", f"trial_{meta.get('trial_index', 0):02d}")
    trial_dir = os.path.join(results_dir, trial_id)
    probe_path = os.path.join(trial_dir, "probe.jsonl")
    access_path = os.path.join(trial_dir, "access.log")

    integrity_reasons = []

    arm = meta.get("arm")
    intended_offset_ms = 1200 if arm == "A" else (1002 if arm == "B" else None)
    intended_offset_s = (intended_offset_ms / 1000.0) if intended_offset_ms is not None else None

    # Metadata checks: waits must be True for both arms; offset_ms must match arm target
    meta_waits = meta.get("waits")
    if meta_waits is not True:
        integrity_reasons.append(f"meta_waits_mismatch_{meta_waits}_expected_True")

    meta_offset_ms = meta.get("offset_ms")
    if intended_offset_ms is not None and meta_offset_ms != intended_offset_ms:
        integrity_reasons.append(f"meta_offset_ms_mismatch_{meta_offset_ms}_expected_{intended_offset_ms}")

    # 1. Frontend access log verification
    access_info = parse_access_log_slice(
        access_path,
        room_id,
        run_id=run_id,
        trial_launch_epoch_s=meta.get("launch_epoch_s"),
        trial_end_epoch_s=meta.get("end_epoch_s"),
    )
    if not access_info.get("exists", False):
        integrity_reasons.append("missing_access_log")
    else:
        if access_info.get("master_h2_200", 0) < 1:
            integrity_reasons.append("missing_h2_master")
        if access_info.get("media_h2_200", 0) < 1:
            integrity_reasons.append("missing_h2_media")
        if access_info.get("non_h2_protocols"):
            integrity_reasons.append(f"mixed_transport_{access_info['non_h2_protocols']}")
        if access_info.get("startup_failures"):
            integrity_reasons.append(f"access_startup_failures_{len(access_info['startup_failures'])}")

    # 2. Probe JSONL fail-closed verification & parsing
    config_records = []
    teardown_records = []
    state_events = []
    marker_samples = []
    invalid_marker_samples = []
    total_non_empty_lines = 0

    if not os.path.isfile(probe_path):
        integrity_reasons.append("missing_probe_jsonl")
    else:
        with open(probe_path, "r", encoding="utf-8", errors="replace") as f:
            for line_idx, raw_line in enumerate(f, 1):
                line_str = raw_line.strip()
                if not line_str:
                    continue
                total_non_empty_lines += 1

                try:
                    record = json.loads(line_str)
                except Exception as e:
                    integrity_reasons.append(f"malformed_json_line_{line_idx}_{e}")
                    continue

                if not isinstance(record, dict):
                    integrity_reasons.append(f"invalid_record_shape_line_{line_idx}")
                    continue

                if _has_nonfinite(record):
                    integrity_reasons.append(f"nonfinite_value_line_{line_idx}")

                if "utc" in record and isinstance(record["utc"], str):
                    ts_str = record["utc"].strip()
                    if ts_str.endswith("Z"):
                        ts_str = ts_str[:-1] + "+00:00"
                    try:
                        _ = datetime.fromisoformat(ts_str)
                    except Exception:
                        integrity_reasons.append(f"invalid_utc_timestamp_line_{line_idx}")

                if "event" in record:
                    ev_type = record.get("event")
                    if ev_type == "config":
                        config_records.append((line_idx, record))
                    elif ev_type == "state":
                        state_events.append((line_idx, record))
                    else:
                        integrity_reasons.append(f"unknown_event_{ev_type}_line_{line_idx}")
                    continue

                if record.get("teardown") is True or "teardown" in record:
                    teardown_records.append((line_idx, record))
                    continue

                # Sample record
                marker_samples.append((line_idx, record))
                if record.get("valid") is not True:
                    invalid_marker_samples.append((line_idx, record))

    # Validate structural requirements
    config_record = None
    if len(config_records) != 1:
        integrity_reasons.append(f"config_event_count_{len(config_records)}_expected_1")
    else:
        config_record = config_records[0][1]
        cfg_waits = config_record.get("waits")
        if cfg_waits is not True:
            integrity_reasons.append(f"config_mismatch_waits_{cfg_waits}_vs_True")

        cfg_req_offset = config_record.get("requested_offset_ms")
        if intended_offset_ms is not None and cfg_req_offset != intended_offset_ms:
            integrity_reasons.append(
                f"config_mismatch_requested_offset_ms_{cfg_req_offset}_vs_{intended_offset_ms}"
            )

        cfg_offset = config_record.get("configured_time_offset_seconds")
        if intended_offset_s is not None:
            if (
                cfg_offset is None
                or not isinstance(cfg_offset, (int, float))
                or abs(float(cfg_offset) - intended_offset_s) > 0.000001
            ):
                integrity_reasons.append(f"config_invalid_offset_{cfg_offset}_vs_{intended_offset_s}")

        cfg_buf = config_record.get("preferred_forward_buffer_duration")
        if (
            cfg_buf is None
            or not isinstance(cfg_buf, (int, float))
            or abs(float(cfg_buf) - 1.2) > 0.000001
        ):
            integrity_reasons.append(f"config_invalid_forward_buffer_{cfg_buf}")

        cfg_preserves = config_record.get("automatically_preserves_time_offset")
        if cfg_preserves is not True:
            integrity_reasons.append(f"config_invalid_preserves_{cfg_preserves}")

    teardown_record = None
    if len(teardown_records) != 1:
        integrity_reasons.append(f"teardown_count_{len(teardown_records)}_expected_1")
    else:
        td_line_idx, teardown_record = teardown_records[0]
        if td_line_idx != total_non_empty_lines:
            integrity_reasons.append(f"teardown_not_terminal_line_{td_line_idx}_of_{total_non_empty_lines}")

        td_waits = teardown_record.get("waits")
        if td_waits is not True:
            integrity_reasons.append(f"teardown_mismatch_waits_{td_waits}_vs_True")

        td_req_offset = teardown_record.get("requested_offset_ms")
        if intended_offset_ms is not None and td_req_offset != intended_offset_ms:
            integrity_reasons.append(
                f"teardown_mismatch_requested_offset_ms_{td_req_offset}_vs_{intended_offset_ms}"
            )

        td_failures = teardown_record.get("failure_count", 0)
        if td_failures is not None and td_failures > 0:
            integrity_reasons.append(f"teardown_failure_count_{td_failures}")

    if len(state_events) == 0:
        integrity_reasons.append("empty_state_lane")
    else:
        for st_ln, st_rec in state_events:
            st_waits = st_rec.get("waits")
            if st_waits is not True:
                integrity_reasons.append(f"state_waits_mismatch_line_{st_ln}")
                break

    if len(invalid_marker_samples) > 0:
        integrity_reasons.append(f"invalid_marker_samples_count_{len(invalid_marker_samples)}")

    measurement_integrity = (len(integrity_reasons) == 0)

    # 3. State events analysis (50ms polling resolution)
    state_list = [rec for _, rec in state_events]
    sample_list = [rec for _, rec in marker_samples]

    # Startup waiting: time from first observed state to first strict playing state
    first_strict_playing_idx = None
    for idx, ev in enumerate(state_list):
        tc = ev.get("time_control_status")
        eff = ev.get("effective_rate", 0.0) or 0.0
        if tc == "playing" and abs(eff - 1.0) <= 0.005:
            first_strict_playing_idx = idx
            break

    startup_waiting_ms = None
    startup_time_ms = None
    startup_time_unavailable_reason = None

    if first_strict_playing_idx is not None and len(state_list) > 0:
        t_start_state = state_list[0].get("observation_mono_ms", 0)
        t_strict_play = state_list[first_strict_playing_idx].get("observation_mono_ms", 0)
        startup_waiting_ms = max(0, t_strict_play - t_start_state)
        initial_reasons = [
            ev.get("reason_for_waiting_to_play")
            for ev in state_list[:first_strict_playing_idx]
            if ev.get("reason_for_waiting_to_play")
        ]

        if teardown_record and teardown_record.get("probe_start_mono_ms") is not None:
            probe_start_mono = teardown_record["probe_start_mono_ms"]
            startup_time_ms = max(0, t_strict_play - probe_start_mono)
        else:
            startup_time_unavailable_reason = "missing_probe_start_mono_ms"
    else:
        initial_reasons = [
            ev.get("reason_for_waiting_to_play")
            for ev in state_list
            if ev.get("reason_for_waiting_to_play")
        ]
        startup_time_unavailable_reason = "never_reached_strict_playing"

    time_to_first_decoded_ms = (
        teardown_record.get("startup_elapsed_ms") if teardown_record else None
    )

    # Post-first-playing interruptions: transitions away from strict playing
    post_first_playing_interruption_count = 0
    if first_strict_playing_idx is not None:
        was_playing = True
        for ev in state_list[first_strict_playing_idx + 1:]:
            tc = ev.get("time_control_status")
            eff = ev.get("effective_rate", 0.0) or 0.0
            is_playing = (tc == "playing" and abs(eff - 1.0) <= 0.005)
            if was_playing and not is_playing:
                post_first_playing_interruption_count += 1
                was_playing = False
            elif not was_playing and is_playing:
                was_playing = True

    # 4. Marker samples analysis (playing status and effective within 0.005 of 1.0)
    playing_samples = [
        s for s in sample_list
        if s.get("time_control_status") == "playing"
        and abs((s.get("effective_timebase_rate") or 0.0) - 1.0) <= 0.005
        and s.get("valid") is True
    ]

    first_age_ms = playing_samples[0].get("age_ms") if playing_samples else None

    median_age_after_5s = None
    p95_age_after_5s = None
    if playing_samples:
        t_first = playing_samples[0].get("observation_mono_ms", 0)
        settled_samples = [
            s for s in playing_samples
            if s.get("observation_mono_ms", 0) >= t_first + 5000
        ]
        if settled_samples:
            settled_ages = [s["age_ms"] for s in settled_samples if "age_ms" in s]
            median_age_after_5s = calc_median(settled_ages)
            p95_age_after_5s = calc_p95(settled_ages)

    native_pdt_ages = [
        s["item_date_age_ms"] for s in playing_samples
        if s.get("item_date_age_ms") is not None
    ]
    median_native_pdt_age_ms = calc_median(native_pdt_ages)

    # Retain ALL distinct sample configured and recommended offsets & detect runtime departures
    all_conf_offsets = sorted(list(set(
        s["configured_offset_seconds"]
        for s in sample_list
        if s.get("configured_offset_seconds") is not None
    )))
    all_rec_offsets = sorted(list(set(
        s["recommended_offset_seconds"]
        for s in sample_list
        if s.get("recommended_offset_seconds") is not None
    )))

    # Any runtime departure from intendedoffset > 0.005 is a negative playback outcome (native clamp/fallback)
    offset_departures = []
    if intended_offset_s is not None:
        for off in all_conf_offsets:
            if abs(float(off) - intended_offset_s) > 0.005:
                offset_departures.append(off)

    offset_diagnostics = {
        "intended_offset_seconds": intended_offset_s,
        "distinct_configured_offsets": all_conf_offsets,
        "distinct_recommended_offsets": all_rec_offsets,
        "offset_changes_detected": (len(all_conf_offsets) > 1),
        "offset_departures": offset_departures,
    }

    # 5. Native error evaluation with exact comment equality
    raw_native_errors = teardown_record.get("native_error_log_events", []) if teardown_record else []
    non_whitelisted_native_errors = []
    for err in raw_native_errors:
        domain = err.get("domain")
        status = err.get("status")
        comment = err.get("comment", "")
        # Whitelist ONLY exact CoreMediaErrorDomain / -15410 / "Server should support ECN for Low Latency"
        if (
            domain == "CoreMediaErrorDomain"
            and status == -15410
            and comment == "Server should support ECN for Low Latency"
        ):
            continue
        non_whitelisted_native_errors.append(err)

    # 6. Playback outcome determination (negative outcomes retained regardless of measurement integrity)
    negative_playback_reasons = []

    if non_whitelisted_native_errors:
        negative_playback_reasons.append(f"native_errors: {non_whitelisted_native_errors}")

    if offset_departures and intended_offset_s is not None:
        negative_playback_reasons.append(
            f"runtime_offset_departure_{offset_departures}_from_intended_{intended_offset_s}"
        )

    exit_code = meta.get("exit_code")
    if exit_code not in (0, None):
        negative_playback_reasons.append(f"nonzero_exit_code_{exit_code}")

    if meta.get("timed_out") is True:
        negative_playback_reasons.append("trial_timed_out")

    item_failed = any(
        (ev.get("player_status") == "failed") for ev in state_list
    ) or any(
        (s.get("player_status") == "failed") for s in sample_list
    )
    if item_failed:
        negative_playback_reasons.append("player_or_item_failed")

    if startup_time_ms is None:
        negative_playback_reasons.append(f"startup_time_unavailable: {startup_time_unavailable_reason}")

    if post_first_playing_interruption_count > 0:
        negative_playback_reasons.append(f"post_first_playing_interruptions_{post_first_playing_interruption_count}")

    if len(playing_samples) == 0:
        negative_playback_reasons.append("no_playing_marker_samples")

    if median_age_after_5s is None:
        negative_playback_reasons.append("no_sustained_playing_after_5s")

    playback_success = (len(negative_playback_reasons) == 0)
    playback_outcome = "clean_playback" if playback_success else "; ".join(negative_playback_reasons)

    return {
        "meta": meta,
        "trial_id": trial_id,
        "arm": meta.get("arm"),
        "pair_index": meta.get("pair_index"),
        "waits": meta.get("waits"),
        "offset_ms": meta.get("offset_ms"),
        "measurement_integrity": measurement_integrity,
        "integrity_reasons": integrity_reasons,
        "playback_success": playback_success,
        "playback_outcome": playback_outcome,
        "negative_playback_reasons": negative_playback_reasons,
        "startup_time_ms": startup_time_ms,
        "startup_time_unavailable_reason": startup_time_unavailable_reason,
        "time_to_first_decoded_ms": time_to_first_decoded_ms,
        "startup_waiting_ms": startup_waiting_ms,
        "initial_waiting_reasons": initial_reasons,
        "post_first_playing_interruption_count": post_first_playing_interruption_count,
        "first_age_ms": first_age_ms,
        "median_age_after_5s": median_age_after_5s,
        "p95_age_after_5s": p95_age_after_5s,
        "median_native_pdt_age_ms": median_native_pdt_age_ms,
        "offset_diagnostics": offset_diagnostics,
        "total_marker_samples": len(marker_samples),
        "playing_marker_samples": len(playing_samples),
        "invalid_marker_samples": len(invalid_marker_samples),
        "total_state_events": len(state_events),
        "raw_native_errors": raw_native_errors,
        "non_whitelisted_native_errors": non_whitelisted_native_errors,
        "frontend_access_log": access_info,
    }


def summarize_trials(trials: list[dict], results_dir: str | None = None) -> dict:
    """
    Summarizes all 20 trials, enforces strict ABBA assignment and complete-20 accounting,
    evaluates paired differences only across dual-integrity-clean trials, keeps candidate
    all-sub-2s strictly on Arm B, and propagates I/O errors.
    """
    total_trials = len(trials)
    pattern = ["A", "B", "B", "A"] * 5

    accounting_errors = []
    seen_indices = set()
    seen_ids = set()

    for t in trials:
        meta = t.get("meta", {})
        idx = meta.get("trial_index", t.get("trial_index"))
        t_id = meta.get("trial_id", t.get("trial_id"))
        arm = meta.get("arm", t.get("arm"))
        pair = meta.get("pair_index", t.get("pair_index"))
        waits = meta.get("waits", t.get("waits"))
        offset_ms = meta.get("offset_ms", t.get("offset_ms"))

        if idx is None or idx < 1 or idx > 20:
            accounting_errors.append(f"invalid_trial_index_{idx}")
            continue
        if idx in seen_indices:
            accounting_errors.append(f"duplicate_trial_index_{idx}")
        seen_indices.add(idx)

        expected_id = f"trial_{idx:02d}"
        if t_id != expected_id:
            accounting_errors.append(f"wrong_trial_id_{t_id}_expected_{expected_id}")
        if t_id in seen_ids:
            accounting_errors.append(f"duplicate_trial_id_{t_id}")
        seen_ids.add(t_id)

        expected_arm = pattern[idx - 1]
        expected_pair = (idx - 1) // 2 + 1
        expected_offset_ms = 1200 if expected_arm == "A" else 1002

        if arm != expected_arm:
            accounting_errors.append(f"wrong_arm_trial_{idx}_{arm}_expected_{expected_arm}")
        if pair != expected_pair:
            accounting_errors.append(f"wrong_pair_trial_{idx}_{pair}_expected_{expected_pair}")
        if waits is not True:
            accounting_errors.append(f"wrong_waits_trial_{idx}_{waits}_expected_True")
        if offset_ms != expected_offset_ms:
            accounting_errors.append(
                f"wrong_offset_ms_trial_{idx}_{offset_ms}_expected_{expected_offset_ms}"
            )

    if total_trials != 20:
        accounting_errors.append(f"trial_count_{total_trials}_expected_20")
    if len(seen_indices) != 20:
        accounting_errors.append(f"unique_indices_count_{len(seen_indices)}_expected_20")

    complete_20_accounting = (len(accounting_errors) == 0)

    trials_a = [t for t in trials if t.get("arm") == "A"]
    trials_b = [t for t in trials if t.get("arm") == "B"]

    arm_a_negative_count = sum(1 for t in trials_a if not t.get("playback_success", False))
    arm_b_negative_count = sum(1 for t in trials_b if not t.get("playback_success", False))

    pairs = []
    clean_pairs = []

    for pair_idx in range(1, 11):
        t_a = next((t for t in trials if t.get("pair_index") == pair_idx and t.get("arm") == "A"), None)
        t_b = next((t for t in trials if t.get("pair_index") == pair_idx and t.get("arm") == "B"), None)

        pair_rec = {
            "pair_index": pair_idx,
            "has_both_trials": (t_a is not None and t_b is not None),
            "trial_A_id": t_a.get("trial_id") if t_a else None,
            "trial_B_id": t_b.get("trial_id") if t_b else None,
            "trial_A_integrity": t_a.get("measurement_integrity", False) if t_a else False,
            "trial_B_integrity": t_b.get("measurement_integrity", False) if t_b else False,
            "trial_A_success": t_a.get("playback_success", False) if t_a else False,
            "trial_B_success": t_b.get("playback_success", False) if t_b else False,
            "is_clean_pair": False,
            "added_failure_in_B": False,
            "b_failed_with_invalid_a": False,
            "delta_median_age_ms": None,
            "delta_startup_ms": None,
            "improved": False,
        }

        # Check negative outcomes regardless of integrity
        b_neg = (t_b is not None and not t_b.get("playback_success", False))
        a_neg = (t_a is not None and not t_a.get("playback_success", False))
        a_valid = (t_a is not None and t_a.get("measurement_integrity", False))

        if b_neg and not a_neg and a_valid:
            pair_rec["added_failure_in_B"] = True
        if b_neg and not a_valid:
            pair_rec["b_failed_with_invalid_a"] = True

        # Pair B-A only across two integrity-valid clean-playback trials
        if (
            t_a and t_b
            and t_a.get("measurement_integrity") and t_b.get("measurement_integrity")
            and t_a.get("playback_success") and t_b.get("playback_success")
        ):
            med_a = t_a.get("median_age_after_5s")
            med_b = t_b.get("median_age_after_5s")
            if med_a is not None and med_b is not None:
                delta_age = med_b - med_a
                pair_rec["delta_median_age_ms"] = delta_age
                pair_rec["is_clean_pair"] = True
                pair_rec["improved"] = (delta_age < 0.0)
                clean_pairs.append(pair_rec)

            st_a = t_a.get("startup_time_ms")
            st_b = t_b.get("startup_time_ms")
            if st_a is not None and st_b is not None:
                pair_rec["delta_startup_ms"] = st_b - st_a

        pairs.append(pair_rec)

    clean_pairs_count = len(clean_pairs)
    total_added_failures_in_b = sum(1 for p in pairs if p["added_failure_in_B"])
    b_fails_with_invalid_a_count = sum(1 for p in pairs if p["b_failed_with_invalid_a"])

    deltas = [p["delta_median_age_ms"] for p in clean_pairs if p["delta_median_age_ms"] is not None]
    median_paired_delta = calc_median(deltas)
    p95_paired_delta = calc_p95(deltas)
    improving_pairs_count = sum(1 for p in clean_pairs if p["improved"])

    # candidate_all_sub_2s: strictly requires all 10 B trials to be integrity-valid,
    # clean playback, and median < 2000. Never includes A. Never true with missing/invalid B.
    candidate_all_sub_2s = (
        complete_20_accounting
        and len(trials_b) == 10
        and all(
            t.get("measurement_integrity") is True
            and t.get("playback_success") is True
            and t.get("median_age_after_5s") is not None
            and t.get("median_age_after_5s") < 2000.0
            for t in trials_b
        )
    )

    # Directional acceptance gate:
    # 1. Complete 20 accounting (no missing/duplicate/misassigned trials)
    # 2. >= 8 clean pairs
    # 3. Paired median <= -100ms
    # 4. >= 8/10 improving pairs (delta < 0)
    # 5. Zero additional B failures/interruptions (confounded B quality blocks claims)
    any_b_integrity_invalid = any(t.get("measurement_integrity") is not True for t in trials_b)
    has_additional_b_failures = (
        total_added_failures_in_b > 0
        or b_fails_with_invalid_a_count > 0
        or arm_b_negative_count > arm_a_negative_count
    )

    directional_criteria_met = False
    if not complete_20_accounting:
        verdict = "incomplete_or_invalid_20_trial_accounting"
        message = f"Accounting failure blocks claims: {accounting_errors}"
    elif clean_pairs_count < 8:
        verdict = "inconclusive_insufficient_clean_pairs"
        message = (
            f"Inconclusive: {clean_pairs_count}/10 clean valid pairs available "
            "(minimum 8 clean pairs required for effect claim)."
        )
    elif any_b_integrity_invalid:
        verdict = "directional_improvement_blocked_invalid_b_quality"
        message = (
            "Arm B contains invalid/unverified measurement integrity; "
            "unknown or invalid Arm B quality blocks positive directional improvement claim."
        )
    elif has_additional_b_failures:
        verdict = "directional_improvement_rejected_additional_b_failures"
        message = (
            f"Arm B introduced added failures/interruptions (added={total_added_failures_in_b}, "
            f"with_invalid_a={b_fails_with_invalid_a_count}, B_neg={arm_b_negative_count} vs A_neg={arm_a_negative_count}); "
            "hypothesis that lower offset improves latency without quality regression rejected."
        )
    else:
        paired_meets_target = (median_paired_delta is not None and median_paired_delta <= -100.0)
        ratio_meets_target = (improving_pairs_count >= 8)
        if paired_meets_target and ratio_meets_target:
            directional_criteria_met = True
            verdict = "directional_improvement_criteria_met"
            message = (
                f"Directional improvement confirmed: paired median delta {median_paired_delta:.1f}ms (target <=-100ms), "
                f"{improving_pairs_count}/{clean_pairs_count} pairs improving with 0 added failures."
            )
        else:
            verdict = "directional_improvement_criteria_not_met"
            message = (
                f"Criteria not met: paired median delta={median_paired_delta}ms (target <=-100ms), "
                f"{improving_pairs_count}/{clean_pairs_count} improving pairs (target >=8)."
            )

    summary = {
        "analysis_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
        "total_trials": total_trials,
        "complete_20_accounting": complete_20_accounting,
        "accounting_errors": accounting_errors,
        "arm_A_summary": {
            "total": len(trials_a),
            "integrity_valid": sum(1 for t in trials_a if t.get("measurement_integrity")),
            "clean_playback": sum(1 for t in trials_a if t.get("playback_success")),
            "negative_outcomes": arm_a_negative_count,
        },
        "arm_B_summary": {
            "total": len(trials_b),
            "integrity_valid": sum(1 for t in trials_b if t.get("measurement_integrity")),
            "clean_playback": sum(1 for t in trials_b if t.get("playback_success")),
            "negative_outcomes": arm_b_negative_count,
        },
        "clean_pairs_count": clean_pairs_count,
        "any_b_integrity_invalid": any_b_integrity_invalid,
        "total_added_failures_in_B": total_added_failures_in_b,
        "b_fails_with_invalid_a_count": b_fails_with_invalid_a_count,
        "median_paired_delta_ms": median_paired_delta,
        "p95_paired_delta_ms": p95_paired_delta,
        "improving_pairs_count": improving_pairs_count,
        "candidate_all_sub_2s": candidate_all_sub_2s,
        "verdict": verdict,
        "directional_criteria_met": directional_criteria_met,
        "message": message,
        "disclaimer": "Same-host source-to-decoded-frame measurement; not glass proof; no playlist causality claims.",
        "pairs": pairs,
        "trials": trials,
    }

    # Propagate I/O errors directly without swallowing
    if results_dir:
        summary_path = os.path.join(results_dir, "summary.json")
        with open(summary_path, "w", encoding="utf-8") as f:
            json.dump(summary, f, indent=2)

    return summary


def run_analysis(
    results_dir: str,
    room_id: str,
    trials_meta: list[dict],
    run_id: str,
) -> dict:
    """
    Processes all trials and outputs a full summary.
    """
    summarized_trials = []
    for meta in trials_meta:
        t_summary = validate_and_summarize_trial(
            meta=meta,
            results_dir=results_dir,
            room_id=room_id,
            run_id=run_id,
        )
        summarized_trials.append(t_summary)

    return summarize_trials(summarized_trials, results_dir=results_dir)
