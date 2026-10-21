#!/usr/bin/env python3
"""
run.py - Subclassed native warm-recovery verification experiment harness.
Reuses cancellation, atomic acquisition, preflight, Nginx, TLS, publisher,
single-POST worker verification, and cleanup from base.H2CaptureHarness.
Implements delivery outage fault injection via DeliveryOutage (SIGSTOP/SIGCONT on owned Nginx)
and tests 12 trials across [2, 5, 10]s outages: 1 observe (40s) + 3 rebuild (65s) per duration.
Evaluates pure recovery quality via RecoveryAnalysis.evaluate_recovery_trial.
"""

import sys
sys.dont_write_bytecode = True

import argparse
from datetime import datetime, timezone
import importlib
import importlib.util
import json
import math
import os
import signal
import subprocess
import time
import urllib.error
import urllib.request

OLD_ROOT = "/private/tmp/vg-startup-auto-20261020-1338"
BASE_ROOT = "/private/tmp/vg-startup-h2-capture-20261020"
NEW_ROOT = "/private/tmp/vg-native-warm-recovery-proof-20261021"

for r in (OLD_ROOT, BASE_ROOT, NEW_ROOT):
    if r not in sys.path:
        sys.path.insert(0, r)

import experiment
from DeliveryOutage import DeliveryOutage
from RecoveryAnalysis import evaluate_recovery_trial

# Explicitly load base analyzer from BASE_ROOT/analyze.py under distinct name "base_analyze"
base_analyze_path = os.path.join(BASE_ROOT, "analyze.py")
base_analyze_spec = importlib.util.spec_from_file_location("base_analyze", base_analyze_path)
base_analyze_module = importlib.util.module_from_spec(base_analyze_spec)
sys.modules["base_analyze"] = base_analyze_module
base_analyze_spec.loader.exec_module(base_analyze_module)
sys.modules["analyze"] = base_analyze_module

# Subclass base.H2CaptureHarness via importlib to avoid module name collision
base_run_path = os.path.join(BASE_ROOT, "run.py")
base_spec = importlib.util.spec_from_file_location("base_run", base_run_path)
base_module = importlib.util.module_from_spec(base_spec)
sys.modules["base_run"] = base_module
base_spec.loader.exec_module(base_module)

NEW_RESULTS_DIR = os.path.join(NEW_ROOT, "results")
NEW_NGINX_CONF = os.path.join(NEW_ROOT, "nginx.conf")

# Redirect base module variables before harness construction
base_module.NEW_RESULTS_DIR = NEW_RESULTS_DIR
base_module.NEW_NGINX_CONF = NEW_NGINX_CONF
base_module.PCAPNG_PATH = os.path.join(NEW_RESULTS_DIR, "unused.pcapng")
base_module.CAPTURE_STDERR_LOG = os.path.join(NEW_RESULTS_DIR, "unused_capture.log")

# Redirect experiment module variables
experiment.RESULTS_DIR = NEW_RESULTS_DIR
experiment.NGINX_CONF = NEW_NGINX_CONF
experiment.H2_PID_FILE = os.path.join(NEW_RESULTS_DIR, "nginx.pid")
experiment.H2_ACCESS_LOG = os.path.join(NEW_RESULTS_DIR, "nginx_access.log")
experiment.H2_ERROR_LOG = os.path.join(NEW_RESULTS_DIR, "nginx_error.log")


