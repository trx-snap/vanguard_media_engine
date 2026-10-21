#!/usr/bin/env python3
"""
experiment.py - Automated HTTP/2 vs HTTP/3 startup and decode latency harness.
Owns subprocess lifecycle, control API orchestration, protocol correlation, and analysis.
"""

import argparse, ast, hashlib, json, math, os, signal, socket, subprocess, sys, time
import urllib.request, urllib.error

ROOT = "/private/tmp/vg-startup-auto-20261020-1338"
BUILD_DIR = os.path.join(ROOT, "build")
RESULTS_DIR = os.path.join(ROOT, "results")
NGINX_CONF = os.path.join(ROOT, "nginx.conf")
H2_PID_FILE = os.path.join(RESULTS_DIR, "nginx.pid")
H2_ACCESS_LOG = os.path.join(RESULTS_DIR, "nginx_access.log")
H2_ERROR_LOG = os.path.join(RESULTS_DIR, "nginx_error.log")
STAGE_DIR = "/tmp/connects-egress-h3-stage-20261018_192200"
H3_ACCESS_LOG = os.path.join(STAGE_DIR, "logs", "access.log")
STAGE_CERTS_DIR = os.path.join(STAGE_DIR, "certs")
STAGE_MANAGER_PATH = "/private/tmp/connects-egress-iphone-20261018_201716/stage_manager.py"
CONTROL_BASE_URL = "http://127.0.0.1:18081/control/v1/runs"
LIVEKIT_URL = "http://127.0.0.1:17880"
TOTAL_DEADLINE_SECS = 1200


def log(msg: str):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    sys.stderr.write(f"[{ts}] [experiment] {msg}\n")
    sys.stderr.flush()


def file_sha256(path: str) -> str:
    if not os.path.exists(path): return ""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(65536): h.update(chunk)
    return h.hexdigest()


def read_control_token() -> str:
    if not os.path.exists(STAGE_MANAGER_PATH): raise RuntimeError(f"Missing {STAGE_MANAGER_PATH}")
    with open(STAGE_MANAGER_PATH, "r") as f: tree = ast.parse(f.read())
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name) and t.id == "CONTROL_TOKEN":
                    tok = ast.literal_eval(node.value)
                    if isinstance(tok, str) and tok: return tok
    raise RuntimeError("CONTROL_TOKEN assignment not found in stage_manager.py")


def check_port_free(host: str, port: int) -> bool:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind((host, port)); return True
    except OSError: return False
    finally: s.close()


def generate_h2_nginx_conf():
    content = f"""daemon off;
worker_processes 1;
pid {H2_PID_FILE};
error_log {H2_ERROR_LOG} debug;
events {{ worker_connections 256; }}
http {{
    include /opt/homebrew/etc/nginx/mime.types;
    default_type application/octet-stream;
    log_format h2_audit '$time_iso8601 client=$remote_addr protocol=$server_protocol http3=$http3 ssl_proto=$ssl_protocol ssl_cipher=$ssl_cipher method=$request_method uri="$request_uri" status=$status bytes=$body_bytes_sent request_time=$request_time ua="$http_user_agent"';
    access_log {H2_ACCESS_LOG} h2_audit;
    server {{
        listen 192.168.0.136:18445 ssl;
        http2 on;
        ssl_certificate {STAGE_CERTS_DIR}/fullchain.crt;
        ssl_certificate_key {STAGE_CERTS_DIR}/server.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers on;
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
        location /media/ {{
            proxy_pass http://127.0.0.1:18080/media/;
            proxy_http_version 1.1;
            proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto $scheme;
            proxy_buffering off; proxy_cache off; proxy_no_cache 1; proxy_cache_bypass 1;
            proxy_read_timeout 300s; proxy_send_timeout 300s; proxy_connect_timeout 5s;
        }}
        location /live/ {{
            proxy_pass http://127.0.0.1:18080/live/;
            proxy_http_version 1.1;
            proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto $scheme;
            proxy_buffering off; proxy_cache off; proxy_no_cache 1; proxy_cache_bypass 1;
            proxy_read_timeout 300s; proxy_send_timeout 300s; proxy_connect_timeout 5s;
        }}
    }}
}}
"""
    with open(NGINX_CONF, "w") as f: f.write(content)
    log(f"Generated owned H2 Nginx config (daemon off) at {NGINX_CONF}")


