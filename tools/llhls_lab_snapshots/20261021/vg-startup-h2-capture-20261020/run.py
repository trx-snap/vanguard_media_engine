#!/usr/bin/env python3
"""
run.py - Frozen HTTP/2-only startup experiment harness.
Owns preflight provenance checks, subprocess lifecycle, single-POST Egress run control,
operator dumpcap handoff with canary verification, 12 sequential Probe trials, and cleanup.
"""

import sys
sys.dont_write_bytecode = True

import argparse
from datetime import datetime, timezone
import json
import os
import select
import shlex
import shutil
import signal
import socket
import ssl
import subprocess
import threading
import time
import urllib.error
import urllib.request

OLD_ROOT = "/private/tmp/vg-startup-auto-20261020-1338"
if OLD_ROOT not in sys.path:
    sys.path.insert(0, OLD_ROOT)

import experiment  # noqa: E402
import analyze     # noqa: E402

NEW_ROOT = "/private/tmp/vg-startup-h2-capture-20261020"
NEW_RESULTS_DIR = os.path.join(NEW_ROOT, "results_retry04")
NEW_NGINX_CONF = os.path.join(NEW_ROOT, "nginx-retry04.conf")

# Keep historical ROOT and BUILD_DIR read-only; redirect all outputs and Nginx paths
experiment.ROOT = OLD_ROOT
experiment.BUILD_DIR = os.path.join(OLD_ROOT, "build")
experiment.RESULTS_DIR = NEW_RESULTS_DIR
experiment.NGINX_CONF = NEW_NGINX_CONF
experiment.H2_PID_FILE = os.path.join(NEW_RESULTS_DIR, "nginx.pid")
experiment.H2_ACCESS_LOG = os.path.join(NEW_RESULTS_DIR, "nginx_access.log")
experiment.H2_ERROR_LOG = os.path.join(NEW_RESULTS_DIR, "nginx_error.log")

EXPECTED_HASHES = {
    "experiment.py": "c4a0c78a914a65a9a946ebf0fb3eb1169cb7db00e30d4489c5af77e0935415a9",
    "publisher.py": "f5403423c7f3a83b1b17943f5207d3cf60964e8d45ec4678dc3c1cd21456eaa6",
    "Probe": "e4442cd8d07fc664467803cfce23e1542f98dd168f9a9c4153067c017ebf1b39",
    "egress_runtime": "d89ec4c6ab3cb0d8e8ebe574953f79a69e6460a919cbb0a468130dcb8f3031ca",
}

LAB_CA_PATH = "/tmp/connects-egress-h3-stage-20261018_192200/certs/ca.crt"
EXPECTED_LAB_CA_SHA256 = "e174bd78b0c62bba8c2a3cb0d1bf16f06946952f7e91cdf4dec6250d380b02f3"

DUMPCAP_BIN = "/opt/homebrew/bin/dumpcap"
TSHARK_BIN = "/opt/homebrew/bin/tshark"
PCAPNG_PATH = os.path.join(NEW_RESULTS_DIR, "upstream.pcapng")
CAPTURE_STDERR_LOG = os.path.join(NEW_RESULTS_DIR, "capture.stderr.log")

OPERATOR_DUMPCAP_CMD = (
    "( set -o pipefail; sudo -u root /opt/homebrew/bin/dumpcap -i lo0 -s 0 -f 'tcp port 18080' -a duration:300 -a filesize:200000 -w - "
    "2>> /private/tmp/vg-startup-h2-capture-20261020/results_retry04/capture.stderr.log "
    "| /usr/bin/tee /private/tmp/vg-startup-h2-capture-20261020/results_retry04/upstream.pcapng > /dev/null )"
)


