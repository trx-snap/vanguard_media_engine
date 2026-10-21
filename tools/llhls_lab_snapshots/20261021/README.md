# Low-Latency HLS (LL-HLS) Lab & Verification Snapshots (2026-10-21)

This directory preserves the historical lab harnesses, synthetic publishers, packet capture fixtures, outage injection scripts, and native Swift host policy test runners developed during the LL-HLS startup alignment and recovery investigations between 17 and 21 October 2026.

## 1. Source Preservation vs. Runnable Portability

- **Source Preservation**:
  All Swift source files, Python analysis scripts, NGINX configurations, and capture fixtures are preserved byte-for-byte to ensure that algorithms, state machines, timing formulas, packet parsing rules, and assertion suites remain durable in repository history.
- **Runnable Portability Limitations**:
  - **Historical Absolute Paths**: Scripts (such as `run.py`) contain historical hard-coded absolute paths pointing to temporary directories (`OLD_ROOT`, `BASE_ROOT`, `NEW_ROOT` under `/private/tmp/...`). These paths remain unchanged to preserve exact archival provenance.
  - **Inter-Test Dependencies**: Several test suites and capture harnesses cross-import modules from other historical temporary run directories.
  - **External Runtime Prerequisites**: Executing the live end-to-end harnesses requires external system dependencies not packaged in this snapshot:
    - Python 3.10+ with Cairo, PyGObject, GStreamer bindings, and packet analysis libraries (`dpkt` / `scapy`);
    - NGINX compiled with HTTP/2 and HTTP/3 / QUIC support, plus valid local TLS certificates;
    - Wireshark / TShark for packet dissections and PDML generation;
    - Connects Egress supervisor/worker stack running on Linux (or Docker container `egress-linux-arm64`) with authenticated LiveKit Control API access;
    - Native `Probe` / `policy-check` compilation environments using Apple `swiftc`.

## 2. Execution & Scope Boundaries

- **No Live Harness Execution**: No live stream generation, NGINX proxy, or end-to-end outage harness was executed during the preservation of this directory.
- **Isolation from Production Classes**: These snapshots reside strictly outside the shipping Vanguard library (`ios/Classes/` and `lib/`) under `tools/llhls_lab_snapshots/`.
- **Release Compilation Condition**: The low-latency startup alignment and recovery logic in `VGStreamingPlaybackCoordinator.swift` and `VGHLSRecovery.swift` is gated behind the `VG_HLS_STARTUP_ALIGNMENT_EXPERIMENT` compilation flag in Release builds.
- **Pending Acceptance Criteria**: Dynamic rate control (`VGHLSRateController.swift` / `VGHLSRatePolicy.swift`) remains unwired and inactive. Wide-area network (WAN) resilience, high jitter, cellular handoffs, and multi-device parity testing remain open for future verification.
