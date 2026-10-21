#!/usr/bin/env python3
"""
RecoveryAnalysis.py - Pure cohesive quality evaluator for AVPlayer native recovery trials.
Evaluates recovery and observe controls under real delivery pause fault injection.
Public pure seam: evaluate_recovery_trial(probe_records: list[dict], fault_records: list[dict], trial_meta: dict) -> dict
"""

import math
from typing import Any, Dict, List, Optional, Tuple


def _validate_config_record(rec: dict, gen_id: int, expected_startup: str, expected_recovery: str) -> Tuple[bool, Optional[str]]:
    if rec.get("event") != "config":
        return False, f"gen{gen_id}_first_event_not_config"
    if rec.get("generation") != gen_id:
        return False, f"gen{gen_id}_config_generation_mismatch: got {rec.get('generation')}"
    if rec.get("startup_mode") != expected_startup:
        return False, f"gen{gen_id}_config_startup_mode_mismatch: got {rec.get('startup_mode')}"
    if rec.get("recovery_mode") != expected_recovery:
        return False, f"gen{gen_id}_config_recovery_mode_mismatch: got {rec.get('recovery_mode')}"
    if rec.get("waits") is not True:
        return False, f"gen{gen_id}_config_waits_not_true"
    if rec.get("can_use_network_resources_for_live_streaming_while_paused") is not True:
        return False, f"gen{gen_id}_config_network_resources_not_true"

    pfb = rec.get("preferred_forward_buffer_duration")
    if pfb is None or not math.isfinite(pfb) or float(pfb) <= 0.0:
        return False, f"gen{gen_id}_config_invalid_preferred_forward_buffer: {pfb}"

    cto = rec.get("configured_time_offset_seconds")
    if cto is None or not math.isfinite(cto) or float(cto) < 0.0:
        return False, f"gen{gen_id}_config_invalid_configured_time_offset: {cto}"

    ro = rec.get("requested_offset_ms")
    if ro is None or not math.isfinite(ro) or float(ro) <= 0.0:
        return False, f"gen{gen_id}_config_invalid_requested_offset_ms: {ro}"

    if expected_startup == "precision":
        if rec.get("startup_protocol") != "warm_play_pause_preroll_align":
            return False, f"gen{gen_id}_config_startup_protocol_mismatch: got {rec.get('startup_protocol')}"

    return True, None


def _validate_warmup_paused(rec: dict) -> Tuple[bool, Optional[str]]:
    req_ahead = rec.get("warm_required_ahead_ms")
    if req_ahead is None or not math.isfinite(req_ahead) or int(req_ahead) != 500:
        return False, f"warmup_paused_required_ahead_ms_invalid: {req_ahead}"
    if rec.get("warm_coverage_verified") is not True:
        return False, "warmup_paused_coverage_not_verified"
    target_sec = rec.get("warm_target_seconds")
    if target_sec is None or not math.isfinite(target_sec) or float(target_sec) < 0.0:
        return False, f"warmup_paused_invalid_target_seconds: {target_sec}"
    loaded_ranges = rec.get("warm_loaded_ranges")
    if not isinstance(loaded_ranges, list) or not loaded_ranges:
        return False, "warmup_paused_missing_or_empty_loaded_ranges"

    target_sec = float(target_sec)
    req_end = target_sec + 0.500
    for rng in loaded_ranges:
        if not isinstance(rng, dict):
            continue
        s, dur, e = rng.get("start"), rng.get("duration"), rng.get("end")
        if s is None or not math.isfinite(s) or float(s) < 0.0:
            continue
        end_val = float(e) if (e is not None and math.isfinite(e)) else (
            float(s) + float(dur) if (dur is not None and math.isfinite(dur) and float(dur) > 0.0) else None
        )
        if end_val is not None and float(s) <= target_sec and req_end <= end_val:
            return True, None
    return False, "warmup_paused_coverage_range_not_satisfied"


def _validate_generation_startup(
    records: List[dict],
    gen_id: int,
    expected_startup: str,
    expected_recovery: str,
) -> Tuple[bool, Optional[str], dict]:
    gen_records = [r for r in records if r.get("generation", 1) == gen_id]
    evts: dict = {}
    expected_names = [
        "config", "warmup_paused", "preroll_requested",
        "preroll_completed", "alignment_issued", "alignment_completed"
    ]
    for name in expected_names:
        matching = [r for r in gen_records if r.get("event") == name]
        if len(matching) != 1:
            return False, f"gen{gen_id}_expected_exactly_1_{name}_got_{len(matching)}", {}
        evts[name] = matching[0]

    ok_cfg, reason_cfg = _validate_config_record(evts["config"], gen_id, expected_startup, expected_recovery)
    if not ok_cfg:
        return False, reason_cfg, {}

    valid_wp, wp_reason = _validate_warmup_paused(evts["warmup_paused"])
    if not valid_wp:
        return False, f"gen{gen_id}_{wp_reason}", {}

    if evts["preroll_completed"].get("finished") is not True:
        return False, f"gen{gen_id}_preroll_completed_finished_not_true", {}

    indices = [records.index(evts[name]) for name in expected_names]
    for i in range(1, len(indices)):
        if indices[i] <= indices[i - 1]:
            return False, f"gen{gen_id}_startup_events_out_of_file_order_{expected_names[i]}_before_{expected_names[i - 1]}", {}

    times = [evts[name].get("observation_mono_ms") for name in expected_names]
    if any(t is None or not math.isfinite(t) for t in times):
        return False, f"gen{gen_id}_invalid_mono_ms_in_startup_events", {}
    if not (times[0] <= times[1] <= times[2] <= times[3] <= times[4] <= times[5]):
        return False, f"gen{gen_id}_startup_events_out_of_monotonic_time_order", {}

    return True, None, evts