class ExperimentHarness:
    def __init__(self, nonce: int):
        self.nonce = nonce
        self.run_id = f"vg_auto_{nonce}"
        self.room_id = self.run_id
        self.host_identity = self.run_id
        self.control_token = ""
        self.start_mono = time.monotonic()

        self.publisher_proc = None
        self.lk_proc = None
        self.probe_proc = None
        self.nginx_proc = None
        self.nginx_pid = None
        self.post_attempted = False
        self.run_created = False
        self.cmd_log = []

    def log_cmd(self, cmd, code, out="", err=""):
        self.cmd_log.append({"cmd": cmd, "code": code, "stdout": out[:500], "stderr": err[:500]})
        with open(os.path.join(RESULTS_DIR, "commands.json"), "w") as f:
            json.dump(self.cmd_log, f, indent=2)

    def check_deadline(self, step: str):
        if (time.monotonic() - self.start_mono) > TOTAL_DEADLINE_SECS:
            raise TimeoutError(f"Outer deadline 20min exceeded during {step}")

    def preflight(self):
        log("Running preflight checks and measuring VM hashes...")
        self.check_deadline("preflight")
        os.makedirs(BUILD_DIR, exist_ok=True)
        os.makedirs(RESULTS_DIR, exist_ok=True)
        os.makedirs(os.path.join(RESULTS_DIR, "playlists"), exist_ok=True)
        os.makedirs(os.path.join(BUILD_DIR, "ModuleCache"), exist_ok=True)

        for host, port in [("127.0.0.1", 19101), ("127.0.0.1", 19102), ("192.168.0.136", 18445)]:
            if not check_port_free(host, port):
                raise RuntimeError(f"Port {host}:{port} occupied; aborting to prevent collision")

        self.control_token = read_control_token()
        sw_vers = subprocess.check_output(["sw_vers"], text=True).strip()
        sdk_vers = subprocess.check_output(["xcrun", "--show-sdk-version"], text=True).strip()
        git_egress = subprocess.check_output(["git", "-C", "/Users/foxy/connects-egress", "status", "-s"], text=True)
        git_app = subprocess.check_output(["git", "-C", "/Users/foxy/connects_app", "status", "-s"], text=True)

        # Measure actual VM hashes via read-only orb
        vm_measured = {"supervisor": {}, "installed": {}, "workers": []}
        try:
            ps_res = subprocess.run(["orb", "-m", "egress-linux-arm64", "ps", "-eo", "pid,args"], capture_output=True, text=True, timeout=10)
            if ps_res.returncode == 0:
                for line in ps_res.stdout.splitlines():
                    if "connects-egress" in line and "grep" not in line:
                        p = line.strip().split(None, 1)
                        pid = p[0]; cmd = p[1] if len(p) > 1 else ""
                        h_res = subprocess.run(["orb", "-m", "egress-linux-arm64", "sudo", "sha256sum", f"/proc/{pid}/exe"], capture_output=True, text=True, timeout=5)
                        sha = h_res.stdout.split()[0] if h_res.returncode == 0 else ""
                        if "supervisor" in cmd: vm_measured["supervisor"] = {"pid": pid, "cmd": cmd, "sha256": sha}
                        elif "worker" in cmd: vm_measured["workers"].append({"pid": pid, "cmd": cmd, "sha256": sha})
            inst_res = subprocess.run(["orb", "-m", "egress-linux-arm64", "sha256sum", "/opt/connects-egress/bin/connects-egress"], capture_output=True, text=True, timeout=5)
            if inst_res.returncode == 0: vm_measured["installed"] = {"path": "/opt/connects-egress/bin/connects-egress", "sha256": inst_res.stdout.split()[0]}
        except Exception as e:
            vm_measured["error"] = str(e)

        meta = {
            "os_version": sw_vers, "sdk_version": sdk_vers, "nonce": self.nonce, "run_id": self.run_id,
            "sources_sha256": {
                "publisher.py": file_sha256(os.path.join(ROOT, "publisher.py")),
                "Probe.swift": file_sha256(os.path.join(ROOT, "Probe.swift")),
                "experiment.py": file_sha256(os.path.join(ROOT, "experiment.py")),
            },
            "git_status_egress": git_egress.strip(), "git_status_app": git_app.strip(),
            "actual_vm_measurements": vm_measured
        }
        with open(os.path.join(RESULTS_DIR, "preflight.json"), "w") as f: json.dump(meta, f, indent=2)
        log("Preflight metadata saved to results/preflight.json")

    def compile_probe(self):
        log("Compiling Probe.swift (bounded 90s, isolated module cache)...")
        self.check_deadline("compile_probe")
        cmd = ["xcrun", "swiftc", "-O",
               "-module-cache-path", os.path.join(BUILD_DIR, "ModuleCache"),
               "-framework", "AVFoundation", "-framework", "CoreMedia",
               "-framework", "CoreVideo", "-framework", "CoreGraphics", "-framework", "ImageIO",
               os.path.join(ROOT, "Probe.swift"), "-o", os.path.join(BUILD_DIR, "Probe")]
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
        self.log_cmd(cmd, res.returncode, res.stdout, res.stderr)
        if res.returncode != 0: raise RuntimeError(f"Probe compilation failed:\n{res.stderr}")
        log("Probe compiled successfully to build/Probe")

    def run_calibration(self):
        log("Running marker calibration...")
        self.check_deadline("calibration")
        png_path = os.path.join(BUILD_DIR, "calib.png")
        jsonl_path = os.path.join(BUILD_DIR, "calib.jsonl")

        cmd_png = [sys.executable, os.path.join(ROOT, "publisher.py"), "--nonce", str(self.nonce), "--calibration-png", png_path]
        r1 = subprocess.run(cmd_png, capture_output=True, text=True, timeout=10)
        self.log_cmd(cmd_png, r1.returncode, r1.stdout, r1.stderr)
        if r1.returncode != 0: raise RuntimeError(f"PNG generation failed: {r1.stderr}")

        cmd_cal = [os.path.join(BUILD_DIR, "Probe"), "--calibrate", png_path, "--nonce", str(self.nonce), "--output", jsonl_path]
        r2 = subprocess.run(cmd_cal, capture_output=True, text=True, timeout=10)
        self.log_cmd(cmd_cal, r2.returncode, r2.stdout, r2.stderr)
        if r2.returncode != 0: raise RuntimeError(f"Calibration rejected: {r2.stderr}")
        log(f"Calibration PASS verified: {r2.stderr.strip()}")

    def start_h2_nginx(self):
        log("Starting owned H2 Nginx as foreground Popen on 192.168.0.136:18445...")
        self.check_deadline("start_h2_nginx")
        generate_h2_nginx_conf()
        self.nginx_proc = subprocess.Popen(["nginx", "-c", NGINX_CONF], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.nginx_pid = self.nginx_proc.pid

        # Verify port binds within 5s
        t0 = time.time(); bound = False
        while time.time() - t0 < 5:
            if not check_port_free("192.168.0.136", 18445): bound = True; break
            time.sleep(0.1)
        if not bound: raise RuntimeError("Owned Nginx failed to bind 192.168.0.136:18445")
        log(f"Owned H2 Nginx active with PID {self.nginx_pid}")

    def publish_media(self):
        log("Starting media publisher and LiveKit publisher...")
        self.check_deadline("publish_media")
        pub_err_log = open(os.path.join(RESULTS_DIR, "publisher_stderr.log"), "w")
        self.publisher_proc = subprocess.Popen([sys.executable, os.path.join(ROOT, "publisher.py"), "--nonce", str(self.nonce)], stderr=pub_err_log)

        for _ in range(50):
            if not check_port_free("127.0.0.1", 19101) and not check_port_free("127.0.0.1", 19102): break
            time.sleep(0.1)
        else: raise RuntimeError("Publisher failed to bind 19101/19102")

        lk_err_log = open(os.path.join(RESULTS_DIR, "lk_stderr.log"), "w")
        lk_cmd = ["lk", "--url", LIVEKIT_URL, "--dev", "room", "join", "--identity", self.host_identity,
                  "--publish", "h264://127.0.0.1:19101", "--publish", "opus://127.0.0.1:19102", "--fps", "30", self.room_id]
        self.lk_proc = subprocess.Popen(lk_cmd, stderr=lk_err_log)

        log("Verifying participant tracks via LiveKit CLI...")
        t0 = time.time(); verified = False
        while time.time() - t0 < 15:
            res = subprocess.run(["lk", "room", "participants", "get", "--url", LIVEKIT_URL, "--dev", "--quiet",
                                  "--room", self.room_id, "--identity", self.host_identity], capture_output=True, text=True, timeout=5)
            if res.returncode == 0 and res.stdout.strip():
                try:
                    p = json.loads(res.stdout)
                    if p.get("state") == "ACTIVE":
                        tracks = p.get("tracks", [])
                        v = next((t for t in tracks if (t.get("type") or "AUDIO") == "VIDEO"), None)
                        a = next((t for t in tracks if (t.get("type") or "AUDIO") == "AUDIO"), None)
                        if v and a and not v.get("muted", False) and not a.get("muted", False):
                            verified = True; log(f"Participant ACTIVE with unmuted video+audio ({len(tracks)} tracks)"); break
                except Exception: pass
            time.sleep(0.5)
        if not verified: raise RuntimeError("Failed to verify active unmuted tracks in LiveKit")

    def start_egress_and_poll(self):
        log("Verifying unique run 404 before sole POST...")
        self.check_deadline("start_egress")
        check_req = urllib.request.Request(f"{CONTROL_BASE_URL}/{self.run_id}", headers={"Authorization": f"Bearer {self.control_token}"})
        try:
            with urllib.request.urlopen(check_req, timeout=5) as resp:
                if resp.status == 200: raise RuntimeError(f"Run {self.run_id} already exists!")
        except urllib.error.HTTPError as he:
            if he.code != 404: raise RuntimeError(f"Expected 404 before POST, got {he.code}")
        except Exception: pass

        self.post_attempted = True
        payload = {"run_id": self.run_id, "room_id": self.room_id, "livekit_room": self.room_id,
                   "host_identity": self.host_identity, "livekit_url": LIVEKIT_URL}
        req = urllib.request.Request(CONTROL_BASE_URL, data=json.dumps(payload).encode("utf-8"),
                                     headers={"Authorization": f"Bearer {self.control_token}", "Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                resp_body = json.loads(resp.read().decode("utf-8"))
                self.run_created = True
                with open(os.path.join(RESULTS_DIR, "run_create_response.json"), "w") as f: json.dump(resp_body, f, indent=2)
                log(f"POST /control/v1/runs status={resp.status}")
        except Exception as pe:
            log(f"Uncertain POST response ({pe}); verifying via GET...")
            try:
                with urllib.request.urlopen(check_req, timeout=5) as gresp:
                    if gresp.status == 200: self.run_created = True; log("Run verified active via GET")
            except Exception: pass
            if not self.run_created: raise

        log("Polling run status and playlists (max 60s)...")
        master_url = f"http://192.168.0.136:18080/live/{self.room_id}/master.m3u8"
        t0 = time.time(); running_ready = False
        while time.time() - t0 < 60:
            self.check_deadline("poll_egress")
            try:
                s_req = urllib.request.Request(f"{CONTROL_BASE_URL}/{self.run_id}", headers={"Authorization": f"Bearer {self.control_token}"})
                with urllib.request.urlopen(s_req, timeout=5) as s_resp:
                    if json.loads(s_resp.read().decode("utf-8")).get("state") == "running":
                        with urllib.request.urlopen(urllib.request.Request(master_url), timeout=3) as p_resp:
                            if p_resp.status == 200 and "#EXTM3U" in p_resp.read().decode("utf-8"):
                                running_ready = True; log("Run state=running and master playlist ready"); break
            except Exception: pass
            time.sleep(1.0)
        if not running_ready: raise RuntimeError("Timed out waiting for Egress running state with master playlist")

        # Save snapshots of master, video, audio playlists
        for p_name in ["master.m3u8", "video.m3u8", "audio.m3u8"]:
            try:
                u = f"http://192.168.0.136:18080/live/{self.room_id}/{p_name}"
                with urllib.request.urlopen(urllib.request.Request(u), timeout=3) as r:
                    with open(os.path.join(RESULTS_DIR, "playlists", p_name), "wb") as f: f.write(r.read())
            except Exception: pass

    def run_trials(self):
        """Executes 16 trials alternating AB/BA (8 pairs) with varied-phase delays."""
        sequence = [
            ("A", "H3", "https://192.168.0.136:18443", H3_ACCESS_LOG),
            ("B", "H2", "https://192.168.0.136:18445", H2_ACCESS_LOG),
            ("B", "H2", "https://192.168.0.136:18445", H2_ACCESS_LOG),
            ("A", "H3", "https://192.168.0.136:18443", H3_ACCESS_LOG),
            ("A", "H3", "https://192.168.0.136:18443", H3_ACCESS_LOG),
            ("B", "H2", "https://192.168.0.136:18445", H2_ACCESS_LOG),
            ("B", "H2", "https://192.168.0.136:18445", H2_ACCESS_LOG),
            ("A", "H3", "https://192.168.0.136:18443", H3_ACCESS_LOG),
            ("A", "H3", "https://192.168.0.136:18443", H3_ACCESS_LOG),
            ("B", "H2", "https://192.168.0.136:18445", H2_ACCESS_LOG),
            ("B", "H2", "https://192.168.0.136:18445", H2_ACCESS_LOG),
            ("A", "H3", "https://192.168.0.136:18443", H3_ACCESS_LOG),
            ("A", "H3", "https://192.168.0.136:18443", H3_ACCESS_LOG),
            ("B", "H2", "https://192.168.0.136:18445", H2_ACCESS_LOG),
            ("B", "H2", "https://192.168.0.136:18445", H2_ACCESS_LOG),
            ("A", "H3", "https://192.168.0.136:18443", H3_ACCESS_LOG),
        ]
        trials_results = []
        for idx, (label, proto, base_url, log_path) in enumerate(sequence, start=1):
            self.check_deadline(f"trial_{idx}_{proto}")
            log(f"Starting Trial {idx}/16: {proto} ({label}) at {base_url}...")
            offset_before = os.path.getsize(log_path) if os.path.exists(log_path) else 0
            url = f"{base_url}/live/{self.room_id}/master.m3u8"
            out_jsonl = os.path.join(RESULTS_DIR, f"trial_{idx}_{proto}.jsonl")
            cmd = [os.path.join(BUILD_DIR, "Probe"), "--url", url, "--nonce", str(self.nonce), "--output", out_jsonl, "--duration", "25"]

            p_start = time.time()
            probe_err_log = open(os.path.join(RESULTS_DIR, f"trial_{idx}_{proto}_stderr.log"), "w")
            self.probe_proc = subprocess.Popen(cmd, stderr=probe_err_log)
            try: ret = self.probe_proc.wait(timeout=50)
            except subprocess.TimeoutExpired:
                self.probe_proc.kill(); ret = self.probe_proc.wait(timeout=5)
            self.probe_proc = None
            p_elapsed = time.time() - p_start
            time.sleep(1.0) # Allow log flush

            offset_after = os.path.getsize(log_path) if os.path.exists(log_path) else 0
            log_slice = b""
            if os.path.exists(log_path) and offset_after > offset_before:
                with open(log_path, "rb") as f:
                    f.seek(offset_before); log_slice = f.read(offset_after - offset_before)
            slice_path = os.path.join(RESULTS_DIR, f"trial_{idx}_{proto}_access.log")
            with open(slice_path, "wb") as f: f.write(log_slice)

            master_proto, media_proto = set(), set()
            master_bytes, media_bytes = 0, 0
            master_success, media_success = 0, 0
            for line in log_slice.decode("utf-8", errors="replace").splitlines():
                if f"/live/{self.room_id}/" in line or "/media/" in line:
                    fields = dict(p.split("=", 1) for p in line.split() if "=" in p)
                    uri = fields.get("uri", "")
                    p_str = fields.get("protocol", "")
                    st = fields.get("status", "")
                    b = int(fields.get("bytes", 0))
                    if f"/live/{self.room_id}/" in uri:
                        master_proto.add(p_str); master_bytes += b
                        if st == "200": master_success += 1
                    elif "/media/" in uri:
                        media_proto.add(p_str); media_bytes += b
                        if st == "200": media_success += 1

            trials_results.append({
                "trial": idx, "pair": (idx + 1) // 2, "label": label, "protocol_target": proto,
                "exit_code": ret, "duration_seconds": p_elapsed, "output_jsonl": out_jsonl,
                "access_log_slice": slice_path,
                "master_protocols": sorted(list(master_proto)), "media_protocols": sorted(list(media_proto)),
                "master_success": master_success, "media_success": media_success,
                "master_bytes": master_bytes, "media_bytes": media_bytes,
            })
            log(f"Completed Trial {idx}: exit={ret}, master_p={sorted(list(master_proto))}, media_p={sorted(list(media_proto))}")
            if idx < 16: time.sleep(0.4 + ((idx * 0.073) % 0.3))

        return trials_results

    def analyze_results(self, trials: list):
        log("Analyzing trial results and generating summaries...")
        summaries = []
        for t in trials:
            first_frame = None; early_ages = []; steady_ages = []; failures = 0
            native_errors = []
            if os.path.exists(t["output_jsonl"]):
                with open(t["output_jsonl"], "r") as f:
                    for line in f:
                        line = line.strip()
                        if not line: continue
                        try:
                            rec = json.loads(line)
                            if rec.get("teardown"):
                                native_errors = rec.get("native_error_log_events", [])
                            elif rec.get("valid"):
                                if first_frame is None: first_frame = rec
                                dt = (rec["observation_mono_ms"] - first_frame["observation_mono_ms"]) / 1000.0
                                age = rec.get("age_ms", 0)
                                if dt <= 5.0: early_ages.append(age)
                                else: steady_ages.append(age)
                            else: failures += 1
                        except Exception: pass

            def calc_stats(arr):
                if not arr: return None, None
                s = sorted(arr); n = len(s)
                med = s[n // 2] if n % 2 != 0 else (s[n // 2 - 1] + s[n // 2]) / 2.0
                return med, s[min(int(math.ceil(0.95 * n)) - 1, n - 1)]

            early_med, early_p95 = calc_stats(early_ages)
            steady_med, steady_p95 = calc_stats(steady_ages)

            all_protos = set(t["master_protocols"] + t["media_protocols"])
            is_pure_h3 = t["protocol_target"] == "H3" and all_protos == {"HTTP/3.0"}
            is_mixed_h3 = t["protocol_target"] == "H3" and "HTTP/3.0" in all_protos and len(all_protos) > 1
            has_valid_media = t["master_success"] > 0 and t["media_success"] > 0
            has_frames = first_frame is not None

            # Measured requires successful master + media requests AND valid decoded frames
            is_measured = (t["exit_code"] == 0) and has_valid_media and has_frames

            summaries.append({
                "trial": t["trial"], "pair": t["pair"], "protocol": t["protocol_target"],
                "exit_code": t["exit_code"], "measured": is_measured,
                "master_protocols": t["master_protocols"], "media_protocols": t["media_protocols"],
                "h3_policy": "pure" if is_pure_h3 else ("mixed" if is_mixed_h3 else "unavailable"),
                "startup_elapsed_ms": first_frame.get("startup_elapsed_ms") if first_frame else None,
                "first_frame_age_ms": first_frame.get("age_ms") if first_frame else None,
                "early_age_median_ms": early_med, "early_age_p95_ms": early_p95,
                "steady_age_median_ms": steady_med, "steady_age_p95_ms": steady_p95,
                "early_count": len(early_ages), "steady_count": len(steady_ages),
                "failure_count": failures, "native_error_events": native_errors
            })

        # Paired analysis only over complete measured pairs
        paired_deltas = []
        for p in range(1, 9):
            pt = [s for s in summaries if s["pair"] == p]
            h3 = next((s for s in pt if s["protocol"] == "H3"), None)
            h2 = next((s for s in pt if s["protocol"] == "H2"), None)
            if h3 and h2 and h3["measured"] and h2["measured"]:
                if h3["startup_elapsed_ms"] is not None and h2["startup_elapsed_ms"] is not None:
                    paired_deltas.append({
                        "pair": p,
                        "h3_policy": h3["h3_policy"],
                        "delta_startup_ms": h3["startup_elapsed_ms"] - h2["startup_elapsed_ms"],
                        "delta_steady_median_ms": (h3["steady_age_median_ms"] or 0) - (h2["steady_age_median_ms"] or 0),
                    })

        with open(os.path.join(RESULTS_DIR, "summary.json"), "w") as f:
            json.dump({"nonce": self.nonce, "run_id": self.run_id, "trials": summaries, "paired_deltas": paired_deltas}, f, indent=2)

        md = [f"# HTTP/2 vs HTTP/3 Latency Experiment Summary (Run {self.run_id})", "",
              "| Trial | Proto | Master Proto | Media Proto | Policy | Startup (ms) | 1st Age (ms) | Early Med (ms) | Steady Med (ms) | Measured |",
              "|-------|-------|--------------|-------------|--------|--------------|--------------|----------------|-----------------|----------|"]
        for s in summaries:
            m_p = ",".join(s["master_protocols"]) if s["master_protocols"] else "None"
            med_p = ",".join(s["media_protocols"]) if s["media_protocols"] else "None"
            meas_str = "YES" if s["measured"] else "NO"
            md.append(f"| {s['trial']} | {s['protocol']} | {m_p} | {med_p} | {s['h3_policy']} | {s['startup_elapsed_ms']} | {s['first_frame_age_ms']} | {s['early_age_median_ms']} | {s['steady_age_median_ms']} | {meas_str} |")
        md.append("\n## Paired Deltas (H3 - H2) Complete Measured Pairs Only")
        if paired_deltas:
            for pd in paired_deltas:
                md.append(f"- Pair {pd['pair']} ({pd['h3_policy']}): Startup Delta = {pd['delta_startup_ms']:+d}ms, Steady Median Delta = {pd['delta_steady_median_ms']:+.1f}ms")
        else:
            md.append("- No complete measured pairs available for delta computation.")

        with open(os.path.join(RESULTS_DIR, "summary.md"), "w") as f: f.write("\n".join(md) + "\n")
        log("Saved results/summary.json and results/summary.md")

    def cleanup(self):
        log("Executing guaranteed idempotent cleanup...")
        clog = []

        def stop_proc(p, name):
            if p and p.poll() is None:
                p.terminate()
                try: p.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    p.kill(); p.wait(timeout=2)
                clog.append(f"Stopped {name} PID {p.pid}")

        stop_proc(self.probe_proc, "Probe")
        stop_proc(self.lk_proc, "LiveKit")
        stop_proc(self.publisher_proc, "Publisher")
        stop_proc(self.nginx_proc, "Nginx")

        if self.post_attempted and self.control_token:
            for _ in range(3):
                try:
                    req = urllib.request.Request(f"{CONTROL_BASE_URL}/{self.run_id}", headers={"Authorization": f"Bearer {self.control_token}"}, method="DELETE")
                    with urllib.request.urlopen(req, timeout=3) as resp:
                        if resp.status in (200, 204, 404): clog.append(f"Deleted run {self.run_id} status {resp.status}"); break
                except Exception: time.sleep(1.0)

        # Verify all ports released
        ports_released = True
        for host, port in [("127.0.0.1", 19101), ("127.0.0.1", 19102), ("192.168.0.136", 18445)]:
            if not check_port_free(host, port):
                ports_released = False; clog.append(f"Port {host}:{port} STILL OCCUPIED")

        try:
            with open(os.path.join(RESULTS_DIR, "cleanup.log"), "a") as f: f.write("\n".join(clog) + "\n")
        except Exception: pass
        log(f"Cleanup finished: {clog}")
        if not ports_released:
            sys.exit(1)

    def run_all(self):
        try:
            self.preflight()
            self.compile_probe()
            self.run_calibration()
            self.start_h2_nginx()
            self.publish_media()
            self.start_egress_and_poll()
            trials = self.run_trials()
            self.analyze_results(trials)
        finally:
            self.cleanup()


def main():
    parser = argparse.ArgumentParser(description="Automated HTTP/2 vs HTTP/3 experiment runner.")
    parser.add_argument("--run", action="store_true", help="Execute complete automated experiment")
    parser.add_argument("--prepare", action="store_true", help="Execute preflight checks without live run")
    parser.add_argument("--nonce", type=int, default=None, help="Explicit nonce (uint32)")
    args = parser.parse_args()

    nonce = args.nonce if args.nonce is not None else (int(time.time()) & 0xFFFFFFFF)
    harness = ExperimentHarness(nonce=nonce)

    def handle_sig(sig, frame):
        log(f"Signal {sig} caught, initiating cleanup")
        harness.cleanup()
        sys.exit(1)

    signal.signal(signal.SIGINT, handle_sig)
    signal.signal(signal.SIGTERM, handle_sig)

    if args.prepare:
        harness.preflight(); sys.exit(0)
    elif args.run:
        harness.run_all(); sys.exit(0)
    else:
        parser.print_help(); sys.exit(1)


if __name__ == "__main__":
    main()