class WarmRecoveryHarness(base_module.H2CaptureHarness):
    def __init__(self, nonce: int):
        super().__init__(nonce=nonce)
        self.run_id = f"vg_warmrecoveryproof_{nonce}"
        self.room_id = f"room_warmrecoveryproof_{nonce}"
        self.host_identity = f"host_warmrecoveryproof_{nonce}"
        self.tested_probe_bin: str | None = None
        self.tested_probe_sha: str | None = None
        self.current_outage: DeliveryOutage | None = None

    def verify_prerequisites(self):
        """Verifies prerequisites, requiring precompiled Probe binary. Records source hashes."""
        probe_bin = os.path.join(NEW_ROOT, "build", "Probe")
        if not (os.path.isfile(probe_bin) and os.access(probe_bin, os.R_OK)):
            alt_bin = os.path.join(NEW_ROOT, "Probe")
            if os.path.isfile(alt_bin) and os.access(alt_bin, os.R_OK):
                probe_bin = alt_bin
            else:
                raise RuntimeError(
                    f"BLOCKED: Required Probe binary missing or unreadable at {probe_bin}; implicit compilation is forbidden"
                )

        self.tested_probe_bin = probe_bin
        self.tested_probe_sha = experiment.file_sha256(probe_bin)
        super().verify_prerequisites()

        prov_path = os.path.join(NEW_RESULTS_DIR, "provenance.json")
        if os.path.exists(prov_path):
            with open(prov_path, "r", encoding="utf-8") as f:
                prov = json.load(f)
            prov["packet_capture"] = False
            prov["tested_probe_binary"] = {"path": self.tested_probe_bin, "sha256": self.tested_probe_sha}
            prov["new_source_hashes_sha256"] = {
                f: experiment.file_sha256(os.path.join(NEW_ROOT, f))
                for f in (
                    "main.swift", "RecoverySession.swift", "PrecisionStartup.swift", "run.py",
                    "RecoveryAnalysis.py", "test_recovery_analysis.py", "DeliveryOutage.py",
                    "test_delivery_outage.py", "nginx.conf", "tests/main.swift"
                )
            }
            with open(prov_path, "w", encoding="utf-8") as f:
                json.dump(prov, f, indent=2)

    def verify_stream_parameters_and_warmup(self):
        """Polls owned /live/ROOM/{vhi.m3u8,a.m3u8} through pinned TLS context, validating warmup threshold."""
        experiment.log("Verifying stream parameters and waiting for warmup threshold (max 45s)...")
        self.check_deadline("verify_stream_parameters_and_warmup")
        ssl_ctx = base_module.create_lab_ssl_context()
        video_url = f"https://192.168.0.136:18445/live/{self.room_id}/vhi.m3u8"
        audio_url = f"https://192.168.0.136:18445/live/{self.room_id}/a.m3u8"
        ua = f"VGCanary/1.0 (stage-readiness; nonce={self.nonce})"

        def parse_server_control(body_text: str) -> dict:
            for line in body_text.splitlines():
                line = line.strip()
                if line.startswith("#EXT-X-SERVER-CONTROL:"):
                    raw = line.split(":", 1)[1]
                    return {k.strip(): v.strip() for part in raw.split(",") if "=" in part for k, v in [part.split("=", 1)]}
            return {}

        t0 = time.monotonic()
        warmup_deadline = t0 + 45.0
        warmup_ready = False
        last_video_body, last_audio_body = "", ""
        last_v_dur, last_a_dur, last_v_phb, last_a_phb = 0.0, 0.0, 0.0, 0.0

        while True:
            self.check_cancellation()
            rem = warmup_deadline - time.monotonic()
            if rem <= 0:
                break
            try:
                v_timeout = min(3.0, warmup_deadline - time.monotonic())
                v_req = urllib.request.Request(video_url, headers={"User-Agent": ua})
                with urllib.request.urlopen(v_req, timeout=v_timeout, context=ssl_ctx) as v_resp:
                    if v_resp.status != 200:
                        time.sleep(min(1.0, max(0.01, warmup_deadline - time.monotonic())))
                        continue
                    video_body = v_resp.read().decode("utf-8", errors="replace")

                self.check_cancellation()
                a_timeout = min(3.0, warmup_deadline - time.monotonic())
                a_req = urllib.request.Request(audio_url, headers={"User-Agent": ua})
                with urllib.request.urlopen(a_req, timeout=a_timeout, context=ssl_ctx) as a_resp:
                    if a_resp.status != 200:
                        time.sleep(min(1.0, max(0.01, warmup_deadline - time.monotonic())))
                        continue
                    audio_body = a_resp.read().decode("utf-8", errors="replace")

                self.check_cancellation()
                v_sc = parse_server_control(video_body)
                a_sc = parse_server_control(audio_body)

                if v_sc.get("CAN-BLOCK-RELOAD") != "YES" or a_sc.get("CAN-BLOCK-RELOAD") != "YES":
                    raise RuntimeError("ABORT: CAN-BLOCK-RELOAD is not YES")

                v_phb = float(v_sc.get("PART-HOLD-BACK", "0"))
                a_phb = float(a_sc.get("PART-HOLD-BACK", "0"))
                if abs(v_phb - 1.002) > 0.000001 or abs(a_phb - 1.002) > 0.000001:
                    raise RuntimeError(f"ABORT: PART-HOLD-BACK expected 1.002, got v={v_phb}, a={a_phb}")

                v_edge = base_module.analyze.parse_playlist_edge(video_body)
                a_edge = base_module.analyze.parse_playlist_edge(audio_body)
                v_dur = v_edge.get("completed_extinf_s") or 0.0
                a_dur = a_edge.get("completed_extinf_s") or 0.0
                last_video_body, last_audio_body = video_body, audio_body
                last_v_dur, last_a_dur, last_v_phb, last_a_phb = v_dur, a_dur, v_phb, a_phb

                if v_edge.get("valid_edge") and a_edge.get("valid_edge") and v_dur >= 24.0 and a_dur >= 23.9:
                    warmup_ready = True
                    break
            except RuntimeError:
                raise
            except Exception as e:
                experiment.log(f"Polling warmup waiting for playlist readiness: {e}")
            time.sleep(min(1.0, max(0.01, warmup_deadline - time.monotonic())))

        if not warmup_ready:
            raise RuntimeError(f"Timed out after 45s waiting for warmup threshold (v_dur={last_v_dur}/24.0, a_dur={last_a_dur}/23.9)")

        self.check_cancellation()
        with open(os.path.join(NEW_RESULTS_DIR, "pretrial_video.m3u8"), "w", encoding="utf-8") as vf:
            vf.write(last_video_body)
        with open(os.path.join(NEW_RESULTS_DIR, "pretrial_audio.m3u8"), "w", encoding="utf-8") as af:
            af.write(last_audio_body)

        now_utc = base_module.utc_now_iso()
        now_mono = int(time.clock_gettime(time.CLOCK_MONOTONIC) * 1000)
        self.record_event(
            "warmup_verified", utc=now_utc, observation_mono_ms=now_mono,
            video_completed_extinf_s=round(last_v_dur, 3), audio_completed_extinf_s=round(last_a_dur, 3),
            video_part_hold_back=last_v_phb, audio_part_hold_back=last_a_phb, can_block_reload="YES",
        )
        experiment.log(f"Warmup verified: video_dur={last_v_dur:.3f}s (>=24), audio_dur={last_a_dur:.3f}s (>=23.9), PHB=1.002")

    def run_trials(self):
        """Executes recovery matrix for each duration in [2, 5, 10]s: 1 observe (40s) + 3 rebuild (65s)."""
        url = f"https://192.168.0.136:18445/live/{self.room_id}/master.m3u8"
        trial_plan = []
        counter = 1
        for d in [2, 5, 10]:
            trial_plan.append({"index": counter, "trial_id": f"trial_{counter:02d}_d{d}s_obs", "outage_duration_s": float(d), "recovery_mode": "observe", "playback_duration_s": 40, "probe_timeout_s": 75.0})
            counter += 1
            for rep in range(1, 4):
                trial_plan.append({"index": counter, "trial_id": f"trial_{counter:02d}_d{d}s_reb_rep{rep}", "outage_duration_s": float(d), "recovery_mode": "rebuild", "playback_duration_s": 65, "probe_timeout_s": 105.0})
                counter += 1

        actual_rebuild_failures = 0
        for plan in trial_plan:
            idx, trial_id, outage_dur_s = plan["index"], plan["trial_id"], plan["outage_duration_s"]
            rec_mode, playback_dur_s, probe_timeout_s = plan["recovery_mode"], plan["playback_duration_s"], plan["probe_timeout_s"]

            self.check_deadline(trial_id)
            trial_dir = os.path.join(NEW_RESULTS_DIR, trial_id)
            os.makedirs(trial_dir, exist_ok=True)
            pre_delay_s = ((idx * 0.073) % 0.334)
            time.sleep(pre_delay_s)

            offset_before = os.path.getsize(experiment.H2_ACCESS_LOG) if os.path.exists(experiment.H2_ACCESS_LOG) else 0
            probe_jsonl = os.path.join(trial_dir, "probe.jsonl")
            probe_stderr = os.path.join(trial_dir, "probe.stderr.log")
            access_slice_path = os.path.join(trial_dir, "access.log")

            cmd = [
                self.tested_probe_bin, "--url", url, "--nonce", str(self.nonce), "--output", probe_jsonl,
                "--duration", str(playback_dur_s), "--waits", "true", "--offset-ms", "1200",
                "--forward-buffer", "1.2", "--startup-mode", "precision", "--recovery-mode", rec_mode,
            ]
            launch_utc = base_module.utc_now_iso()
            launch_epoch_s = time.time()
            launch_mono_ms = int(time.clock_gettime(time.CLOCK_MONOTONIC) * 1000)

            experiment.log(f"Launching {trial_id}/12 [mode={rec_mode}, outage={outage_dur_s}s, dur={playback_dur_s}s]...")
            self.record_event(
                "trial_started", trial_index=idx, trial_id=trial_id, recovery_mode=rec_mode, outage_duration_s=outage_dur_s,
                startup_mode="precision", initial_waits=True, waits=True, offset_ms=1200, forward_buffer_seconds=1.2,
                duration_s=playback_dur_s, pre_delay_target_s=round(pre_delay_s, 6), launch_utc=launch_utc,
                launch_epoch_s=launch_epoch_s, launch_mono_ms=launch_mono_ms,
            )

            def emit_adapter(event_dict: dict):
                ec = dict(event_dict)
                en = ec.pop("event", "delivery_outage")
                self.record_event(en, trial_id=trial_id, **ec)

            outage, timed_out, ret = None, False, None
            t_probe_start = time.monotonic()
            gen1_align_completed_mono_ms, fault_start_mono_ms, fault_started = None, None, False
            jsonl_offset, jsonl_tail_bytes = 0, b""

            with open(probe_stderr, "w", encoding="utf-8") as err_f:
                proc = subprocess.Popen(cmd, stderr=err_f)
                self.probe_proc = proc
                try:
                    while True:
                        self.check_cancellation()
                        now_py = time.monotonic()
                        if (probe_timeout_s - (now_py - t_probe_start)) <= 0:
                            timed_out = True
                            try: proc.kill(); ret = proc.wait(timeout=5)
                            except Exception: pass
                            break
                        ret = proc.poll()
                        if ret is not None:
                            break

                        chunk = b""
                        if os.path.exists(probe_jsonl):
                            try:
                                with open(probe_jsonl, "rb") as jf:
                                    jf.seek(jsonl_offset); chunk = jf.read()
                            except FileNotFoundError: chunk = b""
                            except OSError as oe: raise RuntimeError(f"Audit I/O failure: {oe}") from oe

                        if chunk:
                            jsonl_offset += len(chunk)
                            lines = (jsonl_tail_bytes + chunk).split(b"\n")
                            jsonl_tail_bytes = lines[-1]
                            for lb in lines[:-1]:
                                lb = lb.strip()
                                if not lb: continue
                                try: rec = json.loads(lb.decode("utf-8"))
                                except Exception as je: raise RuntimeError(f"Malformed JSON in {probe_jsonl}: {je}") from je

                                if gen1_align_completed_mono_ms is None:
                                    if rec.get("event") == "alignment_completed" and rec.get("generation", 1) == 1:
                                        obs_ms = rec.get("observation_mono_ms")
                                        if obs_ms is None: raise RuntimeError("Missing observation_mono_ms in gen1 alignment_completed")
                                        gen1_align_completed_mono_ms = int(obs_ms)
                                        fault_start_mono_ms = gen1_align_completed_mono_ms + 10_000
                                        self.record_event("gen1_alignment_completed_detected", trial_id=trial_id, observation_mono_ms=gen1_align_completed_mono_ms, scheduled_fault_start_mono_ms=fault_start_mono_ms)
                                        experiment.log(f"Gen1 aligned at {gen1_align_completed_mono_ms}; pause in 10s at {fault_start_mono_ms}")

                        if gen1_align_completed_mono_ms is None and (now_py - t_probe_start) > 30.0:
                            experiment.log(f"ERROR: {trial_id} fail-closed: no gen1 alignment_completed within 30s")
                            timed_out = True
                            try: proc.kill(); proc.wait(timeout=2)
                            except Exception: pass
                            raise RuntimeError(f"Fail-closed: no gen1 alignment within 30s in {trial_id}")

                        if gen1_align_completed_mono_ms is not None and not fault_started:
                            now_posix_ms = int(time.clock_gettime(time.CLOCK_MONOTONIC) * 1000)
                            if now_posix_ms >= fault_start_mono_ms:
                                fault_started = True
                                outage = DeliveryOutage(self.nginx_proc, emit=emit_adapter)
                                self.current_outage = outage
                                experiment.log(f"Triggering {outage_dur_s}s delivery pause on PID {self.nginx_proc.pid} in {trial_id} at {now_posix_ms}...")
                                outage.start(outage_dur_s)

                        if outage is not None: outage.tick()
                        time.sleep(0.050)
                finally:
                    if outage is not None and outage.needs_continue:
                        try: outage.restore(reason="trial_ended")
                        except Exception as oe: experiment.log(f"ERROR: restoration failed: {oe}")
                    if outage is not None and not outage.needs_continue:
                        self.current_outage = None

                    if proc.poll() is None:
                        try: proc.terminate(); proc.wait(timeout=2)
                        except Exception:
                            try: proc.kill(); proc.wait(timeout=2)
                            except Exception: pass

                    if proc.poll() is not None:
                        self.probe_proc = None
                    else:
                        self.record_event("probe_reap_failed", trial_id=trial_id, pid=proc.pid)
                        raise RuntimeError(f"Probe PID {proc.pid} unconfirmed reaping in {trial_id}")

            if self.current_outage is not None and self.current_outage.needs_continue:
                experiment.log(f"ABORT: Gateway PID {self.nginx_proc.pid} still paused after {trial_id}; aborting matrix.")
                break

            end_utc = base_module.utc_now_iso()
            end_epoch_s = time.time()
            end_mono_ms = int(time.clock_gettime(time.CLOCK_MONOTONIC) * 1000)
            time.sleep(0.5)

            offset_after = os.path.getsize(experiment.H2_ACCESS_LOG) if os.path.exists(experiment.H2_ACCESS_LOG) else 0
            log_slice = b""
            if os.path.exists(experiment.H2_ACCESS_LOG) and offset_after > offset_before:
                with open(experiment.H2_ACCESS_LOG, "rb") as af:
                    af.seek(offset_before); log_slice = af.read(offset_after - offset_before)
            with open(access_slice_path, "wb") as sf:
                sf.write(log_slice)

            trial_meta = {
                "trial_index": idx, "trial_id": trial_id, "recovery_mode": rec_mode, "outage_duration_s": outage_dur_s,
                "playback_duration_s": playback_dur_s, "startup_mode": "precision", "initial_waits": True, "waits": True,
                "offset_ms": 1200, "forward_buffer_seconds": 1.2, "pre_delay_target_s": round(pre_delay_s, 6),
                "launch_utc": launch_utc, "launch_epoch_s": launch_epoch_s, "launch_mono_ms": launch_mono_ms,
                "end_utc": end_utc, "end_epoch_s": end_epoch_s, "end_mono_ms": end_mono_ms, "exit_code": ret,
                "timed_out": timed_out, "fault_exercised": fault_started, "gateway_pid": self.nginx_proc.pid,
            }

            probe_records = []
            evidence_read_error = None
            if os.path.exists(probe_jsonl):
                try:
                    with open(probe_jsonl, "r", encoding="utf-8") as jf:
                        for line_no, l in enumerate(jf, 1):
                            l = l.strip()
                            if l:
                                try: probe_records.append(json.loads(l))
                                except Exception as je:
                                    evidence_read_error = f"malformed_or_truncated_probe_jsonl_at_line_{line_no}: {je}"
                                    break
                except Exception as e: evidence_read_error = f"failed_reading_probe_jsonl: {e}"
            else:
                evidence_read_error = "probe_jsonl_missing"

            events_path = os.path.join(NEW_RESULTS_DIR, "events.jsonl")
            trial_fault_events = []
            if os.path.exists(events_path):
                try:
                    with open(events_path, "r", encoding="utf-8") as ef:
                        for line_no, l in enumerate(ef, 1):
                            l = l.strip()
                            if l:
                                try: ev = json.loads(l)
                                except Exception as je:
                                    if evidence_read_error is None: evidence_read_error = f"malformed_events_jsonl_at_line_{line_no}: {je}"
                                    break
                                if ev.get("trial_id") == trial_id and ev.get("event") in ("delivery_outage_started", "delivery_outage_restored"):
                                    trial_fault_events.append(ev)
                except Exception as e:
                    if evidence_read_error is None: evidence_read_error = f"failed_reading_events_jsonl: {e}"

            if evidence_read_error is not None:
                experiment.log(f"ERROR: Evidence read failure in {trial_id}: {evidence_read_error}; failing closed.")
                eval_res = {
                    "trial_id": trial_id, "recovery_mode": rec_mode, "outage_duration_s": outage_dur_s,
                    "quality_failure": True, "quality_failure_reason": evidence_read_error,
                    "comparator_invalidated": (rec_mode == "observe"), "rebuild_exercised": False,
                    "native_recovery_sufficient": False, "rebuild_latency_met": False,
                }
            else:
                eval_res = evaluate_recovery_trial(probe_records, trial_fault_events, trial_meta)

            trial_meta["recovery_eval"] = eval_res
            self.trials_meta.append(trial_meta)
            self.record_event("trial_completed", **trial_meta)
            experiment.log(
                f"Completed {trial_id}/12 [mode={rec_mode}, outage={outage_dur_s}s, dur={playback_dur_s}s]: "
                f"exit={ret}, timed_out={timed_out}, quality_failure={eval_res.get('quality_failure')}"
            )

            if rec_mode == "rebuild":
                is_rebuild_fail = (ret != 0 or timed_out or eval_res.get("quality_failure") is True)
                if is_rebuild_fail:
                    actual_rebuild_failures += 1
                    experiment.log(f"Actual rebuild failure #{actual_rebuild_failures} in {trial_id}: {eval_res.get('quality_failure_reason')}")
                    if actual_rebuild_failures >= 2:
                        experiment.log(f"Stopping matrix after {actual_rebuild_failures} actual rebuild failures; recording remaining as NOT_RUN.")
                        curr_idx = trial_plan.index(plan)
                        for rem_plan in trial_plan[curr_idx + 1:]:
                            rem_meta = {
                                "trial_index": rem_plan["index"], "trial_id": rem_plan["trial_id"],
                                "recovery_mode": rem_plan["recovery_mode"], "outage_duration_s": rem_plan["outage_duration_s"],
                                "status": "NOT_RUN", "reason": "matrix_stopped_after_2_rebuild_failures",
                            }
                            self.trials_meta.append(rem_meta)
                            self.record_event("trial_not_run", **rem_meta)
                        break

    def execute_experiment(self):
        """Executes setup lifecycle, warmup verification, 12 recovery trials, and cleanup."""
        cancelled = False
        try:
            self.acquire_results_directory(); self.check_cancellation()
            self.verify_prerequisites(); self.check_cancellation()
            self.start_h2_nginx(); self.check_cancellation()
            self.verify_h2_tls_preflight(); self.check_cancellation()
            self.publish_media(); self.check_cancellation()
            self.start_egress_and_verify_worker(); self.check_cancellation()
            self.verify_stream_parameters_and_warmup(); self.check_cancellation()
            self.run_trials(); self.check_cancellation()
            self.record_event("execution_completed", utc=base_module.utc_now_iso(), total_trials=len(self.trials_meta), trials_meta=self.trials_meta)
            experiment.log("Trials executed; raw execution_completed recorded.")
        except base_module.HarnessCancelledError as ce:
            cancelled = True
            experiment.log(f"Experiment cancelled: {ce}")
        finally:
            try:
                if self.current_outage is not None and self.current_outage.needs_continue:
                    try: self.current_outage.restore(reason="experiment_cleanup")
                    except Exception as e: experiment.log(f"Warning: cleanup restore failed: {e}")
            finally:
                try: self.cleanup()
                except Exception: self.cleanup_success = False; raise

        experiment.log(f"Actual completed trials count: {len(self.trials_meta)}")
        if cancelled or self.cancelled_signal is not None:
            experiment.log("Exiting nonzero due to cancellation.")
            sys.exit(1)
        if not self.cleanup_success:
            experiment.log("Cleanup reported unverified resources or occupied ports.")
            sys.exit(1)
        if len(self.trials_meta) != 12:
            experiment.log(f"Experiment expected 12 trials, got {len(self.trials_meta)}.")
            sys.exit(1)

        not_run_trials = [t for t in self.trials_meta if t.get("status") == "NOT_RUN"]
        if not_run_trials:
            experiment.log(f"Experiment aborted prematurely: {len(not_run_trials)} trials NOT_RUN.")
            sys.exit(1)

        nonzero_exits = [t for t in self.trials_meta if t.get("exit_code") != 0 or t.get("timed_out")]
        if nonzero_exits:
            experiment.log(f"Probe execution failures detected in {len(nonzero_exits)} trial(s).")
            sys.exit(1)

        rebuild_cases = [t for t in self.trials_meta if t.get("recovery_mode") == "rebuild"]
        candidate_passed = [
            t for t in rebuild_cases
            if t.get("recovery_eval", {}).get("rebuild_latency_met") is True
            and t.get("recovery_eval", {}).get("quality_failure") is False
        ]
        observe_controls = [t for t in self.trials_meta if t.get("recovery_mode") == "observe"]
        valid_controls = [
            t for t in observe_controls
            if t.get("recovery_eval", {}).get("quality_failure") is False
            and t.get("recovery_eval", {}).get("comparator_invalidated") is False
        ]

        reb_5s = [t for t in rebuild_cases if abs(float(t.get("outage_duration_s", 0)) - 5.0) < 0.1]
        reb_10s = [t for t in rebuild_cases if abs(float(t.get("outage_duration_s", 0)) - 10.0) < 0.1]
        exercised_5s = any(t.get("recovery_eval", {}).get("rebuild_exercised") is True for t in reb_5s)
        exercised_10s = any(t.get("recovery_eval", {}).get("rebuild_exercised") is True for t in reb_10s)

        experiment.log(
            f"Recovery experiment verification: {len(self.trials_meta)} trials completed, "
            f"{len(candidate_passed)}/9 candidate cases meeting latency goal, "
            f"{len(valid_controls)}/3 valid controls, "
            f"5s rebuild exercised: {exercised_5s}, 10s rebuild exercised: {exercised_10s}."
        )

        if len(candidate_passed) < 9 or len(valid_controls) < 3:
            experiment.log("Recovery acceptance threshold not met.")
            sys.exit(1)

        if not (exercised_5s and exercised_10s):
            experiment.log("Missing actual replacement exercise in 5s or 10s categories.")
            sys.exit(1)

        experiment.log("Native warm-recovery experiment successful.")


def main():
    parser = argparse.ArgumentParser(description="AVPlayer native warm-recovery under delivery pause experiment harness.")
    parser.add_argument("--run", action="store_true", help="Execute the 12-process native recovery experiment")
    parser.add_argument("--nonce", type=int, default=None, help="Explicit uint32 session nonce")
    args = parser.parse_args()

    if not args.run:
        parser.print_help()
        sys.exit(0)

    nonce = args.nonce if args.nonce is not None else (int(time.time()) & 0xFFFFFFFF)
    harness = WarmRecoveryHarness(nonce=nonce)

    def handle_signal(sig, _frame):
        if harness.cancelled_signal is None:
            harness.cancelled_signal = sig

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)
    harness.execute_experiment()


if __name__ == "__main__":
    main()