def _validate_safety_stream(
    records_slice: List[dict],
    start_mono_ms: int,
    end_mono_ms: int,
    align_issued_rec: Optional[dict] = None,
) -> Tuple[bool, Optional[str], dict]:
    """
    Shared safety validator for pre-fault and both postrestore branches.
    Enforces rates 1.0±0.005, playing, no backsteps, no 6s fallback,
    exact clock age >= 0, and progress gaps <= 500ms.
    """
    align_issued_idx = records_slice.index(align_issued_rec) if align_issued_rec in records_slice else -1
    align_issued_mono = align_issued_rec.get("observation_mono_ms") if align_issued_rec else None

    max_p_gap = 0
    first_obs: Optional[int] = None
    last_obs: Optional[int] = None
    prev_fid: Optional[int] = None
    prev_src: Optional[float] = None
    prev_disp: Optional[float] = None
    markers_count = 0

    for idx, rec in enumerate(records_slice):
        if rec.get("teardown") is True:
            break

        # Skip pure lifecycle events that are not marker or state records
        evt = rec.get("event")
        if evt in (
            "config", "warmup_paused", "preroll_requested", "preroll_completed",
            "alignment_issued", "alignment_completed", "recovery_requested",
            "generation_ended", "recovery_completed", "monitoring_armed"
        ) and "valid" not in rec and "time_control_status" not in rec:
            continue

        obs = rec.get("observation_mono_ms")
        if obs is None or not math.isfinite(obs):
            continue
        obs_int = int(obs)

        # Time control status check
        tc = rec.get("time_control_status")
        if tc is not None:
            if align_issued_mono is not None and obs_int == int(align_issued_mono) and idx > align_issued_idx and tc == "paused":
                return False, "post_call_same_ms_paused_in_safety_range", {}
            if align_issued_mono is not None and obs_int > int(align_issued_mono) and tc != "playing":
                return False, f"nonplaying_in_safety_range_{tc}_at_mono_{obs_int}", {}
            if align_issued_mono is None and tc != "playing":
                return False, f"nonplaying_in_safety_range_{tc}_at_mono_{obs_int}", {}

        # Marker records (identified strictly by 'valid' key)
        if "valid" in rec:
            req_r = rec.get("requested_rate")
            if req_r is None or not math.isfinite(float(req_r)):
                return False, f"requested_rate_null_or_nonfinite_at_mono_{obs_int}", {}
            if abs(float(req_r) - 1.0) > 0.005:
                return False, f"requested_rate_deviation_{req_r}_at_mono_{obs_int}", {}

            eff_r = rec.get("effective_rate")
            if eff_r is None or not math.isfinite(float(eff_r)):
                return False, f"effective_rate_null_or_nonfinite_at_mono_{obs_int}", {}
            if abs(float(eff_r) - 1.0) > 0.005:
                return False, f"effective_rate_deviation_{eff_r}_at_mono_{obs_int}", {}

            tb_r = rec.get("effective_timebase_rate")
            if tb_r is not None:
                if not math.isfinite(float(tb_r)) or abs(float(tb_r) - 1.0) > 0.005:
                    return False, f"effective_timebase_rate_deviation_{tb_r}_at_mono_{obs_int}", {}

            for k in ("configured_offset_seconds", "recommended_offset_seconds"):
                ov = rec.get(k)
                if ov is not None and (not math.isfinite(float(ov)) or float(ov) >= 5.5):
                    return False, f"offset_6s_fallback_{k}_{ov}_at_mono_{obs_int}", {}

            if rec.get("valid") is not True:
                return False, f"invalid_marker_at_mono_{obs_int}", {}
            if rec.get("presentation_eligible") is not True:
                return False, f"ineligible_presentation_at_mono_{obs_int}", {}
            if rec.get("is_future_sample") is True:
                return False, f"future_marker_at_mono_{obs_int}", {}

            fid = rec.get("frame_id")
            src_m = rec.get("source_mono_ms")
            disp = rec.get("display_item_time_seconds")
            age = rec.get("age_ms")

            if fid is None or not isinstance(fid, int):
                return False, f"missing_or_invalid_frame_id_at_mono_{obs_int}", {}
            if src_m is None or not math.isfinite(float(src_m)):
                return False, f"missing_or_nonfinite_source_mono_ms_at_mono_{obs_int}", {}
            if disp is None or not math.isfinite(float(disp)):
                return False, f"missing_or_nonfinite_display_item_time_at_mono_{obs_int}", {}
            if age is None or not math.isfinite(float(age)) or float(age) < 0.0:
                return False, f"missing_or_invalid_age_ms_at_mono_{obs_int}", {}

            expected_age = float(obs_int) - float(src_m)
            if abs(float(age) - expected_age) > 1.0:
                return False, f"source_clock_inconsistent_at_mono_{obs_int}", {}

            markers_count += 1
            if first_obs is None:
                first_obs = obs_int
                init_gap = first_obs - start_mono_ms
                max_p_gap = max(max_p_gap, init_gap)
                if init_gap > 500:
                    return False, f"start_to_first_marker_gap_exceeded_{init_gap}ms", {}

            if prev_fid is not None:
                if fid <= prev_fid:
                    return False, f"frame_backstep_{fid}<=_{prev_fid}_at_mono_{obs_int}", {}
                if float(src_m) <= prev_src:
                    return False, f"source_backstep_{src_m}<=_{prev_src}_at_mono_{obs_int}", {}
                if float(disp) <= prev_disp:
                    return False, f"display_backstep_{disp}<=_{prev_disp}_at_mono_{obs_int}", {}
                gap = obs_int - last_obs
                max_p_gap = max(max_p_gap, gap)
                if gap > 500:
                    return False, f"progress_gap_exceeded_{gap}ms_at_mono_{obs_int}", {}

            prev_fid, prev_src, prev_disp, last_obs = fid, float(src_m), float(disp), obs_int

        elif "time_control_status" in rec:
            req_r = rec.get("requested_rate")
            if req_r is not None and (not math.isfinite(float(req_r)) or abs(float(req_r) - 1.0) > 0.005):
                return False, f"state_requested_rate_deviation_{req_r}_at_mono_{obs_int}", {}
            eff_r = rec.get("effective_rate")
            if eff_r is not None and (not math.isfinite(float(eff_r)) or abs(float(eff_r) - 1.0) > 0.005):
                return False, f"state_effective_rate_deviation_{eff_r}_at_mono_{obs_int}", {}
            tb_r = rec.get("effective_timebase_rate")
            if tb_r is not None and (not math.isfinite(float(tb_r)) or abs(float(tb_r) - 1.0) > 0.005):
                return False, f"state_effective_timebase_rate_deviation_{tb_r}_at_mono_{obs_int}", {}
            for k in ("configured_offset_seconds", "recommended_offset_seconds"):
                ov = rec.get(k)
                if ov is not None and (not math.isfinite(float(ov)) or float(ov) >= 5.5):
                    return False, f"state_offset_6s_fallback_{k}_{ov}_at_mono_{obs_int}", {}

    if last_obs is None:
        return False, "no_eligible_markers_found_in_safety_range", {}

    tail_gap = end_mono_ms - last_obs
    max_p_gap = max(max_p_gap, tail_gap)
    if tail_gap > 500:
        return False, f"tail_to_end_gap_exceeded_{tail_gap}ms", {}

    return True, None, {
        "markers_count": markers_count,
        "first_obs_mono_ms": first_obs,
        "last_obs_mono_ms": last_obs,
        "max_progress_gap_ms": max_p_gap,
    }


