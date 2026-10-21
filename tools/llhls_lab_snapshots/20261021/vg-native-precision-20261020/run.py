#!/usr/bin/env python3
"""
run.py - Subclassed native precision startup (Arm A native vs Arm B decoder preroll + precise start) experiment harness.
Reuses cancellation, atomic acquisition, preflight, Nginx, TLS, publisher,
single-POST worker verification, and cleanup from base.H2CaptureHarness.
Implements warmup verification with stream parameter validation (CAN-BLOCK-RELOAD=YES,
PART-HOLD-BACK=1.002) and 21-process sequence: 20 ABBA trials (Arm A: native, Arm B: precision)
followed by 1 Arm B 300s stability run. Raw source-to-native-video-output age measurement.
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
NEW_ROOT = "/private/tmp/vg-native-precision-20261020"

if OLD_ROOT not in sys.path:
    sys.path.insert(0, OLD_ROOT)
if BASE_ROOT not in sys.path:
    sys.path.insert(0, BASE_ROOT)
if NEW_ROOT not in sys.path:
    sys.path.insert(0, NEW_ROOT)

import experiment

# Subclass base.H2CaptureHarness via importlib to avoid module name shadowing
base_spec = importlib.util.spec_from_file_location("base_run", os.path.join(BASE_ROOT, "run.py"))
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


class StartupPrecisionABHarness(base_module.H2CaptureHarness):
    def __init__(self, nonce: int):
        super().__init__(nonce=nonce)
        self.run_id = f"vg_precision_{nonce}"
        self.room_id = f"room_precision_{nonce}"
        self.host_identity = f"host_precision_{nonce}"
        self.tested_probe_bin: str | None = None
        self.tested_probe_sha: str | None = None

    def verify_prerequisites(self):
        """
        Verifies prerequisites, ensuring new Probe binary exists and its hash is recorded,
        then calls base preflight checks and updates provenance with new source hashes.
        """
        probe_bin = os.path.join(NEW_ROOT, "build", "Probe")
        if not (os.path.isfile(probe_bin) and os.access(probe_bin, os.R_OK)):
            alt_bin = os.path.join(NEW_ROOT, "Probe")
            if os.path.isfile(alt_bin) and os.access(alt_bin, os.R_OK):
                probe_bin = alt_bin
            else:
                raise RuntimeError(
                    f"BLOCKED: New Probe binary missing or unreadable at {probe_bin}"
                )

        self.tested_probe_bin = probe_bin
        self.tested_probe_sha = experiment.file_sha256(probe_bin)

        # Call parent preflight checks
        super().verify_prerequisites()

        # Update provenance with actual new source/binary hashes and packet_capture=False
        prov_path = os.path.join(NEW_RESULTS_DIR, "provenance.json")
        if os.path.exists(prov_path):
            with open(prov_path, "r", encoding="utf-8") as f:
                prov = json.load(f)
            prov["packet_capture"] = False
            prov["tested_probe_binary"] = {
                "path": self.tested_probe_bin,
                "sha256": self.tested_probe_sha,
            }
            prov["new_source_hashes_sha256"] = {
                "main.swift": experiment.file_sha256(os.path.join(NEW_ROOT, "main.swift")),
                "PrecisionStartup.swift": experiment.file_sha256(os.path.join(NEW_ROOT, "PrecisionStartup.swift")),
                "run.py": experiment.file_sha256(os.path.join(NEW_ROOT, "run.py")),
                "analyze_offset.py": experiment.file_sha256(os.path.join(NEW_ROOT, "analyze_offset.py")),
                "test_offset.py": experiment.file_sha256(os.path.join(NEW_ROOT, "test_offset.py")),
                "nginx.conf": experiment.file_sha256(NEW_NGINX_CONF),
            }
            with open(prov_path, "w", encoding="utf-8") as f:
                json.dump(prov, f, indent=2)

    def verify_stream_parameters_and_warmup(self):
        """
        Polls owned /live/ROOM/{vhi.m3u8,a.m3u8} through existing pinned TLS context,
        VGCanary UA, 3s request timeout, 1s delay, 45s total, checking cancellation each loop.
        Validates CAN-BLOCK-RELOAD=YES and PART-HOLD-BACK=1.002 exactly (tolerance 0.000001).
        Uses analyze.parse_playlist_edge to require video completed_extinf_s >= 24
        and audio completed_extinf_s >= 23.9 before starts.
        Saves results/pretrial_video.m3u8 and results/pretrial_audio.m3u8 and records
        warmup_verified event on success.
        """
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
                    attrs = {}
                    for part in raw.split(","):
                        if "=" in part:
                            k, v = part.split("=", 1)
                            attrs[k.strip()] = v.strip()
                    return attrs
            return {}

        t0 = time.monotonic()
        warmup_deadline = t0 + 45.0
        warmup_ready = False
        last_video_body = ""
        last_audio_body = ""
        last_v_dur = 0.0
        last_a_dur = 0.0
        last_v_phb = 0.0
        last_a_phb = 0.0

        while True:
            self.check_cancellation()
            rem = warmup_deadline - time.monotonic()
            if rem <= 0:
                break

            try:
                # Video request bounded by min(3.0, remaining)
                rem_v = warmup_deadline - time.monotonic()
                if rem_v <= 0:
                    break
                v_timeout = min(3.0, rem_v)
                v_req = urllib.request.Request(video_url, headers={"User-Agent": ua})
                with urllib.request.urlopen(v_req, timeout=v_timeout, context=ssl_ctx) as v_resp:
                    if v_resp.status != 200:
                        rem_sleep = min(1.0, max(0.01, warmup_deadline - time.monotonic()))
                        time.sleep(rem_sleep)
                        continue
                    video_body = v_resp.read().decode("utf-8", errors="replace")

                self.check_cancellation()

                # Audio request bounded by min(3.0, remaining)
                rem_a = warmup_deadline - time.monotonic()
                if rem_a <= 0:
                    break
                a_timeout = min(3.0, rem_a)
                a_req = urllib.request.Request(audio_url, headers={"User-Agent": ua})
                with urllib.request.urlopen(a_req, timeout=a_timeout, context=ssl_ctx) as a_resp:
                    if a_resp.status != 200:
                        rem_sleep = min(1.0, max(0.01, warmup_deadline - time.monotonic()))
                        time.sleep(rem_sleep)
                        continue
                    audio_body = a_resp.read().decode("utf-8", errors="replace")

                self.check_cancellation()

                # Validate SERVER-CONTROL parameters: CAN-BLOCK-RELOAD=YES and PART-HOLD-BACK=1.002
                v_sc = parse_server_control(video_body)
                a_sc = parse_server_control(audio_body)

                if "CAN-BLOCK-RELOAD" not in v_sc or v_sc.get("CAN-BLOCK-RELOAD") != "YES":
                    raise RuntimeError(f"ABORT: video CAN-BLOCK-RELOAD is {v_sc.get('CAN-BLOCK-RELOAD')}, expected YES")
                if "CAN-BLOCK-RELOAD" not in a_sc or a_sc.get("CAN-BLOCK-RELOAD") != "YES":
                    raise RuntimeError(f"ABORT: audio CAN-BLOCK-RELOAD is {a_sc.get('CAN-BLOCK-RELOAD')}, expected YES")

                try:
                    v_phb = float(v_sc.get("PART-HOLD-BACK", "0"))
                except ValueError:
                    raise RuntimeError(f"ABORT: video PART-HOLD-BACK malformed: {v_sc.get('PART-HOLD-BACK')}")

                try:
                    a_phb = float(a_sc.get("PART-HOLD-BACK", "0"))
                except ValueError:
                    raise RuntimeError(f"ABORT: audio PART-HOLD-BACK malformed: {a_sc.get('PART-HOLD-BACK')}")

                # Reject nonfinite PART-HOLD-BACK (NaN or Inf)
                if not math.isfinite(v_phb):
                    raise RuntimeError(f"ABORT: video PART-HOLD-BACK nonfinite: {v_phb}")
                if not math.isfinite(a_phb):
                    raise RuntimeError(f"ABORT: audio PART-HOLD-BACK nonfinite: {a_phb}")

                if abs(v_phb - 1.002) > 0.000001:
                    raise RuntimeError(f"ABORT: video PART-HOLD-BACK is {v_phb}, expected exactly 1.002")
                if abs(a_phb - 1.002) > 0.000001:
                    raise RuntimeError(f"ABORT: audio PART-HOLD-BACK is {a_phb}, expected exactly 1.002")

                # Check completed durations using base analyze.parse_playlist_edge
                v_edge = base_module.analyze.parse_playlist_edge(video_body)
                a_edge = base_module.analyze.parse_playlist_edge(audio_body)

                v_dur = v_edge.get("completed_extinf_s") or 0.0
                a_dur = a_edge.get("completed_extinf_s") or 0.0

                last_video_body = video_body
                last_audio_body = audio_body
                last_v_dur = v_dur
                last_a_dur = a_dur
                last_v_phb = v_phb
                last_a_phb = a_phb

                if v_edge.get("valid_edge") and a_edge.get("valid_edge"):
                    if v_dur >= 24.0 and a_dur >= 23.9:
                        # Check remaining budget and cancellation before final success
                        self.check_cancellation()
                        if time.monotonic() >= warmup_deadline:
                            break
                        warmup_ready = True
                        break
            except RuntimeError:
                raise
            except Exception as e:
                experiment.log(f"Polling warmup waiting for playlist readiness: {e}")

            rem_sleep = min(1.0, max(0.01, warmup_deadline - time.monotonic()))
            time.sleep(rem_sleep)

        if not warmup_ready:
            raise RuntimeError(
                f"Timed out after 45s waiting for warmup threshold (v_dur={last_v_dur}/24.0, a_dur={last_a_dur}/23.9)"
            )

        # Final pre-commit cancellation check
        self.check_cancellation()

        # Save exact bodies results/pretrial_video.m3u8, pretrial_audio.m3u8
        with open(os.path.join(NEW_RESULTS_DIR, "pretrial_video.m3u8"), "w", encoding="utf-8") as vf:
            vf.write(last_video_body)
        with open(os.path.join(NEW_RESULTS_DIR, "pretrial_audio.m3u8"), "w", encoding="utf-8") as af:
            af.write(last_audio_body)

        now_utc = base_module.utc_now_iso()
        now_mono = int(time.clock_gettime(time.CLOCK_MONOTONIC) * 1000)
        self.record_event(
            "warmup_verified",
            utc=now_utc,
            observation_mono_ms=now_mono,
            video_completed_extinf_s=round(last_v_dur, 3),
            audio_completed_extinf_s=round(last_a_dur, 3),
            video_part_hold_back=last_v_phb,
            audio_part_hold_back=last_a_phb,
            can_block_reload="YES",
        )
        experiment.log(
            f"Warmup verified: video_dur={last_v_dur:.3f}s (>=24), audio_dur={last_a_dur:.3f}s (>=23.9), PHB=1.002"
        )

    def run_trials(self):
        """
        Executes 21 trials: sequence ABBA repeated 5 times (trials 1..20, 15s duration),
        followed by 1 Arm B stability run (trial 21, 300s duration).
        Arm A: native startup mode, forward_buffer_seconds=1.2.
        Arm B: precision startup mode, forward_buffer_seconds=1.2.
        Every trial: offset_ms=1200, initial waits=true.
        Outer timeout 50s for trials 1..20, 335s for stability trial.
        Stop trials after two nonzero B exits, retain failed evidence.
        Cancellation poll <= 250ms, terminate 2s / kill 2s / reap verification with retained handle on failure.
        """
        url = f"https://192.168.0.136:18445/live/{self.room_id}/master.m3u8"
        pattern = ["A", "B", "B", "A"] * 5 + ["B"]  # 21 trials total
        nonzero_b_count = 0

        for idx in range(1, 22):
            is_stability = (idx == 21)
            trial_id = "stability" if is_stability else f"trial_{idx:02d}"
            self.check_deadline(trial_id)

            arm = pattern[idx - 1]
            kind = "stability" if is_stability else "paired"
            pair_idx = None if is_stability else ((idx - 1) // 2 + 1)
            waits_bool = True
            offset_ms = 1200
            forward_buffer_seconds = 1.2
            startup_mode = "native" if arm == "A" else "precision"
            waits_after_precision = False if arm == "B" else True
            duration_s = 300 if is_stability else 15
            probe_timeout_s = 335.0 if is_stability else 50.0

            trial_dir = os.path.join(NEW_RESULTS_DIR, trial_id)
            os.makedirs(trial_dir, exist_ok=True)

            pre_delay_s = (((pair_idx or 1) * 0.073) % 0.334)
            time.sleep(pre_delay_s)

            offset_before = (
                os.path.getsize(experiment.H2_ACCESS_LOG)
                if os.path.exists(experiment.H2_ACCESS_LOG)
                else 0
            )

            probe_jsonl = os.path.join(trial_dir, "probe.jsonl")
            probe_stderr = os.path.join(trial_dir, "probe.stderr.log")
            access_slice_path = os.path.join(trial_dir, "access.log")

            cmd = [
                self.tested_probe_bin,
                "--url", url,
                "--nonce", str(self.nonce),
                "--output", probe_jsonl,
                "--duration", str(duration_s),
                "--waits", "true",
                "--offset-ms", str(offset_ms),
                "--forward-buffer", str(forward_buffer_seconds),
                "--startup-mode", startup_mode,
            ]

            launch_utc = base_module.utc_now_iso()
            launch_epoch_s = time.time()
            launch_mono_ms = int(time.clock_gettime(time.CLOCK_MONOTONIC) * 1000)

            experiment.log(
                f"Launching {trial_id}/21 [{kind}, Arm {arm} ({startup_mode}), forward_buffer={forward_buffer_seconds}s, duration={duration_s}s, offset_ms={offset_ms}] "
                f"(pre_delay={pre_delay_s:.3f}s)..."
            )
            self.record_event(
                "trial_started",
                trial_index=idx,
                trial_id=trial_id,
                kind=kind,
                arm=arm,
                pair_index=pair_idx,
                startup_mode=startup_mode,
                initial_waits=True,
                waits_after_precision=waits_after_precision,
                waits=waits_bool,
                offset_ms=offset_ms,
                forward_buffer_seconds=forward_buffer_seconds,
                duration_s=duration_s,
                pre_delay_target_s=round(pre_delay_s, 6),
                launch_utc=launch_utc,
                launch_epoch_s=launch_epoch_s,
                launch_mono_ms=launch_mono_ms,
            )

            with open(probe_stderr, "w", encoding="utf-8") as err_f:
                proc = subprocess.Popen(cmd, stderr=err_f)
                self.probe_proc = proc
                timed_out = False
                ret = None
                t_probe_start = time.monotonic()

                try:
                    while True:
                        self.check_cancellation()
                        elapsed = time.monotonic() - t_probe_start
                        rem = probe_timeout_s - elapsed
                        if rem <= 0:
                            timed_out = True
                            try:
                                proc.kill()
                            except OSError:
                                pass
                            try:
                                ret = proc.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                pass
                            break

                        slice_timeout = min(0.25, rem)
                        try:
                            ret = proc.wait(timeout=slice_timeout)
                            break
                        except subprocess.TimeoutExpired:
                            continue
                finally:
                    if proc.poll() is None:
                        try:
                            proc.terminate()
                            proc.wait(timeout=2)
                        except Exception:
                            try:
                                proc.kill()
                                proc.wait(timeout=2)
                            except Exception:
                                pass

                    if proc.poll() is not None:
                        self.probe_proc = None
                    else:
                        self.record_event("probe_reap_failed", trial_id=trial_id, pid=proc.pid)
                        experiment.log(
                            f"ERROR: Probe PID {proc.pid} reaping unconfirmed in {trial_id}; aborting trials."
                        )
                        raise RuntimeError(
                            f"Probe PID {proc.pid} unconfirmed reaping after bounded attempts in {trial_id}; aborting trials"
                        )

            end_utc = base_module.utc_now_iso()
            end_epoch_s = time.time()
            end_mono_ms = int(time.clock_gettime(time.CLOCK_MONOTONIC) * 1000)

            time.sleep(0.5)  # 0.5s flush for Nginx access.log
            offset_after = (
                os.path.getsize(experiment.H2_ACCESS_LOG)
                if os.path.exists(experiment.H2_ACCESS_LOG)
                else 0
            )
            log_slice = b""
            if os.path.exists(experiment.H2_ACCESS_LOG) and offset_after > offset_before:
                with open(experiment.H2_ACCESS_LOG, "rb") as af:
                    af.seek(offset_before)
                    log_slice = af.read(offset_after - offset_before)
            with open(access_slice_path, "wb") as sf:
                sf.write(log_slice)

            trial_meta = {
                "trial_index": idx,
                "trial_id": trial_id,
                "kind": kind,
                "arm": arm,
                "pair_index": pair_idx,
                "startup_mode": startup_mode,
                "initial_waits": True,
                "waits_after_precision": waits_after_precision,
                "waits": waits_bool,
                "offset_ms": offset_ms,
                "forward_buffer_seconds": forward_buffer_seconds,
                "duration_s": duration_s,
                "pre_delay_target_s": round(pre_delay_s, 6),
                "launch_utc": launch_utc,
                "launch_epoch_s": launch_epoch_s,
                "launch_mono_ms": launch_mono_ms,
                "end_utc": end_utc,
                "end_epoch_s": end_epoch_s,
                "end_mono_ms": end_mono_ms,
                "exit_code": ret,
                "timed_out": timed_out,
            }
            self.trials_meta.append(trial_meta)
            self.record_event("trial_completed", **trial_meta)
            experiment.log(
                f"Completed {trial_id}/21 [{kind}, Arm {arm} ({startup_mode}), forward_buffer={forward_buffer_seconds}s, duration={duration_s}s]: exit={ret}, timed_out={timed_out}"
            )

            # Stop trials after two nonzero B exits, retain failed evidence
            if arm == "B" and (ret != 0 or timed_out):
                nonzero_b_count += 1
                if nonzero_b_count >= 2:
                    experiment.log(
                        f"Stopping trials after {nonzero_b_count} nonzero Arm B exits; retaining failed evidence."
                    )
                    break

    def execute_experiment(self):
        """
        Executes setup lifecycle, warmup verification, 21 trials, and records raw execution metadata.
        Lifecycle setup order: preflight, Nginx, TLS, publish, solePOSTworker, warmup, trials, finally cleanup.
        Runtime success requires all 21 processes exited 0 and clean verified teardown.
        Runtime success is NOT playback acceptance.
        """
        cancelled = False
        try:
            self.acquire_results_directory()
            self.check_cancellation()
            self.verify_prerequisites()
            self.check_cancellation()
            self.start_h2_nginx()
            self.check_cancellation()
            self.verify_h2_tls_preflight()
            self.check_cancellation()
            self.publish_media()
            self.check_cancellation()
            self.start_egress_and_verify_worker()
            self.check_cancellation()
            self.verify_stream_parameters_and_warmup()
            self.check_cancellation()
            self.run_trials()
            self.check_cancellation()
            self.record_event(
                "execution_completed",
                utc=base_module.utc_now_iso(),
                total_trials=len(self.trials_meta),
                trials_meta=self.trials_meta,
            )
            experiment.log("Trials executed; raw execution_completed recorded.")
        except base_module.HarnessCancelledError as ce:
            cancelled = True
            experiment.log(f"Experiment cancelled: {ce}")
        finally:
            self.cleanup()

        # Log actual completed count; retain expected21 guard AFTER cleanup
        experiment.log(f"Actual completed trials count: {len(self.trials_meta)}")

        if cancelled or self.cancelled_signal is not None:
            experiment.log("Exiting nonzero due to cancellation.")
            sys.exit(1)

        if not self.cleanup_success:
            experiment.log("Cleanup reported unverified resources or occupied ports.")
            sys.exit(1)

        if len(self.trials_meta) != 21:
            experiment.log(f"Experiment expected 21 trials, got {len(self.trials_meta)}.")
            sys.exit(1)

        nonzero_exits = [t for t in self.trials_meta if t.get("exit_code") != 0 or t.get("timed_out")]
        if nonzero_exits:
            experiment.log(f"Probe execution failures detected in {len(nonzero_exits)} trial(s).")
            sys.exit(1)

        experiment.log("Native precision experiment raw execution successful (runtime success only; NOT playback acceptance).")


def main():
    parser = argparse.ArgumentParser(
        description="AVPlayer native precision startup (Arm A native vs Arm B decoder preroll + precise start) experiment harness."
    )
    parser.add_argument("--run", action="store_true", help="Execute the 21-process native precision experiment")
    parser.add_argument("--nonce", type=int, default=None, help="Explicit uint32 session nonce")
    args = parser.parse_args()

    if not args.run:
        parser.print_help()
        sys.exit(1)

    nonce = args.nonce if args.nonce is not None else (int(time.time()) & 0xFFFFFFFF)
    harness = StartupPrecisionABHarness(nonce=nonce)

    def handle_signal(sig, _frame):
        if harness.cancelled_signal is None:
            harness.cancelled_signal = sig

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    harness.execute_experiment()


if __name__ == "__main__":
    main()