def create_lab_ssl_context(ca_path: str | None = None) -> ssl.SSLContext:
    """
    Creates a fixed lab endpoint SSL context using the stage CA cert.
    Rejects a missing or mismatched CA cert.
    Clears only VERIFY_X509_STRICT on this context, while keeping CERT_REQUIRED,
    check_hostname=True, and all other verification settings intact.
    """
    if ca_path is None:
        ca_path = LAB_CA_PATH
    if not os.path.isfile(ca_path):
        raise RuntimeError(f"BLOCKED: Lab CA cert missing: {ca_path}")
    actual_sha = experiment.file_sha256(ca_path)
    if actual_sha != EXPECTED_LAB_CA_SHA256:
        raise RuntimeError(
            f"BLOCKED: Lab CA cert SHA-256 mismatch: got {actual_sha}, expected {EXPECTED_LAB_CA_SHA256}"
        )
    ctx = ssl.create_default_context(cafile=ca_path)
    if hasattr(ssl.VerifyFlags, "VERIFY_X509_STRICT"):
        ctx.verify_flags &= ~ssl.VerifyFlags.VERIFY_X509_STRICT
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.check_hostname = True
    return ctx


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def check_tcp_reachable(host: str, port: int, timeout: float = 3.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def get_dumpcap_pids() -> list[int]:
    """
    Path-based PID detection observes writer processes (e.g. tee in the operator pipeline) while alive.
    These PIDs represent the operator capture pipeline, not direct proof of dumpcap activity.
    """
    pids = []
    try:
        res = subprocess.run(
            ["pgrep", "-f", PCAPNG_PATH],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                line = line.strip()
                if line.isdigit():
                    pid = int(line)
                    if pid != os.getpid() and pid not in pids:
                        pids.append(pid)
    except Exception:
        pass

    if not pids and os.path.exists(PCAPNG_PATH):
        try:
            res = subprocess.run(
                ["/usr/sbin/lsof", "-t", PCAPNG_PATH],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if res.returncode == 0:
                for line in res.stdout.splitlines():
                    line = line.strip()
                    if line.isdigit():
                        pid = int(line)
                        if pid != os.getpid() and pid not in pids:
                            pids.append(pid)
        except Exception:
            pass

    return pids


def is_capture_active() -> bool:
    return len(get_dumpcap_pids()) > 0


class HarnessCancelledError(Exception):
    """Raised when an external cancellation signal (e.g. SIGINT, SIGTERM) is requested."""
    pass


class H2CaptureHarness(experiment.ExperimentHarness):
    def __init__(self, nonce: int):
        super().__init__(nonce=nonce)
        self.run_id = f"vg_h2cap_{nonce}"
        self.room_id = f"room_h2cap_{nonce}"
        self.host_identity = f"host_h2cap_{nonce}"
        self.results_acquired = False
        self._cleaned_up = False
        self.cleanup_in_progress = False
        self.cleanup_completed = False
        self._cleanup_lock = threading.Lock()
        self.cancelled_signal: int | None = None
        self.cleanup_success = True
        self.trials_meta: list[dict] = []

    def check_cancellation(self):
        """
        Raises HarnessCancelledError if a cancellation signal has been recorded.
        Must only be called outside cleanup.
        """
        if self.cancelled_signal is not None and not self.cleanup_in_progress:
            raise HarnessCancelledError(f"Harness received cancellation signal {self.cancelled_signal}")

    def check_deadline(self, stage: str):
        self.check_cancellation()
        super().check_deadline(stage)

    def acquire_results_directory(self):
        """
        Atomically acquires the absent results directory.
        If it already exists, stops without modifying it or running cleanup against it.
        """
        if os.path.exists(NEW_RESULTS_DIR):
            raise RuntimeError(
                f"BLOCKED: Results directory already exists: {NEW_RESULTS_DIR}; "
                "stopping without modification or cleanup"
            )
        try:
            os.mkdir(NEW_RESULTS_DIR)
            self.results_acquired = True
        except FileExistsError:
            raise RuntimeError(
                f"BLOCKED: Results directory already exists: {NEW_RESULTS_DIR}; "
                "stopping without modification or cleanup"
            )

    def record_event(self, event_name: str, **fields):
        if not self.results_acquired:
            return
        entry = {
            "utc": utc_now_iso(),
            "epoch_s": time.time(),
            "mono_ms": int(time.clock_gettime(time.CLOCK_MONOTONIC) * 1000),
            "event": event_name,
            **fields,
        }
        events_path = os.path.join(NEW_RESULTS_DIR, "events.jsonl")
        with open(events_path, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry) + "\n")
            f.flush()

    def append_capture_log(self, msg: str):
        if not self.results_acquired:
            return
        with open(CAPTURE_STDERR_LOG, "a", encoding="utf-8") as f:
            f.write(f"[{utc_now_iso()}] {msg}\n")
            f.flush()

    def inspect_vm_binaries(self) -> dict:
        vm_info = {"supervisor": {}, "installed": {}, "workers": []}
        ps_res = subprocess.run(
            ["orb", "-m", "egress-linux-arm64", "ps", "-eo", "pid,args"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if ps_res.returncode != 0:
            raise RuntimeError(f"BLOCKED: Failed querying Linux VM processes: {ps_res.stderr.strip()}")

        for line in ps_res.stdout.splitlines():
            line_str = line.strip()
            if not line_str:
                continue
            parts = line_str.split(None, 1)
            if len(parts) < 2:
                continue
            pid, cmd = parts[0], parts[1]
            try:
                argv = shlex.split(cmd)
            except Exception:
                continue
            if not argv:
                continue
            if os.path.basename(argv[0]) != "connects-egress":
                continue
            if len(argv) < 2:
                continue
            role = argv[1]
            if role not in ("supervisor", "worker"):
                continue

            h_res = subprocess.run(
                ["orb", "-m", "egress-linux-arm64", "sudo", "sha256sum", f"/proc/{pid}/exe"],
                capture_output=True,
                text=True,
                timeout=5,
            )
            sha = h_res.stdout.split()[0] if (h_res.returncode == 0 and h_res.stdout.split()) else ""
            record = {"pid": pid, "cmd": cmd, "argv": argv, "sha256": sha}
            if role == "supervisor":
                vm_info["supervisor"] = record
            elif role == "worker":
                vm_info["workers"].append(record)

        inst_res = subprocess.run(
            ["orb", "-m", "egress-linux-arm64", "sha256sum", "/opt/connects-egress/bin/connects-egress"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if inst_res.returncode == 0 and inst_res.stdout.split():
            vm_info["installed"] = {
                "path": "/opt/connects-egress/bin/connects-egress",
                "sha256": inst_res.stdout.split()[0],
            }
        return vm_info

    def verify_prerequisites(self):
        experiment.log("Verifying frozen prerequisites, hashes, TLS trust, ports, and VM runtime...")
        self.check_deadline("verify_prerequisites")

        if os.path.exists(PCAPNG_PATH):
            raise RuntimeError(f"BLOCKED: Capture file already exists and reuse is forbidden: {PCAPNG_PATH}")

        # 1. Verify read-only reused artifact hashes
        exp_path = os.path.join(OLD_ROOT, "experiment.py")
        pub_path = os.path.join(OLD_ROOT, "publisher.py")
        probe_path = os.path.join(OLD_ROOT, "build", "Probe")
        actual_hashes = {
            "experiment.py": experiment.file_sha256(exp_path),
            "publisher.py": experiment.file_sha256(pub_path),
            "Probe": experiment.file_sha256(probe_path),
        }
        for name, actual in actual_hashes.items():
            expected = EXPECTED_HASHES[name]
            if actual != expected:
                raise RuntimeError(f"BLOCKED: {name} SHA-256 mismatch: got {actual}, expected {expected}")

        # 2. Verify required CLI tools
        for tool in ["nginx", "lk", "orb", "security", DUMPCAP_BIN, TSHARK_BIN]:
            if not (os.path.isfile(tool) and os.access(tool, os.X_OK)) and shutil.which(tool) is None:
                raise RuntimeError(f"BLOCKED: Required tool unavailable: {tool}")

        # 3. Verify TLS certificates and macOS system trust
        cert_path = os.path.join(experiment.STAGE_CERTS_DIR, "fullchain.crt")
        key_path = os.path.join(experiment.STAGE_CERTS_DIR, "server.key")
        if not (os.path.isfile(cert_path) and os.access(cert_path, os.R_OK)):
            raise RuntimeError(f"BLOCKED: Missing or unreadable TLS certificate: {cert_path}")
        if not (os.path.isfile(key_path) and os.access(key_path, os.R_OK)):
            raise RuntimeError(f"BLOCKED: Missing or unreadable TLS private key: {key_path}")
        cert_check = subprocess.run(
            ["security", "verify-cert", "-c", cert_path],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if cert_check.returncode != 0:
            raise RuntimeError(f"BLOCKED: TLS certificate not trusted by macOS security verify-cert: {cert_check.stderr.strip()}")

        # 4. Verify owned ports are free and existing upstream services are reachable
        for host, port in [("127.0.0.1", 19101), ("127.0.0.1", 19102), ("192.168.0.136", 18445)]:
            if not experiment.check_port_free(host, port):
                raise RuntimeError(f"BLOCKED: Owned port {host}:{port} is already occupied")

        for svc_name, host, port in [
            ("LiveKit", "127.0.0.1", 17880),
            ("Egress Origin", "127.0.0.1", 18080),
            ("Egress Control API", "127.0.0.1", 18081),
        ]:
            if not check_tcp_reachable(host, port, timeout=3.0):
                raise RuntimeError(f"BLOCKED: Existing service {svc_name} unreachable at {host}:{port}")

        # 5. Read control token securely without logging it
        self.control_token = experiment.read_control_token()

        # 6. Verify authenticated GET of unique run_id returns 404
        check_req = urllib.request.Request(
            f"{experiment.CONTROL_BASE_URL}/{self.run_id}",
            headers={"Authorization": f"Bearer {self.control_token}"},
        )
        try:
            with urllib.request.urlopen(check_req, timeout=5) as resp:
                raise RuntimeError(f"BLOCKED: Unique run {self.run_id} unexpectedly returned status {resp.status}")
        except urllib.error.HTTPError as he:
            if he.code != 404:
                raise RuntimeError(f"BLOCKED: Control API GET for fresh run returned HTTP {he.code}, expected 404")

        # 7. Verify Linux VM installed and running supervisor hashes match expected runtime hash
        vm_info = self.inspect_vm_binaries()
        sup_sha = vm_info.get("supervisor", {}).get("sha256", "")
        inst_sha = vm_info.get("installed", {}).get("sha256", "")
        if sup_sha != EXPECTED_HASHES["egress_runtime"]:
            raise RuntimeError(
                f"BLOCKED: Running supervisor hash {sup_sha!r} != expected {EXPECTED_HASHES['egress_runtime']}"
            )
        if inst_sha != EXPECTED_HASHES["egress_runtime"]:
            raise RuntimeError(
                f"BLOCKED: Installed binary hash {inst_sha!r} != expected {EXPECTED_HASHES['egress_runtime']}"
            )

        sw_vers = subprocess.check_output(["sw_vers"], text=True, timeout=5).strip()
        sdk_vers = subprocess.check_output(["xcrun", "--show-sdk-version"], text=True, timeout=5).strip()
        git_egress = subprocess.check_output(
            ["git", "-C", "/Users/foxy/connects-egress", "status", "-s"], text=True, timeout=5
        ).strip()

        # Collect nested app metadata read-only if present without inventing a root repo
        nested_app_repo = "/Users/foxy/connects_app/connectsapp_app"
        git_app = ""
        if os.path.isdir(os.path.join(nested_app_repo, ".git")):
            git_app = subprocess.check_output(
                ["git", "-C", nested_app_repo, "status", "-s"], text=True, timeout=5
            ).strip()

        provenance = {
            "verified_at_utc": utc_now_iso(),
            "nonce": self.nonce,
            "run_id": self.run_id,
            "room_id": self.room_id,
            "host_identity": self.host_identity,
            "os_version": sw_vers,
            "sdk_version": sdk_vers,
            "reused_hashes_sha256": actual_hashes,
            "new_harness_hashes_sha256": {
                "run.py": experiment.file_sha256(os.path.join(NEW_ROOT, "run.py")),
                "analyze.py": experiment.file_sha256(os.path.join(NEW_ROOT, "analyze.py")),
                "test_analyze.py": experiment.file_sha256(os.path.join(NEW_ROOT, "test_analyze.py")),
                os.path.basename(NEW_NGINX_CONF): experiment.file_sha256(NEW_NGINX_CONF),
            },
            "expected_egress_runtime_sha256": EXPECTED_HASHES["egress_runtime"],
            "vm_binaries_preflight": vm_info,
            "git_status_egress": git_egress,
            "git_status_app_nested": git_app,
        }
        with open(os.path.join(NEW_RESULTS_DIR, "provenance.json"), "w", encoding="utf-8") as f:
            json.dump(provenance, f, indent=2)

        self.record_event("preflight_verified", run_id=self.run_id, room_id=self.room_id)
        experiment.log("Preflight and provenance verification passed.")

    def start_h2_nginx(self):
        """
        Starts owned H2 Nginx using frozen configuration on 192.168.0.136:18445.
        Overrides experiment.py:start_h2_nginx to prevent configuration regeneration.
        Never invokes generate_h2_nginx_conf or modifies NEW_NGINX_CONF.
        Retains process/PID immediately and checks cancellation and early process exit
        while polling the five-second bind-readiness bound.
        """
        experiment.log("Starting owned H2 Nginx using frozen configuration on 192.168.0.136:18445...")
        self.check_deadline("start_h2_nginx")

        cmd = ["nginx", "-c", NEW_NGINX_CONF]
        self.nginx_proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.nginx_pid = self.nginx_proc.pid

        t0 = time.monotonic()
        bound = False
        while time.monotonic() - t0 < 5.0:
            self.check_cancellation()
            if self.nginx_proc.poll() is not None:
                _, err_bytes = self.nginx_proc.communicate()
                err_msg = err_bytes.decode("utf-8", errors="replace").strip()
                raise RuntimeError(
                    f"Owned Nginx exited prematurely with code {self.nginx_proc.returncode}: {err_msg}"
                )

            if not experiment.check_port_free("192.168.0.136", 18445):
                bound = True
                break
            time.sleep(0.1)

        if not bound:
            raise RuntimeError("Owned Nginx failed to bind 192.168.0.136:18445 within 5s")

        experiment.log(f"Owned H2 Nginx active with PID {self.nginx_pid}")

    def verify_h2_tls_preflight(self):
        """
        Immediately after owned Nginx startup, before publishing media, perform a five-second
        HTTPS check against https://192.168.0.136:18445/__vg_tls_preflight__.
        The expected HTTP 404 counts as successful TLS verification.
        Other outcomes fail immediately with the actual error.
        """
        experiment.log("Performing 5-second HTTPS check against H2 TLS preflight endpoint...")
        self.check_deadline("verify_h2_tls_preflight")
        url = "https://192.168.0.136:18445/__vg_tls_preflight__"
        ssl_ctx = create_lab_ssl_context()
        req = urllib.request.Request(
            url,
            headers={"User-Agent": f"VGCanary/1.0 (tls-preflight; nonce={self.nonce})"},
        )
        try:
            with urllib.request.urlopen(req, timeout=5.0, context=ssl_ctx) as resp:
                status = resp.status
                if status == 404:
                    self.record_event("tls_preflight_verified", status=404)
                    experiment.log("H2 TLS preflight check verified (HTTP 404 as expected).")
                    return
                raise RuntimeError(f"TLS preflight failed: expected HTTP 404, got status {status}")
        except urllib.error.HTTPError as he:
            if he.code == 404:
                self.record_event("tls_preflight_verified", status=404)
                experiment.log("H2 TLS preflight check verified (HTTP 404 as expected).")
                return
            raise RuntimeError(f"TLS preflight failed with HTTP error: {he.code} {he.reason}") from he
        except Exception as e:
            raise RuntimeError(f"TLS preflight check failed: {e}") from e

    def start_egress_and_verify_worker(self):
        experiment.log(f"Verifying 404 before sole POST for run_id={self.run_id}...")
        self.check_deadline("start_egress")

        check_req = urllib.request.Request(
            f"{experiment.CONTROL_BASE_URL}/{self.run_id}",
            headers={"Authorization": f"Bearer {self.control_token}"},
        )
        try:
            with urllib.request.urlopen(check_req, timeout=5) as resp:
                raise RuntimeError(f"Run {self.run_id} already exists (status={resp.status}) before POST")
        except urllib.error.HTTPError as he:
            if he.code != 404:
                raise RuntimeError(f"Expected 404 before POST, got HTTP {he.code}")

        self.post_attempted = True
        payload = {
            "run_id": self.run_id,
            "room_id": self.room_id,
            "livekit_room": self.room_id,
            "host_identity": self.host_identity,
            "livekit_url": experiment.LIVEKIT_URL,
        }
        post_req = urllib.request.Request(
            experiment.CONTROL_BASE_URL,
            data=json.dumps(payload).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {self.control_token}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(post_req, timeout=10) as resp:
                resp_body = json.loads(resp.read().decode("utf-8"))
                self.run_created = True
                with open(os.path.join(NEW_RESULTS_DIR, "run_create_response.json"), "w", encoding="utf-8") as f:
                    json.dump(resp_body, f, indent=2)
                self.record_event("egress_run_post_succeeded", http_status=resp.status)
        except Exception as post_err:
            experiment.log(f"Uncertain POST outcome ({post_err}); reconciling with GET (no repeat POST)...")
            self.record_event("egress_run_post_uncertain", error=str(post_err))
            try:
                with urllib.request.urlopen(check_req, timeout=5) as gresp:
                    if gresp.status == 200:
                        gbody = json.loads(gresp.read().decode("utf-8"))
                        self.run_created = True
                        with open(os.path.join(NEW_RESULTS_DIR, "run_create_response.json"), "w", encoding="utf-8") as f:
                            json.dump(gbody, f, indent=2)
                        self.record_event("egress_run_reconciled_via_get", http_status=gresp.status)
            except Exception:
                pass
            if not self.run_created:
                raise RuntimeError(f"Sole POST failed and GET reconciliation did not find run {self.run_id}") from post_err

        experiment.log("Polling run state=running and H2 playlist readiness (max 60s)...")
        h2_master_url = f"https://192.168.0.136:18445/live/{self.room_id}/master.m3u8"
        ssl_ctx = create_lab_ssl_context()
        t0 = time.monotonic()
        running_ready = False
        while time.monotonic() - t0 < 60.0:
            self.check_deadline("poll_egress_running")
            try:
                with urllib.request.urlopen(check_req, timeout=5) as s_resp:
                    st_data = json.loads(s_resp.read().decode("utf-8"))
                    if st_data.get("state") == "running":
                        p_req = urllib.request.Request(
                            h2_master_url,
                            headers={"User-Agent": f"VGCanary/1.0 (stage-readiness; nonce={self.nonce})"},
                        )
                        with urllib.request.urlopen(p_req, timeout=3, context=ssl_ctx) as p_resp:
                            body = p_resp.read().decode("utf-8", errors="replace")
                            if p_resp.status == 200 and "#EXTM3U" in body:
                                running_ready = True
                                break
            except Exception:
                pass
            time.sleep(1.0)

        if not running_ready:
            raise RuntimeError("Timed out waiting for Egress run state=running and H2 master playlist")

        # Record and verify the new worker binary hash
        vm_after = self.inspect_vm_binaries()
        target_arg = f"--run={self.run_id}"
        matched_workers = [
            w for w in vm_after.get("workers", [])
            if target_arg in w.get("argv", [])
        ]
        if len(matched_workers) != 1:
            raise RuntimeError(
                f"Expected exactly 1 worker process for {self.run_id}, found {len(matched_workers)}: {matched_workers}"
            )
        worker_rec = matched_workers[0]
        if worker_rec.get("sha256") != EXPECTED_HASHES["egress_runtime"]:
            raise RuntimeError(
                f"Worker binary hash mismatch: got {worker_rec.get('sha256')}, expected {EXPECTED_HASHES['egress_runtime']}"
            )

        worker_info = {
            "verified_at_utc": utc_now_iso(),
            "run_id": self.run_id,
            "room_id": self.room_id,
            "worker": worker_rec,
            "expected_sha256": EXPECTED_HASHES["egress_runtime"],
            "match": True,
        }
        with open(os.path.join(NEW_RESULTS_DIR, "worker_info.json"), "w", encoding="utf-8") as f:
            json.dump(worker_info, f, indent=2)

        prov_path = os.path.join(NEW_RESULTS_DIR, "provenance.json")
        if os.path.exists(prov_path):
            with open(prov_path, "r", encoding="utf-8") as f:
                prov_data = json.load(f)
            prov_data["worker_info"] = worker_info
            with open(prov_path, "w", encoding="utf-8") as f:
                json.dump(prov_data, f, indent=2)

        self.record_event("worker_verified", worker_pid=worker_rec["pid"], worker_sha256=worker_rec["sha256"])
        experiment.log(f"Worker PID {worker_rec['pid']} verified with SHA-256 {worker_rec['sha256']}")

    def wait_for_capture_and_verify_canary(self):
        """
        Prints the operator command and uses real TShark + PDML parsing to verify
        the complete matching canary request/200 response in upstream.pcapng.
        """
        if os.path.exists(PCAPNG_PATH):
            raise RuntimeError(f"BLOCKED: Capture file {PCAPNG_PATH} already exists before operator start")

        prompt_banner = (
            "\n======================================================================\n"
            "STAGE READY. Run this exact capture command in a separate terminal:\n\n"
            f"{OPERATOR_DUMPCAP_CMD}\n"
            "======================================================================\n"
        )
        sys.stdout.write(prompt_banner)
        sys.stdout.flush()
        experiment.log("Waiting at most 600s for operator capture pipeline start and real TShark canary verification...")
        self.record_event("operator_capture_prompted", command=OPERATOR_DUMPCAP_CMD)
        self.append_capture_log(f"Prompted operator for capture:\n{OPERATOR_DUMPCAP_CMD}")

        ssl_ctx = create_lab_ssl_context()
        canary_url = f"https://192.168.0.136:18445/live/{self.room_id}/master.m3u8?vg_canary={self.nonce}"
        canary_ua = f"VGCanary/1.0 (nonce={self.nonce}; exclude-from-avplayer)"

        t0 = time.monotonic()
        canary_verified = False
        last_canary_attempt = 0.0
        capture_perms_recorded = False

        while time.monotonic() - t0 < 600.0:
            self.check_deadline("wait_for_capture")
            if sys.stdin and sys.stdin.isatty():
                rlist, _, _ = select.select([sys.stdin], [], [], 0.25)
                if rlist:
                    _ = sys.stdin.readline()
            else:
                time.sleep(0.25)

            pids = get_dumpcap_pids()
            if not pids or not os.path.exists(PCAPNG_PATH) or os.path.getsize(PCAPNG_PATH) == 0:
                continue

            # Record actual file uid/gid/mode and readability via existing events.jsonl before first canary attempt
            if not capture_perms_recorded:
                st = os.stat(PCAPNG_PATH)
                readable = os.access(PCAPNG_PATH, os.R_OK)
                self.record_event(
                    "capture_file_permissions",
                    uid=st.st_uid,
                    gid=st.st_gid,
                    mode=oct(st.st_mode),
                    readable=readable,
                    path=PCAPNG_PATH,
                )
                capture_perms_recorded = True
                if not readable:
                    raise RuntimeError(
                        f"BLOCKED: Capture file permission error: {PCAPNG_PATH} is unreadable "
                        f"(uid={st.st_uid}, gid={st.st_gid}, mode={oct(st.st_mode)}). "
                        "Capture permission denied; non-root user cannot read dumpcap output."
                    )

            now_mono = time.monotonic()
            if (now_mono - last_canary_attempt) >= 1.5:
                last_canary_attempt = now_mono
                canary_sent_epoch = time.time()
                try:
                    req = urllib.request.Request(canary_url, headers={"User-Agent": canary_ua})
                    with urllib.request.urlopen(req, timeout=3, context=ssl_ctx) as resp:
                        _ = resp.read()
                except Exception as ce:
                    self.record_event("canary_http_attempt_error", error=str(ce))
                    continue

                time.sleep(0.5)  # Allow dumpcap write

                if not os.access(PCAPNG_PATH, os.R_OK):
                    st = os.stat(PCAPNG_PATH)
                    raise RuntimeError(
                        f"BLOCKED: Capture file permission error: {PCAPNG_PATH} is unreadable "
                        f"(uid={st.st_uid}, gid={st.st_gid}, mode={oct(st.st_mode)})"
                    )

                tshark_cmd = [
                    TSHARK_BIN,
                    "-2",
                    "-r", PCAPNG_PATH,
                    "-d", "tcp.port==18080,http",
                    "-o", "tcp.desegment_tcp_streams:TRUE",
                    "-o", "tcp.reassemble_out_of_order:TRUE",
                    "-o", "http.desegment_headers:TRUE",
                    "-o", "http.desegment_body:TRUE",
                    "-o", "http.dechunk_body:TRUE",
                    "-T", "pdml",
                ]
                t_res = subprocess.run(tshark_cmd, capture_output=True, text=True, timeout=10)
                if t_res.returncode != 0:
                    err_msg = t_res.stderr.strip()
                    # Incomplete capture tails during write mean retry, not configuration failure
                    if "cut short" in err_msg.lower() or "less than expected" in err_msg.lower():
                        self.record_event("canary_live_tail_retry", error=err_msg)
                        continue
                    raise RuntimeError(f"TShark error during canary verification: {err_msg}")

                try:
                    pdml_data = analyze.parse_pdml_stream(t_res.stdout)
                except Exception as pe:
                    self.record_event("canary_live_parse_retry", error=str(pe))
                    continue

                for pair in pdml_data.get("pairs", []):
                    uri = pair.get("uri", "")
                    ua = pair.get("user_agent", "")
                    query = pair.get("query", {})
                    path = pair.get("path", "")
                    req_t = pair.get("request_time_epoch", 0.0)

                    path_match = (path == f"/live/{self.room_id}/master.m3u8")
                    query_match = (query.get("vg_canary") == [str(self.nonce)])
                    ua_match = (ua == canary_ua)
                    status_match = (pair.get("status_code") == 200)
                    complete_match = pair.get("complete", False)
                    time_match = (req_t >= canary_sent_epoch - 2.0)
                    body_text = pair.get("body_text") or ""
                    body_match = body_text.startswith("#EXTM3U")

                    if path_match and query_match and ua_match and status_match and complete_match and time_match and body_match:
                        canary_verified = True
                        self.record_event(
                            "canary_verified",
                            dumpcap_pids=pids,
                            capture_pipeline_pids=pids,
                            canary_url=canary_url,
                            canary_user_agent=canary_ua,
                            request_frame=pair["request_frame"],
                            response_frame=pair["response_frame"],
                            pcap_bytes=os.path.getsize(PCAPNG_PATH),
                        )
                        self.append_capture_log(
                            f"Canary verified via real TShark PDML: frames {pair['request_frame']}->{pair['response_frame']}"
                        )
                        experiment.log(
                            f"Operator capture pipeline active (PIDs {pids}) and canary request/200 response verified via TShark."
                        )
                        break

                if canary_verified:
                    break

        if not canary_verified:
            raise RuntimeError("BLOCKED: Timed out (600s) waiting for complete matching canary request/200 response in capture")

    def run_h2_trials(self):
        probe_bin = os.path.join(OLD_ROOT, "build", "Probe")
        url = f"https://192.168.0.136:18445/live/{self.room_id}/master.m3u8"

        for idx in range(1, 13):
            self.check_deadline(f"trial_{idx:02d}")
            trial_id = f"trial_{idx:02d}"
            trial_dir = os.path.join(NEW_RESULTS_DIR, trial_id)
            os.makedirs(trial_dir, exist_ok=True)

            if not is_capture_active():
                raise RuntimeError(f"Capture became inactive prior to {trial_id} delay")

            pre_delay_s = (idx * 0.073) % 0.334
            time.sleep(pre_delay_s)

            capture_before = is_capture_active()
            if not capture_before:
                raise RuntimeError(f"Capture became inactive immediately before {trial_id} launch")

            pcap_before = os.path.getsize(PCAPNG_PATH) if os.path.exists(PCAPNG_PATH) else 0
            offset_before = (
                os.path.getsize(experiment.H2_ACCESS_LOG)
                if os.path.exists(experiment.H2_ACCESS_LOG)
                else 0
            )

            probe_jsonl = os.path.join(trial_dir, "probe.jsonl")
            probe_stderr = os.path.join(trial_dir, "probe.stderr.log")
            access_slice_path = os.path.join(trial_dir, "access.log")

            cmd = [
                probe_bin,
                "--url", url,
                "--nonce", str(self.nonce),
                "--output", probe_jsonl,
                "--duration", "15",
            ]

            launch_utc = utc_now_iso()
            launch_epoch_s = time.time()
            launch_mono_ms = int(time.clock_gettime(time.CLOCK_MONOTONIC) * 1000)

            experiment.log(f"Launching {trial_id}/12 (pre_delay={pre_delay_s:.3f}s, launch_utc={launch_utc})...")
            self.record_event(
                "trial_started",
                trial_index=idx,
                trial_id=trial_id,
                pre_delay_target_s=round(pre_delay_s, 6),
                launch_utc=launch_utc,
                launch_epoch_s=launch_epoch_s,
                launch_mono_ms=launch_mono_ms,
                pcap_size_before=pcap_before,
            )

            with open(probe_stderr, "w", encoding="utf-8") as err_f:
                proc = subprocess.Popen(cmd, stderr=err_f)
                self.probe_proc = proc
                timed_out = False
                ret = None
                t_probe_start = time.monotonic()
                probe_timeout_s = 50.0

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
                    # Defect 2: never clear probe_proc unless wait confirms reaping
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
                        # Failed terminate/kill/wait retains ownership so cleanup can retry boundedly
                        self.record_event("probe_reap_failed", trial_id=trial_id, pid=proc.pid)
                        experiment.log(
                            f"ERROR: Probe PID {proc.pid} reaping unconfirmed in {trial_id}; aborting trials and retaining ownership for cleanup retry."
                        )
                        raise RuntimeError(
                            f"Probe PID {proc.pid} unconfirmed reaping after bounded attempts in {trial_id}; aborting trials"
                        )

            end_utc = utc_now_iso()
            end_epoch_s = time.time()
            end_mono_ms = int(time.clock_gettime(time.CLOCK_MONOTONIC) * 1000)
            capture_after = is_capture_active()
            pcap_after = os.path.getsize(PCAPNG_PATH) if os.path.exists(PCAPNG_PATH) else 0

            time.sleep(0.5)  # Allow Nginx access.log flush
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
                "pre_delay_target_s": round(pre_delay_s, 6),
                "launch_utc": launch_utc,
                "launch_epoch_s": launch_epoch_s,
                "launch_mono_ms": launch_mono_ms,
                "end_utc": end_utc,
                "end_epoch_s": end_epoch_s,
                "end_mono_ms": end_mono_ms,
                "exit_code": ret,
                "timed_out": timed_out,
                "capture_active_before": capture_before,
                "capture_active_after": capture_after,
                "pcap_size_before": pcap_before,
                "pcap_size_after": pcap_after,
            }
            self.trials_meta.append(trial_meta)
            self.record_event("trial_completed", **trial_meta)
            experiment.log(
                f"Completed {trial_id}/12: exit={ret}, capture_after={capture_after}, pcap_bytes={pcap_after}"
            )

            if not capture_after:
                raise RuntimeError(f"Capture terminated prematurely during {trial_id}")

    def cleanup(self):
        """
        Guaranteed idempotent, bounded and signal-safe cleanup:
        Attempts every owned resource even if an earlier step fails.
        Does not touch results directory if acquisition was not completed.
        """
        with self._cleanup_lock:
            if self.cleanup_completed:
                return
            if not self.results_acquired:
                return
            self.cleanup_in_progress = True
            self._cleaned_up = True
            try:
                clog = []
                cleanup_errors = []

                def stop_proc(p, name):
                    if p and p.poll() is None:
                        try:
                            p.terminate()
                        except OSError:
                            pass
                        try:
                            p.wait(timeout=2)
                        except (subprocess.TimeoutExpired, OSError):
                            try:
                                p.kill()
                                p.wait(timeout=2)
                            except OSError:
                                pass
                        if p.poll() is None:
                            raise RuntimeError(f"{name} PID {p.pid} failed to terminate / unconfirmed reaping")
                        clog.append(f"Stopped {name} PID {p.pid}")

                # 1. Stop Probe
                try:
                    stop_proc(self.probe_proc, "Probe")
                    if self.probe_proc and self.probe_proc.poll() is not None:
                        self.probe_proc = None
                except Exception as e:
                    cleanup_errors.append(f"Probe cleanup: {e}")

                # 2. Stop LiveKit
                try:
                    stop_proc(self.lk_proc, "LiveKit")
                except Exception as e:
                    cleanup_errors.append(f"LiveKit cleanup: {e}")

                # 3. Stop Publisher
                try:
                    stop_proc(self.publisher_proc, "Publisher")
                except Exception as e:
                    cleanup_errors.append(f"Publisher cleanup: {e}")

                # 4. Stop Nginx
                try:
                    stop_proc(self.nginx_proc, "Nginx")
                except Exception as e:
                    cleanup_errors.append(f"Nginx cleanup: {e}")

                # 5. Delete and verify terminal state of uniquely owned Egress run
                if self.post_attempted and self.control_token:
                    terminal_verified = False
                    final_state = None
                    t0 = time.monotonic()
                    while time.monotonic() - t0 < 15.0:
                        try:
                            req = urllib.request.Request(
                                f"{experiment.CONTROL_BASE_URL}/{self.run_id}",
                                headers={"Authorization": f"Bearer {self.control_token}"},
                            )
                            with urllib.request.urlopen(req, timeout=3) as resp:
                                st = json.loads(resp.read().decode("utf-8"))
                                final_state = st.get("state")
                                if final_state in ("stopped", "ended", "failed"):
                                    terminal_verified = True
                                    clog.append(f"Verified Egress run {self.run_id} terminal state={final_state}")
                                    break
                                del_req = urllib.request.Request(
                                    f"{experiment.CONTROL_BASE_URL}/{self.run_id}",
                                    headers={"Authorization": f"Bearer {self.control_token}"},
                                    method="DELETE",
                                )
                                with urllib.request.urlopen(del_req, timeout=3):
                                    pass
                        except urllib.error.HTTPError as he:
                            if he.code == 404:
                                terminal_verified = True
                                final_state = "not_found_404"
                                clog.append(f"Verified Egress run {self.run_id} absent (404)")
                                break
                        except Exception:
                            pass
                        time.sleep(0.5)

                    if not terminal_verified:
                        cleanup_errors.append(f"Egress run {self.run_id} termination unverified (last={final_state})")

                # 6. Verify ports released
                ports_released = True
                for host, port in [("127.0.0.1", 19101), ("127.0.0.1", 19102), ("192.168.0.136", 18445)]:
                    if not experiment.check_port_free(host, port):
                        ports_released = False
                        clog.append(f"Port {host}:{port} STILL OCCUPIED")
                if not ports_released:
                    cleanup_errors.append("One or more owned ports failed to release")

                # 7. Check operator capture pipeline process (never kill root/operator pipeline)
                pids = get_dumpcap_pids()
                if pids:
                    msg = (
                        f"Operator capture pipeline PID(s) {pids} still running (300s autostop configured); "
                        "please press Ctrl-C in the capture terminal if cancelling early."
                    )
                    clog.append(msg)
                    sys.stderr.write(f"[cleanup] {msg}\n")
                    sys.stderr.flush()
                else:
                    clog.append("Operator capture pipeline is not running.")

                if cleanup_errors:
                    self.cleanup_success = False
                    clog.extend([f"CLEANUP ERROR: {err}" for err in cleanup_errors])

                try:
                    with open(os.path.join(NEW_RESULTS_DIR, "cleanup.log"), "a", encoding="utf-8") as f:
                        f.write("\n".join(clog) + "\n")
                except Exception:
                    pass
                self.record_event("cleanup_completed", notes=clog, errors=cleanup_errors, success=self.cleanup_success)
            finally:
                self.cleanup_in_progress = False
                self.cleanup_completed = True

    def wait_for_capture_close(self, max_wait_s: float = 310.0):
        pids = get_dumpcap_pids()
        if not pids:
            self.append_capture_log("Capture process already exited cleanly.")
            return
        msg = (
            f"\nAll trials complete. Operator capture pipeline PID(s) {pids} still active.\n"
            "Press Ctrl-C in the capture terminal now (or wait for its 300s autostop) to close upstream.pcapng...\n"
        )
        sys.stdout.write(msg)
        sys.stdout.flush()
        self.append_capture_log(msg.strip())
        self.record_event("waiting_for_capture_close", dumpcap_pids=pids, capture_pipeline_pids=pids)

        t0 = time.monotonic()
        while time.monotonic() - t0 < max_wait_s:
            self.check_cancellation()
            if not is_capture_active():
                self.append_capture_log("Operator capture process exited.")
                self.record_event("capture_closed")
                return
            time.sleep(0.25)
        raise RuntimeError("Timed out waiting for operator dumpcap process to close upstream.pcapng")

    def execute_experiment(self):
        summary = None
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
            self.wait_for_capture_and_verify_canary()
            self.check_cancellation()
            self.run_h2_trials()
            self.check_cancellation()
            self.wait_for_capture_close()
            self.check_cancellation()
            experiment.log("Running post-capture TShark PDML extraction and trial correlation...")
            summary = analyze.run_analysis(
                results_dir=NEW_RESULTS_DIR,
                room_id=self.room_id,
                trials_meta=self.trials_meta,
                run_id=self.run_id,
            )
            self.record_event("analysis_completed", healthy_complete=summary.get("healthy_complete_success"))
            experiment.log("Analysis completed.")
        except HarnessCancelledError as ce:
            cancelled = True
            experiment.log(f"Experiment cancelled: {ce}")
        finally:
            self.cleanup()

        # Cancellation always exits nonzero, including cancellation during final cleanup
        if cancelled or self.cancelled_signal is not None:
            experiment.log("Exiting nonzero due to cancellation.")
            sys.exit(1)

        if not self.cleanup_success:
            experiment.log("Cleanup reported unverified resources or occupied ports.")
            sys.exit(1)

        if summary is None or not summary.get("healthy_complete_success"):
            experiment.log(
                f"Experiment did not meet healthy complete success contract: {summary.get('invalidated_trials_count', 'all')} invalidated."
            )
            sys.exit(1)

        experiment.log("Full experiment and analysis completed with verified success.")


def main():
    parser = argparse.ArgumentParser(description="Frozen HTTP/2-only startup playlist & decode age harness.")
    parser.add_argument("--run", action="store_true", help="Execute the full HTTP/2 startup capture experiment")
    parser.add_argument("--nonce", type=int, default=None, help="Explicit uint32 session nonce")
    args = parser.parse_args()

    if not args.run:
        parser.print_help()
        sys.exit(1)

    nonce = args.nonce if args.nonce is not None else (int(time.time()) & 0xFFFFFFFF)
    harness = H2CaptureHarness(nonce=nonce)

    def handle_signal(sig, _frame):
        # Freeze: handler only records the first cancellation signal.
        # Never clean up, log, acquire locks, or exit inside it.
        if harness.cancelled_signal is None:
            harness.cancelled_signal = sig

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    harness.execute_experiment()


if __name__ == "__main__":
    main()