def _compute_window_stats(window_records: List[dict], w_start: int, w_end: int) -> Tuple[bool, Optional[str], dict]:
    if len(window_records) < 110:
        return False, f"settled_window_insufficient_samples: {len(window_records)} < 110", {}
    w_obs = [int(r["observation_mono_ms"]) for r in window_records]
    t_first_w, t_last_w = min(w_obs), max(w_obs)
    w_span = float(t_last_w - t_first_w)
    if w_span < 29000.0:
        return False, f"settled_window_insufficient_span: {w_span}ms < 29000ms", {}
    first_off = t_first_w - w_start
    last_off = w_end - t_last_w
    if first_off > 500:
        return False, f"settled_window_first_sample_late: {first_off}ms > 500ms", {}
    if last_off > 500:
        return False, f"settled_window_last_sample_early: {last_off}ms > 500ms", {}

    ages = sorted(float(r["age_ms"]) for r in window_records)
    mid = len(ages) // 2
    median = ages[mid] if len(ages) % 2 != 0 else (ages[mid - 1] + ages[mid]) / 2.0
    p95_idx = int(math.ceil(0.95 * len(ages))) - 1
    p95 = ages[min(max(p95_idx, 0), len(ages) - 1)]
    if median > 1500.0:
        return False, f"settled_median_age_exceeded: {median:.1f}ms > 1500ms", {}
    if p95 >= 2000.0:
        return False, f"settled_p95_age_exceeded: {p95:.1f}ms >= 2000ms", {}

    return True, None, {
        "samples_count": len(window_records),
        "span_ms": w_span,
        "first_offset_ms": first_off,
        "last_offset_ms": last_off,
        "median_age_ms": round(median, 1),
        "p95_age_ms": round(p95, 1),
    }


def evaluate_recovery_trial(
    probe_records: List[dict],
    fault_records: List[dict],
    trial_meta: dict,
) -> dict:
    trial_id = trial_meta.get("trial_id", "unknown_trial")
    rec_mode = trial_meta.get("recovery_mode", "observe")
    outage_dur_s = float(trial_meta.get("outage_duration_s", 0.0))
    startup_mode = trial_meta.get("startup_mode", "precision")
    is_observe = (rec_mode == "observe")

    res: Dict[str, Any] = {
        "trial_id": trial_id,
        "recovery_mode": rec_mode,
        "outage_duration_s": outage_dur_s,
        "quality_failure": False,
        "quality_failure_reason": None,
        "comparator_invalidated": False,
        "rebuild_exercised": False,
        "native_recovery_sufficient": False,
        "rebuild_latency_met": False,
        "outage_started_seen": False,
        "outage_restored_seen": False,
        "outage_target_duration_s": None,
        "outage_actual_duration_s": None,
        "outage_ack_latency_ms": None,
        "outage_pid_verified": False,
        "gen1_warmup_paused": False,
        "gen1_preroll_completed": False,
        "gen1_alignment_issued_mono_ms": None,
        "gen1_alignment_completed_mono_ms": None,
        "prefault_eligible_samples": 0,
        "prefault_span_ms": 0.0,
        "prefault_passed": False,
        "recovery_requested_seen": False,
        "recovery_requested_gap_ms": None,
        "recovery_completed_seen": False,
        "restore_to_recovery_completed_ms": None,
        "recovery_source_age_ms": None,
        "gen2_warmup_paused": False,
        "gen2_preroll_completed": False,
        "gen2_alignment_issued_mono_ms": None,
        "gen2_alignment_completed_mono_ms": None,
        "settled_window_start_ms": None,
        "settled_window_end_ms": None,
        "settled_samples_count": 0,
        "settled_span_ms": 0.0,
        "settled_first_offset_ms": None,
        "settled_last_offset_ms": None,
        "settled_median_age_ms": None,
        "settled_p95_age_ms": None,
        "max_progress_gap_ms": 0,
        "resumed_postrestore": False,
        "postrestore_first_frame_id": None,
        "postrestore_first_mono_ms": None,
        "postrestore_first_age_ms": None,
        "teardown_seen": False,
        "teardown_mono_ms": None,
        "native_error_log_count": 0,
        "native_terminal_error": None,
    }

    def fail(reason: str, is_infra: bool = False):
        res["quality_failure"] = True
        res["quality_failure_reason"] = reason
        if is_observe and is_infra:
            res["comparator_invalidated"] = True
        return res

    # 1. Exit code and PID validation
    if trial_meta.get("timed_out") is True:
        return fail("probe_process_timed_out", is_infra=True)
    if trial_meta.get("exit_code") is None or trial_meta.get("exit_code") != 0:
        return fail(f"exit_code_must_be_0_got_{trial_meta.get('exit_code')}", is_infra=True)

    expected_pid = trial_meta.get("gateway_pid")
    if expected_pid is None or not isinstance(expected_pid, int) or expected_pid <= 0:
        return fail("absent_or_invalid_gateway_pid", is_infra=True)

    if not probe_records:
        return fail("empty_probe_evidence", is_infra=True)

    # 2. Teardown record check at EOF
    if probe_records[-1].get("teardown") is not True:
        return fail("teardown_record_not_at_eof", is_infra=is_observe)

    td_recs = [r for r in probe_records if r.get("teardown") is True]
    if len(td_recs) != 1:
        return fail(f"expected_exactly_1_teardown_got_{len(td_recs)}", is_infra=is_observe)

    td = td_recs[0]
    res["teardown_seen"] = True
    t_td = td.get("teardown_mono_ms")
    if t_td is None or not math.isfinite(float(t_td)):
        return fail("invalid_teardown_mono_ms", is_infra=is_observe)
    t_td_ms = int(t_td)
    res["teardown_mono_ms"] = t_td_ms

    final_ph = td.get("final_phase")
    if final_ph in ("terminal", "failed"):
        return fail(f"terminal_failure_phase_{final_ph}", is_infra=is_observe)

    native_errs = td.get("native_error_log_events", [])
    if isinstance(native_errs, list):
        res["native_error_log_count"] = len(native_errs)

    fail_evts = [r for r in probe_records if r.get("event") in ("alignment_failed", "precision_failed", "recovery_failed", "preroll_failed")]
    if fail_evts:
        res["native_terminal_error"] = f"{fail_evts[0].get('event')}: {fail_evts[0].get('reason')}"
        if not is_observe:
            return fail(f"native_terminal_failure_event: {res['native_terminal_error']}")

    # 3. Fault verification
    started_recs = [f for f in fault_records if f.get("event") == "delivery_outage_started"]
    restored_recs = [f for f in fault_records if f.get("event") == "delivery_outage_restored"]
    if len(started_recs) != 1 or len(restored_recs) != 1:
        return fail(f"fault_lifecycle_count_invalid: started={len(started_recs)}, restored={len(restored_recs)}", is_infra=True)

    started, restored = started_recs[0], restored_recs[0]
    res["outage_started_seen"] = True
    res["outage_restored_seen"] = True

    if started.get("target_pid") != expected_pid or restored.get("target_pid") != expected_pid:
        return fail(f"fault_pid_mismatch: expected {expected_pid}, got {started.get('target_pid')}/{restored.get('target_pid')}", is_infra=True)
    res["outage_pid_verified"] = True

    cmd_mono_s = started.get("cmd_mono_s")
    ack_mono_s = started.get("ack_mono_s")
    restore_mono_s = restored.get("restore_mono_s")
    tgt_dur = started.get("target_duration_s")
    act_dur = restored.get("actual_outage_duration_s")

    for val, name in [
        (cmd_mono_s, "cmd_mono_s"), (ack_mono_s, "ack_mono_s"),
        (restore_mono_s, "restore_mono_s"), (tgt_dur, "target_duration_s"),
        (act_dur, "actual_outage_duration_s"),
    ]:
        if val is None or not math.isfinite(float(val)):
            return fail(f"fault_nonfinite_{name}", is_infra=True)

    cmd_mono_s = float(cmd_mono_s)
    ack_mono_s = float(ack_mono_s)
    restore_mono_s = float(restore_mono_s)
    tgt_dur = float(tgt_dur)
    act_dur = float(act_dur)

    if abs(tgt_dur - outage_dur_s) > 0.001:
        return fail(f"fault_target_duration_mismatch: got {tgt_dur}, expected {outage_dur_s}", is_infra=True)
    res["outage_target_duration_s"] = tgt_dur

    ack_lat_ms = started.get("ack_latency_ms")
    if ack_lat_ms is None or not math.isfinite(float(ack_lat_ms)):
        return fail("fault_nonfinite_ack_latency_ms", is_infra=True)
    ack_lat_ms = float(ack_lat_ms)
    res["outage_ack_latency_ms"] = ack_lat_ms

    if ack_lat_ms < 0.0 or ack_lat_ms > 500.0:
        return fail(f"fault_ack_latency_out_of_range: {ack_lat_ms}ms", is_infra=True)
    expected_ack_lat = (ack_mono_s - cmd_mono_s) * 1000.0
    if abs(ack_lat_ms - expected_ack_lat) > 1.0:
        return fail(f"fault_ack_latency_inconsistent: got {ack_lat_ms}ms, calculated {expected_ack_lat:.2f}ms", is_infra=True)

    if restore_mono_s < ack_mono_s:
        return fail("fault_timing_inversion_between_ack_and_restore", is_infra=True)

    expected_act_dur = restore_mono_s - ack_mono_s
    if abs(act_dur - expected_act_dur) > 0.010:
        return fail(f"fault_actual_duration_inconsistent: got {act_dur}s, calculated {expected_act_dur:.3f}s", is_infra=True)

    res["outage_actual_duration_s"] = act_dur
    if abs(act_dur - outage_dur_s) > 0.300:
        return fail(f"fault_actual_duration_deviation_exceeded_300ms: got {act_dur}s, target {outage_dur_s}s", is_infra=True)

    t_fault_cmd_ms = int(cmd_mono_s * 1000)
    t_fault_ack_ms = int(ack_mono_s * 1000)
    t_fault_restore_ms = int(restore_mono_s * 1000)

    # 4. Generation 1 verification
    ok_g1, reason_g1, evts_g1 = _validate_generation_startup(probe_records, gen_id=1, expected_startup=startup_mode, expected_recovery=rec_mode)
    if not ok_g1:
        return fail(reason_g1 or "gen1_startup_validation_failed", is_infra=True)

    res["gen1_warmup_paused"] = True
    res["gen1_preroll_completed"] = True
    g1_align_iss_ms = int(evts_g1["alignment_issued"]["observation_mono_ms"])
    g1_align_comp_ms = int(evts_g1["alignment_completed"]["observation_mono_ms"])
    res["gen1_alignment_issued_mono_ms"] = g1_align_iss_ms
    res["gen1_alignment_completed_mono_ms"] = g1_align_comp_ms

    expected_fault_start = g1_align_comp_ms + 10_000
    if t_fault_cmd_ms < expected_fault_start or t_fault_cmd_ms > (expected_fault_start + 300):
        return fail(f"fault_start_timing_out_of_window: cmd_mono={t_fault_cmd_ms}ms, expected [{expected_fault_start}..{expected_fault_start+300}]ms", is_infra=True)

    # 5. Pre-fault window in aligned + 3..8s
    pf_start, pf_end = g1_align_comp_ms + 3000, g1_align_comp_ms + 8000
    pf_slice = [
        r for r in probe_records
        if r.get("generation", 1) == 1
        and r.get("observation_mono_ms") is not None
        and pf_start <= int(r["observation_mono_ms"]) <= pf_end
    ]

    ok_pf, reason_pf, stats_pf = _validate_safety_stream(pf_slice, pf_start, pf_end)
    if not ok_pf:
        return fail(f"prefault_safety_failed_{reason_pf}", is_infra=True)

    res["prefault_eligible_samples"] = stats_pf["markers_count"]
    if stats_pf["markers_count"] < 16:
        return fail(f"prefault_insufficient_samples: {stats_pf['markers_count']} < 16", is_infra=True)

    pf_span = float(stats_pf["last_obs_mono_ms"] - stats_pf["first_obs_mono_ms"])
    res["prefault_span_ms"] = pf_span
    if pf_span < 4500.0:
        return fail(f"prefault_insufficient_span: {pf_span}ms < 4500ms", is_infra=True)

    res["prefault_passed"] = True

    # 6. Observe Mode Evaluation
    if is_observe:
        if td.get("final_generation") != 1 or td.get("final_phase") not in ("monitoring", "initial"):
            return fail(f"observe_teardown_final_mismatch: gen={td.get('final_generation')}, phase={td.get('final_phase')}", is_infra=False)

        if any(r.get("event") in ("recovery_requested", "recovery_completed", "generation_ended") for r in probe_records):
            return fail("observe_control_unexpected_recovery_event", is_infra=False)
        if any(r.get("generation", 1) > 1 for r in probe_records):
            return fail("observe_control_unexpected_generation_gt_1", is_infra=False)
        extra_aligns = [
            r for r in probe_records
            if r.get("event") in ("alignment_issued", "alignment_completed")
            and r is not evts_g1["alignment_issued"] and r is not evts_g1["alignment_completed"]
        ]
        if extra_aligns:
            return fail("observe_control_unexpected_extra_alignment", is_infra=False)

        post_restore_markers = [
            r for r in probe_records
            if "valid" in r and r.get("valid") is True and r.get("presentation_eligible") is True
            and r.get("observation_mono_ms") is not None and int(r["observation_mono_ms"]) >= t_fault_restore_ms
        ]
        if post_restore_markers:
            res["resumed_postrestore"] = True
            first_post = post_restore_markers[0]
            res["postrestore_first_frame_id"] = first_post.get("frame_id")
            res["postrestore_first_mono_ms"] = first_post.get("observation_mono_ms")
            res["postrestore_first_age_ms"] = first_post.get("age_ms")
        else:
            res["resumed_postrestore"] = False

        res["quality_failure"] = False
        res["comparator_invalidated"] = False
        return res

    # 7. Rebuild Mode Evaluation
    rec_reqs = [r for r in probe_records if r.get("event") == "recovery_requested"]
    if len(rec_reqs) > 1:
        return fail(f"multiple_recovery_requested_events_got_{len(rec_reqs)}")
    if any(r.get("generation", 1) > 2 for r in probe_records):
        return fail("forbidden_generation_3_present")

    # Case A: Actual rebuild exercised
    if len(rec_reqs) == 1:
        if td.get("final_generation") != 2 or td.get("final_phase") != "recovered":
            return fail(f"rebuild_teardown_final_mismatch: gen={td.get('final_generation')}, phase={td.get('final_phase')}")

        res["recovery_requested_seen"] = True
        rec_req = rec_reqs[0]
        gap_ms = rec_req.get("progress_gap_ms")
        if gap_ms is None or not math.isfinite(float(gap_ms)) or float(gap_ms) < 750.0:
            return fail(f"recovery_requested_progress_gap_below_750ms: {gap_ms}")
        res["recovery_requested_gap_ms"] = int(gap_ms)

        last_fid, last_src = rec_req.get("last_advancing_frame_id"), rec_req.get("last_advancing_source_mono_ms")
        if last_fid is None or last_src is None or not math.isfinite(float(last_src)):
            return fail("recovery_requested_missing_last_advancing_tracking_fields")

        req_mono = rec_req.get("observation_mono_ms")
        if req_mono is None or int(req_mono) < t_fault_ack_ms or int(req_mono) < g1_align_comp_ms:
            return fail("recovery_requested_before_fault_ack_or_gen1_startup")

        # Check generation_ended: RecoverySession.swift emits ended_generation: 1
        gen_ends = [r for r in probe_records if r.get("event") == "generation_ended"]
        if len(gen_ends) != 1 or gen_ends[0].get("ended_generation") != 1:
            return fail(f"expected_exactly_1_generation_ended_with_ended_generation_1_got_{len(gen_ends)}")

        ok_g2, reason_g2, evts_g2 = _validate_generation_startup(probe_records, gen_id=2, expected_startup=startup_mode, expected_recovery=rec_mode)
        if not ok_g2:
            return fail(reason_g2 or "gen2_startup_validation_failed")

        res["gen2_warmup_paused"] = True
        res["gen2_preroll_completed"] = True
        g2_align_iss_ms = int(evts_g2["alignment_issued"]["observation_mono_ms"])
        g2_align_comp_ms = int(evts_g2["alignment_completed"]["observation_mono_ms"])
        res["gen2_alignment_issued_mono_ms"] = g2_align_iss_ms
        res["gen2_alignment_completed_mono_ms"] = g2_align_comp_ms

        rec_comps = [r for r in probe_records if r.get("event") == "recovery_completed"]
        if len(rec_comps) != 1:
            return fail(f"expected_exactly_1_recovery_completed_got_{len(rec_comps)}")
        rec_comp = rec_comps[0]
        res["recovery_completed_seen"] = True
        if rec_comp.get("generation") != 2:
            return fail(f"recovery_completed_generation_mismatch: got {rec_comp.get('generation')}, expected 2")

        new_fid, new_src, new_obs = rec_comp.get("frame_id"), rec_comp.get("source_mono_ms"), rec_comp.get("observation_mono_ms")
        if new_fid is None or new_src is None or new_obs is None:
            return fail("recovery_completed_missing_required_fields")
        if int(new_fid) <= int(last_fid) or float(new_src) <= float(last_src):
            return fail("recovery_completed_not_newer_than_prefault")

        # Enforce FILE ORDER: recovery_requested < generation_ended < gen2 config < warmup < preroll < align < recovery_completed
        idx_req = probe_records.index(rec_req)
        idx_ended = probe_records.index(gen_ends[0])
        idx_g2_cfg = probe_records.index(evts_g2["config"])
        idx_align_comp = probe_records.index(evts_g2["alignment_completed"])
        idx_rec_comp = probe_records.index(rec_comp)

        if not (idx_req < idx_ended < idx_g2_cfg < idx_align_comp < idx_rec_comp):
            return fail("rebuild_lifecycle_events_out_of_file_order")

        # RecoverySession.swift emits recovery_completed BEFORE the matching marker record.
        # Require immediate FOLLOWING marker matching generation 2, frame, source, observation, age, valid eligible 1x.
        if (idx_rec_comp + 1) >= len(probe_records):
            return fail("recovery_completed_lacks_following_marker")
        following_marker = probe_records[idx_rec_comp + 1]

        if "valid" not in following_marker:
            return fail("recovery_completed_immediate_next_record_not_marker")
        if following_marker.get("valid") is not True or following_marker.get("presentation_eligible") is not True:
            return fail("following_marker_ineligible_or_invalid")
        if following_marker.get("generation") != 2:
            return fail(f"following_marker_generation_mismatch: {following_marker.get('generation')}")
        if following_marker.get("frame_id") != new_fid:
            return fail(f"following_marker_frame_id_mismatch: got {following_marker.get('frame_id')}, expected {new_fid}")
        if following_marker.get("source_mono_ms") != new_src:
            return fail(f"following_marker_source_mono_ms_mismatch: got {following_marker.get('source_mono_ms')}, expected {new_src}")
        if following_marker.get("observation_mono_ms") != new_obs:
            return fail(f"following_marker_observation_mono_ms_mismatch: got {following_marker.get('observation_mono_ms')}, expected {new_obs}")

        # Latency check: no negative latency, restore->completion <= 3000ms
        t_rec_comp_ms = int(new_obs)
        if t_rec_comp_ms < t_fault_restore_ms:
            return fail("early_recovery_completed_before_fault_restoration")
        restore_to_rec_ms = float(t_rec_comp_ms - t_fault_restore_ms)
        res["restore_to_recovery_completed_ms"] = restore_to_rec_ms
        res["recovery_source_age_ms"] = float(t_rec_comp_ms) - float(new_src)
        if restore_to_rec_ms > 3000.0:
            return fail(f"restore_to_recovery_completed_latency_exceeded: {restore_to_rec_ms}ms > 3000ms")

        # Postrecovery safety range: strictly AFTER gen2 alignment_issued FILE INDEX to teardown
        idx_align_iss = probe_records.index(evts_g2["alignment_issued"])
        gen2_safety_slice = probe_records[idx_align_iss + 1:]
        ok_safety, reason_safety, stats_safety = _validate_safety_stream(
            gen2_safety_slice,
            start_mono_ms=g2_align_iss_ms,
            end_mono_ms=t_td_ms,
            align_issued_rec=evts_g2["alignment_issued"],
        )
        if not ok_safety:
            return fail(f"postrecovery_safety_failed_{reason_safety}")
        res["max_progress_gap_ms"] = stats_safety["max_progress_gap_ms"]

        # Settled window recovery_completed + 5..35s
        w_start, w_end = t_rec_comp_ms + 5_000, t_rec_comp_ms + 35_000
        res["settled_window_start_ms"], res["settled_window_end_ms"] = w_start, w_end
        win_recs = [
            r for r in probe_records
            if "valid" in r and r.get("valid") is True and r.get("presentation_eligible") is True
            and r.get("observation_mono_ms") is not None and w_start <= int(r["observation_mono_ms"]) <= w_end
            and r.get("age_ms") is not None and math.isfinite(float(r["age_ms"]))
        ]
        ok_w, reason_w, stats_w = _compute_window_stats(win_recs, w_start, w_end)
        if not ok_w:
            return fail(reason_w or "settled_window_evaluation_failed")

        res["settled_samples_count"] = stats_w["samples_count"]
        res["settled_span_ms"] = stats_w["span_ms"]
        res["settled_first_offset_ms"] = stats_w["first_offset_ms"]
        res["settled_last_offset_ms"] = stats_w["last_offset_ms"]
        res["settled_median_age_ms"] = stats_w["median_age_ms"]
        res["settled_p95_age_ms"] = stats_w["p95_age_ms"]
        res["rebuild_exercised"] = True
        res["native_recovery_sufficient"] = False
        res["rebuild_latency_met"] = True
        res["quality_failure"] = False
        return res

    # Case B: No recovery_requested emitted (Check if gap >= 750 occurred or buffer absorbed)
    if td.get("final_generation") != 1 or td.get("final_phase") not in ("monitoring", "initial"):
        return fail(f"norebuild_teardown_final_mismatch: gen={td.get('final_generation')}, phase={td.get('final_phase')}")

    idx_g1_iss = probe_records.index(evts_g1["alignment_issued"])
    no_reb_slice = probe_records[idx_g1_iss + 1:]
    ok_noreb_safety, reason_noreb_safety, stats_noreb_safety = _validate_safety_stream(
        no_reb_slice,
        start_mono_ms=g1_align_iss_ms,
        end_mono_ms=t_td_ms,
        align_issued_rec=evts_g1["alignment_issued"],
    )
    if not ok_noreb_safety:
        all_markers = [
            r for r in probe_records
            if "valid" in r and r.get("valid") is True and r.get("presentation_eligible") is True and r.get("observation_mono_ms") is not None
        ]
        for i in range(1, len(all_markers)):
            if int(all_markers[i]["observation_mono_ms"]) - int(all_markers[i - 1]["observation_mono_ms"]) >= 750:
                return fail("missing_recovery_trigger_on_gap_greater_equal_750ms")
        return fail(f"no_rebuild_safety_failed_{reason_noreb_safety}")

    if any(r.get("generation", 1) > 1 for r in probe_records) or any(r.get("event") == "generation_ended" for r in probe_records):
        return fail("native_recovery_sufficient_violates_generation_invariance")

    all_markers = [
        r for r in probe_records
        if "valid" in r and r.get("valid") is True and r.get("presentation_eligible") is True and r.get("observation_mono_ms") is not None
    ]
    fresh = [
        r for r in all_markers
        if t_fault_restore_ms <= int(r["observation_mono_ms"]) <= t_fault_restore_ms + 3000
        and r.get("age_ms") is not None and float(r["age_ms"]) < 2000.0
    ]
    if not fresh:
        return fail("missing_fresh_advancing_frame_with_age_below_2000ms_within_3s_of_restore")

    w_start, w_end = t_fault_restore_ms + 5_000, t_fault_restore_ms + 35_000
    res["settled_window_start_ms"], res["settled_window_end_ms"] = w_start, w_end
    win_recs = [
        r for r in all_markers
        if w_start <= int(r["observation_mono_ms"]) <= w_end
        and r.get("age_ms") is not None and math.isfinite(float(r["age_ms"]))
    ]
    ok_w, reason_w, stats_w = _compute_window_stats(win_recs, w_start, w_end)
    if not ok_w:
        return fail(reason_w or "native_sufficient_settled_evaluation_failed")

    res["settled_samples_count"] = stats_w["samples_count"]
    res["settled_span_ms"] = stats_w["span_ms"]
    res["settled_first_offset_ms"] = stats_w["first_offset_ms"]
    res["settled_last_offset_ms"] = stats_w["last_offset_ms"]
    res["settled_median_age_ms"] = stats_w["median_age_ms"]
    res["settled_p95_age_ms"] = stats_w["p95_age_ms"]
    res["max_progress_gap_ms"] = stats_noreb_safety["max_progress_gap_ms"]
    res["rebuild_exercised"] = False
    res["native_recovery_sufficient"] = True
    res["rebuild_latency_met"] = True
    res["quality_failure"] = False
    return res
