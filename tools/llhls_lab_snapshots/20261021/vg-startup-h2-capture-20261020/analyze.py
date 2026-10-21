#!/usr/bin/env python3
"""
analyze.py - TShark two-pass PDML extraction, LL-HLS playlist edge timing,
AVPlayer request/response correlation, capture health verification, and summary statistics.
"""

import sys
sys.dont_write_bytecode = True

import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
import math
import os
import re
import subprocess
from urllib.parse import urlsplit, parse_qs
import xml.etree.ElementTree as ET


TSHARK_BIN = "/opt/homebrew/bin/tshark"


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def format_utc_iso(epoch_s: float) -> str:
    dt = datetime.fromtimestamp(epoch_s, tz=timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def parse_iso8601_utc(ts_str: str) -> float:
    s = ts_str.strip()
    if not s:
        raise ValueError("empty timestamp")
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    dt = datetime.fromisoformat(s)
    if dt.tzinfo is None:
        raise ValueError("timestamp lacks timezone offset")
    return dt.timestamp()


def calc_median(values: list) -> float | None:
    if not values:
        return None
    s = sorted(values)
    n = len(s)
    if n % 2 == 1:
        return float(s[n // 2])
    return float((s[n // 2 - 1] + s[n // 2]) / 2.0)


def calc_p95(values: list) -> float | None:
    if not values:
        return None
    s = sorted(values)
    n = len(s)
    idx = min(int(math.ceil(0.95 * n)) - 1, n - 1)
    return float(s[idx])


def calc_pearson_r(xs: list, ys: list) -> float | None:
    if len(xs) != len(ys) or len(xs) < 2:
        return None
    n = len(xs)
    mx = sum(xs) / n
    my = sum(ys) / n
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    den_x = sum((x - mx) ** 2 for x in xs)
    den_y = sum((y - my) ** 2 for y in ys)
    if den_x <= 0.0 or den_y <= 0.0:
        return None
    return float(num / math.sqrt(den_x * den_y))


def extract_pdml_with_tshark(
    pcapng_path: str,
    pdml_path: str,
    stderr_log_path: str,
    timeout: int = 120,
) -> dict:
    """
    Runs TShark two-pass PDML extraction decoding tcp.port==18080 as HTTP,
    with TCP stream desegmentation, out-of-order reassembly, HTTP header/body
    desegmentation, and HTTP dechunking enabled.
    Rejects nonzero exit status.
    """
    if not os.path.exists(pcapng_path) or os.path.getsize(pcapng_path) == 0:
        raise RuntimeError(f"Capture file missing or empty: {pcapng_path}")

    cmd = [
        TSHARK_BIN,
        "-2",
        "-r", pcapng_path,
        "-d", "tcp.port==18080,http",
        "-o", "tcp.desegment_tcp_streams:TRUE",
        "-o", "tcp.reassemble_out_of_order:TRUE",
        "-o", "http.desegment_headers:TRUE",
        "-o", "http.desegment_body:TRUE",
        "-o", "http.dechunk_body:TRUE",
        "-T", "pdml",
    ]
    with open(pdml_path, "wb") as out_f, open(stderr_log_path, "ab") as err_f:
        err_f.write(f"\n[analyze] Executing: {' '.join(cmd)}\n".encode("utf-8"))
        err_f.flush()
        res = subprocess.run(cmd, stdout=out_f, stderr=err_f, timeout=timeout)

    if res.returncode != 0:
        raise RuntimeError(f"TShark extraction failed with exit code {res.returncode}")

    return {
        "command": cmd,
        "returncode": res.returncode,
        "pdml_path": pdml_path,
        "pdml_bytes": os.path.getsize(pdml_path) if os.path.exists(pdml_path) else 0,
    }


def parse_capture_stderr(stderr_text: str) -> dict:
    """
    Extracts capture drop counts and truncation warnings from dumpcap/tshark stderr.
    Represents absent drop statistics as UNKNOWN, not zero.
    """
    drops = None
    drop_lines = []
    truncated_warnings = 0
    has_drop_stats = False

    for line in stderr_text.splitlines():
        low = line.lower()
        # Transient live-file checks, retries, or harness logs must not pollute capture stats
        if "canary check" in low or "live check" in low or "transient" in low or line.strip().startswith("["):
            continue
        m_ratio = re.search(
            r"packets received/dropped(?:\s+on\s+interface\s+(?:'[^']*'|\"[^\"]*\"|[^:]+))?:\s*(\d+)/(\d+)",
            low,
        )
        if m_ratio:
            d = int(m_ratio.group(2))
            drops = d if drops is None else drops + d
            drop_lines.append(line.strip())
            has_drop_stats = True
            continue
        m_drop = re.search(
            r"packets dropped(?:\s+on\s+interface\s+(?:'[^']*'|\"[^\"]*\"|[^:]+))?:\s*(\d+)",
            low,
        )
        if m_drop:
            d = int(m_drop.group(1))
            drops = d if drops is None else drops + d
            drop_lines.append(line.strip())
            has_drop_stats = True
            continue
        if "cut short" in low or "truncated" in low or "damaged" in low:
            truncated_warnings += 1
            drop_lines.append(line.strip())

    return {
        "capture_drops": drops if has_drop_stats else "UNKNOWN",
        "has_drop_stats": has_drop_stats,
        "capture_truncated_warnings": truncated_warnings,
        "raw_drop_lines": drop_lines,
    }


def parse_playlist_edge(body_text: str, response_epoch_s: float | None = None) -> dict:
    """
    Computes advertised live edge UTC from successive explicit PDT anchors,
    completed #EXTINF segment durations, and trailing published #EXT-X-PART durations.
    - Validates adjacent segment consistency without accumulating rounding errors across window.
    - Does NOT double-count parts belonging to completed segments.
    - Does NOT count #EXT-X-PRELOAD-HINT entries.
    - Preserves full counters separately from current anchor offset.
    - Returns valid_edge=False (unavailable) if PDT is missing, discontinuous without
      a fresh PDT, adjacent segments are inconsistent (>50ms), or malformed.
    """
    lines = [ln.strip() for ln in body_text.splitlines() if ln.strip()]
    if not lines or lines[0] != "#EXTM3U":
        return {
            "kind": "invalid",
            "valid_edge": False,
            "reason": "invalid_m3u8_header",
            "pdt_utc": None,
            "pdt_epoch_s": None,
            "completed_segments_count": 0,
            "completed_extinf_s": None,
            "completed_segment_parts_superseded": 0,
            "trailing_parts_count": 0,
            "trailing_parts_s": None,
            "preload_hints_ignored": 0,
            "advertised_edge_utc": None,
            "advertised_edge_epoch_s": None,
            "edge_age_at_response_ms": None,
        }

    for ln in lines:
        if ln.startswith("#EXT-X-STREAM-INF:"):
            return {
                "kind": "master",
                "valid_edge": False,
                "reason": "master_playlist",
                "pdt_utc": None,
                "pdt_epoch_s": None,
                "completed_segments_count": 0,
                "completed_extinf_s": None,
                "completed_segment_parts_superseded": 0,
                "trailing_parts_count": 0,
                "trailing_parts_s": None,
                "preload_hints_ignored": 0,
                "advertised_edge_utc": None,
                "advertised_edge_epoch_s": None,
                "edge_age_at_response_ms": None,
            }

    if not any(ln.startswith("#EXT-X-PROGRAM-DATE-TIME:") for ln in lines):
        return {
            "kind": "media",
            "valid_edge": False,
            "reason": "missing_pdt",
            "pdt_utc": None,
            "pdt_epoch_s": None,
            "completed_segments_count": 0,
            "completed_extinf_s": None,
            "completed_segment_parts_superseded": 0,
            "trailing_parts_count": 0,
            "trailing_parts_s": None,
            "preload_hints_ignored": 0,
            "advertised_edge_utc": None,
            "advertised_edge_epoch_s": None,
            "edge_age_at_response_ms": None,
        }

    first_pdt_epoch_s: float | None = None
    first_pdt_str: str | None = None
    current_anchor_pdt_epoch_s: float | None = None
    current_anchor_pdt_str: str | None = None
    current_anchor_extinf_s: float = 0.0

    total_completed_extinf_s: float = 0.0
    total_completed_segments_count: int = 0
    completed_segment_parts_superseded: int = 0

    last_completed_seg_pdt: float | None = None
    last_completed_seg_dur: float | None = None

    pending_parts: list[float] = []
    pending_extinf: float | None = None
    preload_hints_ignored: int = 0
    needs_pdt_after_discontinuity: bool = False

    def fail(reason: str) -> dict:
        return {
            "kind": "media",
            "valid_edge": False,
            "reason": reason,
            "pdt_utc": current_anchor_pdt_str or first_pdt_str,
            "pdt_epoch_s": current_anchor_pdt_epoch_s or first_pdt_epoch_s,
            "completed_segments_count": total_completed_segments_count,
            "completed_extinf_s": None,
            "completed_segment_parts_superseded": completed_segment_parts_superseded,
            "trailing_parts_count": len(pending_parts),
            "trailing_parts_s": None,
            "preload_hints_ignored": preload_hints_ignored,
            "advertised_edge_utc": None,
            "advertised_edge_epoch_s": None,
            "edge_age_at_response_ms": None,
        }

    for ln in lines[1:]:
        if ln == "#EXT-X-DISCONTINUITY":
            if pending_extinf is not None or pending_parts:
                return fail("unclosed_segment_before_discontinuity")
            needs_pdt_after_discontinuity = True
            continue

        if ln.startswith("#EXT-X-PROGRAM-DATE-TIME:"):
            if pending_extinf is not None or pending_parts:
                return fail("unclosed_segment_before_pdt")
            raw_pdt = ln.split(":", 1)[1].strip()
            try:
                pdt_val = parse_iso8601_utc(raw_pdt)
            except Exception:
                return fail("invalid_pdt_format")

            if first_pdt_epoch_s is None:
                first_pdt_epoch_s = pdt_val
                first_pdt_str = raw_pdt
                current_anchor_pdt_epoch_s = pdt_val
                current_anchor_pdt_str = raw_pdt
                current_anchor_extinf_s = 0.0
                needs_pdt_after_discontinuity = False
            elif needs_pdt_after_discontinuity:
                current_anchor_pdt_epoch_s = pdt_val
                current_anchor_pdt_str = raw_pdt
                current_anchor_extinf_s = 0.0
                needs_pdt_after_discontinuity = False
                last_completed_seg_pdt = None
                last_completed_seg_dur = None
            else:
                # Successive explicit anchor: validate adjacent segment consistency
                if last_completed_seg_pdt is not None and last_completed_seg_dur is not None:
                    expected_adjacent = last_completed_seg_pdt + last_completed_seg_dur
                    discrepancy = abs(pdt_val - expected_adjacent)
                    # 50ms tolerance allows adjacent rounding differences (e.g. 1ms for 1.999 vs 2.0s)
                    # without cumulative drift, but rejects genuine 500ms inconsistencies.
                    if discrepancy > 0.050:
                        return fail("inconsistent_adjacent_pdt")
                # Advance the explicit anchor
                current_anchor_pdt_epoch_s = pdt_val
                current_anchor_pdt_str = raw_pdt
                current_anchor_extinf_s = 0.0
            continue

        if ln.startswith("#EXT-X-PRELOAD-HINT:"):
            preload_hints_ignored += 1
            continue

        if ln.startswith("#EXT-X-PART:"):
            if current_anchor_pdt_epoch_s is None:
                return fail("part_before_pdt")
            if needs_pdt_after_discontinuity:
                return fail("discontinuity_without_pdt")
            if pending_extinf is not None:
                return fail("part_after_unconsumed_extinf")
            attrs_str = ln.split(":", 1)[1]
            m_dur = re.search(r"(?:^|,)DURATION=([0-9.+\-eE]+)(?:,|$)", attrs_str)
            m_uri = re.search(r'(?:^|,)URI="([^"]+)"', attrs_str)
            if not m_dur or not m_uri:
                return fail("invalid_part_attributes")
            try:
                d_val = float(m_dur.group(1))
            except ValueError:
                return fail("invalid_part_duration")
            if not math.isfinite(d_val) or d_val <= 0.0:
                return fail("invalid_part_duration")
            pending_parts.append(d_val)
            continue

        if ln.startswith("#EXTINF:"):
            if current_anchor_pdt_epoch_s is None:
                return fail("extinf_before_pdt")
            if needs_pdt_after_discontinuity:
                return fail("discontinuity_without_pdt")
            if pending_extinf is not None:
                return fail("consecutive_extinf_without_uri")
            dur_part = ln.split(":", 1)[1].split(",", 1)[0].strip()
            try:
                ext_val = float(dur_part)
            except ValueError:
                return fail("invalid_extinf_duration")
            if not math.isfinite(ext_val) or ext_val <= 0.0:
                return fail("invalid_extinf_duration")
            pending_extinf = ext_val
            continue

        if ln.startswith("#"):
            continue

        # Media segment URI line
        if pending_extinf is None:
            return fail("segment_uri_without_extinf")
        if current_anchor_pdt_epoch_s is None:
            return fail("segment_before_pdt")
        if needs_pdt_after_discontinuity:
            return fail("discontinuity_without_pdt")

        if pending_parts:
            parts_sum = sum(pending_parts)
            if abs(parts_sum - pending_extinf) > 0.020:
                return fail("part_extinf_mismatch")
            completed_segment_parts_superseded += len(pending_parts)
            pending_parts = []

        total_completed_extinf_s += pending_extinf
        current_anchor_extinf_s += pending_extinf
        total_completed_segments_count += 1
        last_completed_seg_pdt = current_anchor_pdt_epoch_s
        last_completed_seg_dur = pending_extinf
        pending_extinf = None

    if current_anchor_pdt_epoch_s is None:
        return fail("missing_pdt")
    if needs_pdt_after_discontinuity:
        return fail("discontinuity_without_pdt")
    if pending_extinf is not None:
        return fail("dangling_extinf_without_uri")

    trailing_parts_count = len(pending_parts)
    trailing_parts_s = sum(pending_parts)
    if total_completed_segments_count == 0 and trailing_parts_count == 0:
        return fail("no_published_media_duration")

    advertised_edge_epoch_s = current_anchor_pdt_epoch_s + current_anchor_extinf_s + trailing_parts_s
    edge_age_ms = None
    if response_epoch_s is not None:
        edge_age_ms = (response_epoch_s - advertised_edge_epoch_s) * 1000.0

    return {
        "kind": "media",
        "valid_edge": True,
        "reason": "ok",
        "pdt_utc": current_anchor_pdt_str,
        "pdt_epoch_s": current_anchor_pdt_epoch_s,
        "first_pdt_utc": first_pdt_str,
        "first_pdt_epoch_s": first_pdt_epoch_s,
        "completed_segments_count": total_completed_segments_count,
        "completed_extinf_s": round(total_completed_extinf_s, 9),
        "completed_segment_parts_superseded": completed_segment_parts_superseded,
        "trailing_parts_count": trailing_parts_count,
        "trailing_parts_s": round(trailing_parts_s, 9),
        "preload_hints_ignored": preload_hints_ignored,
        "advertised_edge_utc": format_utc_iso(advertised_edge_epoch_s),
        "advertised_edge_epoch_s": advertised_edge_epoch_s,
        "edge_age_at_response_ms": edge_age_ms,
    }


def _iter_fields(elem: ET.Element):
    for child in elem:
        if child.tag == "field":
            yield child
            yield from _iter_fields(child)


def parse_pdml_stream(pdml_source) -> dict:
    """
    Parses TShark PDML output (from file path, file object, or XML string).
    Reconstructs request/response pairs using frame references and tcp.stream,
    and tracks truncated packets, TCP stream anomalies, and incomplete HTTP bodies.
    """
    if isinstance(pdml_source, str) and not pdml_source.lstrip().startswith("<"):
        ctx = ET.iterparse(pdml_source, events=("end",))
    elif isinstance(pdml_source, str):
        ctx = ET.iterparse(io.BytesIO(pdml_source.encode("utf-8")), events=("end",))
    else:
        ctx = ET.iterparse(pdml_source, events=("end",))

    requests_by_frame: dict[int, dict] = {}
    responses_list: list[dict] = []
    truncated_packets: list[dict] = []
    stream_anomalies: dict[int, list[dict]] = {}
    total_packets = 0

    for _, elem in ctx:
        if elem.tag != "packet":
            continue
        total_packets += 1

        frame_num = None
        time_epoch = None
        frame_len = None
        cap_len = None
        tcp_stream = None
        tcp_flags_anomalies = []

        frame_proto = elem.find("proto[@name='frame']")
        if frame_proto is not None:
            for f in _iter_fields(frame_proto):
                fname = f.attrib.get("name", "")
                fshow = f.attrib.get("show", "")
                if fname == "frame.number" and fshow:
                    frame_num = int(fshow)
                elif fname == "frame.time_epoch" and fshow:
                    time_epoch = float(fshow)
                elif fname == "frame.len" and fshow:
                    frame_len = int(fshow)
                elif fname == "frame.cap_len" and fshow:
                    cap_len = int(fshow)

        if frame_num is not None and frame_len is not None and cap_len is not None:
            if cap_len < frame_len:
                truncated_packets.append({
                    "frame_number": frame_num,
                    "time_epoch": time_epoch,
                    "frame_len": frame_len,
                    "cap_len": cap_len,
                })

        tcp_proto = elem.find("proto[@name='tcp']")
        if tcp_proto is not None:
            for f in _iter_fields(tcp_proto):
                fname = f.attrib.get("name", "")
                fshow = f.attrib.get("show", "")
                if fname == "tcp.stream" and fshow:
                    tcp_stream = int(fshow)
                elif fname in (
                    "tcp.analysis.lost_segment",
                    "tcp.analysis.ack_lost_segment",
                    "tcp.analysis.retransmission",
                    "tcp.analysis.out_of_order",
                ):
                    tcp_flags_anomalies.append(fname)

        if tcp_stream is not None and tcp_flags_anomalies:
            stream_anomalies.setdefault(tcp_stream, []).append({
                "frame_number": frame_num,
                "time_epoch": time_epoch,
                "anomalies": tcp_flags_anomalies,
            })

        for http_proto in elem.findall("proto[@name='http']"):
            is_req = False
            is_resp = False
            method = None
            uri = None
            user_agent = None
            response_in = None
            request_in = None
            status_code = None
            content_length = None
            transfer_encoding = None
            content_type = None
            file_data_hex = None
            expert_errors = []

            for f in _iter_fields(http_proto):
                fname = f.attrib.get("name", "")
                fshow = f.attrib.get("show", "")
                fval = f.attrib.get("value", "")
                if fname == "http.request" and fshow in ("1", "True", "true"):
                    is_req = True
                elif fname == "http.response" and fshow in ("1", "True", "true"):
                    is_resp = True
                elif fname == "http.request.method":
                    method = fshow
                    is_req = True
                elif fname == "http.request.uri":
                    uri = fshow
                elif fname == "http.user_agent":
                    user_agent = fshow
                elif fname == "http.response_in" and fshow:
                    response_in = int(fshow)
                elif fname == "http.request_in" and fshow:
                    request_in = int(fshow)
                elif fname == "http.response.code" and fshow:
                    status_code = int(fshow)
                    is_resp = True
                elif fname in ("http.content_length", "http.content_length_header") and fshow:
                    try:
                        content_length = int(fshow.strip())
                    except ValueError:
                        pass
                elif fname == "http.transfer_encoding":
                    transfer_encoding = fshow
                elif fname == "http.content_type":
                    content_type = fshow
                elif fname == "http.file_data" and fval:
                    file_data_hex = fval
                elif fname == "_ws.expert.message" and fshow:
                    low_exp = fshow.lower()
                    if "incomplete" in low_exp or "malformed" in low_exp or "failed" in low_exp or "truncated" in low_exp:
                        expert_errors.append(fshow)

            if is_req and not is_resp and frame_num is not None:
                requests_by_frame[frame_num] = {
                    "frame_number": frame_num,
                    "time_epoch": time_epoch,
                    "tcp_stream": tcp_stream,
                    "method": method or "GET",
                    "uri": uri or "",
                    "user_agent": user_agent or "",
                    "response_in": response_in,
                    "matched": False,
                }
            elif is_resp and frame_num is not None:
                body_bytes = b""
                hex_decode_error = False
                if file_data_hex is not None:
                    try:
                        body_bytes = bytes.fromhex(file_data_hex)
                    except ValueError:
                        hex_decode_error = True

                responses_list.append({
                    "frame_number": frame_num,
                    "time_epoch": time_epoch,
                    "tcp_stream": tcp_stream,
                    "status_code": status_code,
                    "request_in": request_in,
                    "uri_from_resp": uri,
                    "content_length": content_length,
                    "transfer_encoding": transfer_encoding,
                    "content_type": content_type,
                    "body_bytes": body_bytes,
                    "has_file_data": file_data_hex is not None,
                    "hex_decode_error": hex_decode_error,
                    "expert_errors": expert_errors,
                })

        elem.clear()

    pairs = []
    unmatched_responses = []

    for resp in responses_list:
        req = None
        req_in = resp.get("request_in")
        if req_in is not None and req_in in requests_by_frame:
            cand = requests_by_frame[req_in]
            if cand["tcp_stream"] == resp["tcp_stream"] and resp["frame_number"] >= cand["frame_number"]:
                req = cand
        if req is None:
            for cand in requests_by_frame.values():
                if (
                    not cand["matched"]
                    and cand["tcp_stream"] == resp["tcp_stream"]
                    and cand.get("response_in") == resp["frame_number"]
                    and resp["frame_number"] >= cand["frame_number"]
                ):
                    req = cand
                    break

        if req is None:
            unmatched_responses.append({
                "frame_number": resp["frame_number"],
                "time_epoch": resp["time_epoch"],
                "tcp_stream": resp["tcp_stream"],
                "status_code": resp["status_code"],
                "request_in": resp["request_in"],
                "uri_hint": resp.get("uri_from_resp"),
            })
            continue

        req["matched"] = True
        uri = req["uri"]
        path_only = urlsplit(uri).path
        is_playlist = path_only.endswith(".m3u8")

        stream_gaps = [
            a for a in stream_anomalies.get(req["tcp_stream"], [])
            if any(
                flag in ("tcp.analysis.lost_segment", "tcp.analysis.ack_lost_segment")
                for flag in a["anomalies"]
            )
        ]
        truncated_in_exchange = [
            t for t in truncated_packets
            if req["frame_number"] <= t["frame_number"] <= resp["frame_number"]
        ]

        body_bytes = resp["body_bytes"]
        body_text = ""
        utf8_ok = True
        if is_playlist:
            try:
                body_text = body_bytes.decode("utf-8")
            except UnicodeDecodeError:
                utf8_ok = False
                body_text = body_bytes.decode("utf-8", errors="replace")

        length_ok = True
        if (
            resp["content_length"] is not None
            and not (resp["transfer_encoding"] and "chunked" in resp["transfer_encoding"].lower())
        ):
            if len(body_bytes) != resp["content_length"]:
                length_ok = False

        playlist_envelope_ok = True
        if is_playlist:
            if not utf8_ok or not body_text.startswith("#EXTM3U") or not body_text.endswith("\n"):
                playlist_envelope_ok = False

        complete = (
            resp["status_code"] == 200
            and resp["has_file_data"]
            and not resp["hex_decode_error"]
            and not resp["expert_errors"]
            and length_ok
            and (playlist_envelope_ok if is_playlist else len(body_bytes) > 0)
            and len(stream_gaps) == 0
            and len(truncated_in_exchange) == 0
        )

        pairs.append({
            "request_frame": req["frame_number"],
            "response_frame": resp["frame_number"],
            "tcp_stream": req["tcp_stream"],
            "method": req["method"],
            "uri": uri,
            "path": path_only,
            "query": parse_qs(urlsplit(uri).query),
            "user_agent": req["user_agent"],
            "request_time_epoch": req["time_epoch"],
            "response_time_epoch": resp["time_epoch"],
            "status_code": resp["status_code"],
            "content_length": resp["content_length"],
            "transfer_encoding": resp["transfer_encoding"],
            "body_bytes_len": len(body_bytes),
            "body_sha256": sha256_bytes(body_bytes) if body_bytes else None,
            "body_text": body_text if is_playlist else None,
            "complete": complete,
            "incomplete_reasons": [
                r for r, cond in [
                    ("non_200_status", resp["status_code"] != 200),
                    ("missing_file_data", not resp["has_file_data"]),
                    ("hex_decode_error", resp["hex_decode_error"]),
                    ("wireshark_expert_error", bool(resp["expert_errors"])),
                    ("content_length_mismatch", not length_ok),
                    ("invalid_playlist_envelope", is_playlist and not playlist_envelope_ok),
                    ("tcp_stream_loss_gap", len(stream_gaps) > 0),
                    ("truncated_packet", len(truncated_in_exchange) > 0),
                ] if cond
            ],
            "stream_gaps": stream_gaps,
        })

    unmatched_requests = [
        {
            "frame_number": r["frame_number"],
            "time_epoch": r["time_epoch"],
            "tcp_stream": r["tcp_stream"],
            "method": r["method"],
            "uri": r["uri"],
            "user_agent": r["user_agent"],
            "response_in": r["response_in"],
        }
        for r in requests_by_frame.values()
        if not r["matched"]
    ]

    return {
        "total_packets": total_packets,
        "pairs": pairs,
        "unmatched_requests": unmatched_requests,
        "unmatched_responses": unmatched_responses,
        "truncated_packets": truncated_packets,
        "stream_anomalies": stream_anomalies,
    }


def parse_access_log_slice(
    access_log_path: str,
    room_id: str,
    *,
    run_id: str,
    trial_launch_epoch_s: float | None = None,
    trial_end_epoch_s: float | None = None,
) -> dict:
    """
    Parses a trial's frontend Nginx access.log slice.
    - Accepts empty http3 and ssl fields.
    - Returns structured parsed exchange records.
    - Distinguishes teardown-consistent blocking reload (499 / 0-byte) entries from
      startup/in-run failures using trial-end timing and 1-second log quantization.
    - Preserves teardown cancellations diagnostically without blanket-ignoring non-200.
    """
    if not os.path.exists(access_log_path):
        return {
            "exists": False,
            "exchanges": [],
            "teardown_cancellations": [],
            "startup_failures": [],
            "master_h2_200": 0,
            "video_h2_200": 0,
            "audio_h2_200": 0,
            "media_h2_200": 0,
            "non_h2_protocols": [],
            "non_200_statuses": [],
            "user_agents": [],
            "has_nonzero_transfers": False,
            "total_bytes": 0,
        }

    exchanges = []
    teardown_cancellations = []
    startup_failures = []
    non_200 = []
    non_h2 = set()
    user_agents = set()
    total_bytes = 0

    master_h2_200 = 0
    video_h2_200 = 0
    audio_h2_200 = 0
    media_h2_200 = 0

    line_re = re.compile(
        r'^(?P<ts>\S+)\s+client=(?P<client>\S*)\s+protocol=(?P<proto>\S+)\s+http3=(?P<h3>\S*)\s+'
        r'ssl_proto=(?P<ssl_p>\S*)\s+ssl_cipher=(?P<ssl_c>\S*)\s+method=(?P<method>\S+)\s+'
        r'uri="(?P<uri>[^"]*)"\s+status=(?P<status>\d+)\s+bytes=(?P<bytes>\d+)\s+'
        r'request_time=(?P<rt>\S+)\s+ua="(?P<ua>[^"]*)"'
    )

    with open(access_log_path, "r", encoding="utf-8", errors="replace") as f:
        for raw_line in f:
            line = raw_line.strip()
            if not line:
                continue
            m = line_re.search(line)
            if not m:
                continue
            uri = m.group("uri")
            proto = m.group("proto")
            status = int(m.group("status"))
            b_val = int(m.group("bytes"))
            ua = m.group("ua")
            if "VGCanary" in ua or "vg_canary" in uri:
                continue

            parsed_uri = urlsplit(uri)
            path_only = parsed_uri.path
            query_str = parsed_uri.query

            is_room_playlist = path_only.startswith(f"/live/{room_id}/")
            is_run_media = path_only.startswith(f"/media/{run_id}/")
            if not is_room_playlist and not is_run_media:
                continue

            user_agents.add(ua)
            if proto != "HTTP/2.0":
                non_h2.add(proto)

            try:
                entry_epoch = parse_iso8601_utc(m.group("ts"))
            except Exception:
                entry_epoch = 0.0

            try:
                rt_float = float(m.group("rt"))
            except ValueError:
                rt_float = 0.0

            rec = {
                "ts_raw": m.group("ts"),
                "time_epoch": entry_epoch,
                "client": m.group("client"),
                "protocol": proto,
                "http3": m.group("h3"),
                "ssl_proto": m.group("ssl_p"),
                "ssl_cipher": m.group("ssl_c"),
                "method": m.group("method"),
                "uri": uri,
                "path": path_only,
                "query": query_str,
                "status": status,
                "bytes": b_val,
                "request_time": rt_float,
                "ua": ua,
            }
            exchanges.append(rec)

            is_teardown_consistent = False
            if trial_end_epoch_s is not None:
                floor_end = math.floor(trial_end_epoch_s)
                within_window = (floor_end - 1.0) <= entry_epoch <= (floor_end + 1.0)
                is_apple_core_media = ("AppleCoreMedia" in ua) and ("VGCanary" not in ua)
                is_owned = is_room_playlist or is_run_media

                if (
                    status == 499
                    and b_val == 0
                    and m.group("method") == "GET"
                    and is_apple_core_media
                    and is_owned
                    and within_window
                ):
                    is_teardown_consistent = True

            if is_teardown_consistent:
                rec["cancellation_classification"] = "teardown_consistent"
                rec["cancellation_target"] = "playlist" if is_room_playlist else "media"
                teardown_cancellations.append(rec)
            elif status != 200 or b_val <= 0:
                startup_failures.append(rec)
                non_200.append({
                    "uri": uri,
                    "status": status,
                    "bytes": b_val,
                    "protocol": proto,
                    "time_epoch": entry_epoch,
                    "method": m.group("method"),
                })
                continue

            total_bytes += b_val
            has_reload_params = ("_HLS_msn" in query_str) or ("_HLS_part" in query_str)

            if proto == "HTTP/2.0" and status == 200 and b_val > 0:
                if path_only == f"/live/{room_id}/master.m3u8":
                    master_h2_200 += 1
                elif path_only in (
                    f"/live/{room_id}/vhi.m3u8",
                    f"/live/{room_id}/vmid.m3u8",
                    f"/live/{room_id}/vlo.m3u8",
                    f"/live/{room_id}/video.m3u8",
                ) and not has_reload_params:
                    video_h2_200 += 1
                elif path_only in (
                    f"/live/{room_id}/a.m3u8",
                    f"/live/{room_id}/audio.m3u8",
                ) and not has_reload_params:
                    audio_h2_200 += 1
                elif is_run_media:
                    media_h2_200 += 1

    return {
        "exists": True,
        "exchanges": exchanges,
        "teardown_cancellations": teardown_cancellations,
        "teardown_cancellations_playlist": [
            c for c in teardown_cancellations if c.get("cancellation_target") == "playlist"
        ],
        "teardown_cancellations_media": [
            c for c in teardown_cancellations if c.get("cancellation_target") == "media"
        ],
        "startup_failures": startup_failures,
        "master_h2_200": master_h2_200,
        "video_h2_200": video_h2_200,
        "audio_h2_200": audio_h2_200,
        "media_h2_200": media_h2_200,
        "total_bytes": total_bytes,
        "has_nonzero_transfers": (total_bytes > 0),
        "non_h2_protocols": sorted(non_h2),
        "non_200_statuses": non_200,
        "user_agents": sorted(user_agents),
    }


def match_initial_playlist_exchange(
    exchanges: list[dict],
    *,
    expected_uri: str,
    expected_user_agent: str,
    expected_bytes: int | None = None,
    expected_response_epoch_s: float | None = None,
    trial_launch_epoch_s: float | None = None,
    first_playing_epoch_s: float | None = None,
) -> dict:
    """
    Matches each required initial playlist by:
    - captured initial URI including query from selected captured pair (exact match)
    - exact User-Agent from selected captured pair
    - required captured body-byte-count matching (bytes == expected_bytes)
    - successful nonzero transfer (status=200, bytes>0, HTTP/2.0)
    - response-time interval with 1-second log quantization.
    Missing evidence fails closed. Multiple candidates remain ambiguous. No rendition-category fallback.
    """
    if not expected_uri or not expected_user_agent or expected_bytes is None or expected_bytes <= 0:
        return {
            "matched": False,
            "status": "missing",
            "exchange": None,
            "candidates_count": 0,
            "reason": "missing_expected_evidence",
        }

    candidates = []
    for ex in exchanges:
        if ex.get("protocol") != "HTTP/2.0":
            continue
        if ex.get("status") != 200 or (ex.get("bytes") or 0) <= 0:
            continue
        if ex.get("bytes") != expected_bytes:
            continue
        if ex.get("uri") != expected_uri:
            continue
        if ex.get("ua") != expected_user_agent:
            continue

        t_epoch = ex.get("time_epoch", 0.0)
        # Check response-time interval:
        if expected_response_epoch_s is not None:
            # Allow 1-second log quantization against the upstream response timestamp
            if abs(t_epoch - expected_response_epoch_s) > 1.5:
                continue
        elif trial_launch_epoch_s is not None:
            # Allow 1-second log quantization against trial launch
            if t_epoch < (math.floor(trial_launch_epoch_s) - 1.0):
                continue
            if first_playing_epoch_s is not None and t_epoch > (math.ceil(first_playing_epoch_s) + 1.0):
                continue

        candidates.append(ex)

    if len(candidates) == 1:
        return {
            "matched": True,
            "status": "matched",
            "exchange": candidates[0],
            "candidates_count": 1,
        }
    elif len(candidates) > 1:
        return {
            "matched": False,
            "status": "ambiguous",
            "exchange": None,
            "candidates_count": len(candidates),
            "candidates": candidates,
        }
    else:
        return {
            "matched": False,
            "status": "missing",
            "exchange": None,
            "candidates_count": 0,
        }


def parse_probe_jsonl(probe_jsonl_path: str) -> dict:
    """
    Parses a trial's probe.jsonl, separating:
    - First decoded frame vs first valid playing sample (valid=True, time_control_status='playing', effective_timebase_rate ~ 1.0)
    - Waiting-state decoded frames (excluded from playing samples)
    - First valid playing decoded-frame age
    - Playing-frame median after 5.0 seconds from the first playing sample
    - Native PDT age (item_date_age_ms)
    - Time to first decoded frame and time to first observed playing sample
    - Distinguishes nonfatal -15410 ECN advisories from fatal errors
    """
    if not os.path.exists(probe_jsonl_path):
        return {
            "exists": False,
            "teardown_present": False,
            "decode_failure_count": 0,
            "native_error_log_events": [],
            "fatal_native_errors": [],
            "ecn_advisories": [],
            "waiting_valid_samples_excluded": 0,
            "playing_samples_count": 0,
            "playing_samples_after_5s_count": 0,
            "first_playing_utc": None,
            "time_to_first_decoded_frame_ms": None,
            "time_to_first_playing_sample_ms": None,
            "first_decoded_frame_age_ms": None,
            "first_playing_frame_age_ms": None,
            "playing_age_median_after_5s_ms": None,
            "playing_age_p95_after_5s_ms": None,
            "first_decoded_native_pdt_age_ms": None,
            "first_playing_native_pdt_age_ms": None,
            "playing_native_pdt_age_median_after_5s_ms": None,
        }

    first_decoded_sample = None
    first_playing_sample = None
    waiting_valid_excluded = 0
    playing_samples = []
    decode_failure_records = 0
    teardown_record = None

    with open(probe_jsonl_path, "r", encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.strip()
            if not line:
                continue
            rec = json.loads(line)
            if rec.get("teardown") is True:
                teardown_record = rec
                continue

            if rec.get("valid") is True:
                if first_decoded_sample is None:
                    first_decoded_sample = rec
                tcs = rec.get("time_control_status")
                rate = rec.get("effective_timebase_rate")
                is_playing = (
                    tcs == "playing"
                    and isinstance(rate, (int, float))
                    and abs(float(rate) - 1.0) <= 0.05
                )
                if is_playing:
                    if first_playing_sample is None:
                        first_playing_sample = rec
                    playing_samples.append(rec)
                else:
                    waiting_valid_excluded += 1
            else:
                decode_failure_records += 1

    time_to_first_decoded_ms = None
    first_decoded_age_ms = None
    first_decoded_pdt_age_ms = None
    if first_decoded_sample is not None:
        if first_decoded_sample.get("startup_elapsed_ms") is not None:
            time_to_first_decoded_ms = float(first_decoded_sample["startup_elapsed_ms"])
        if first_decoded_sample.get("age_ms") is not None:
            first_decoded_age_ms = float(first_decoded_sample["age_ms"])
        if first_decoded_sample.get("item_date_age_ms") is not None:
            first_decoded_pdt_age_ms = float(first_decoded_sample["item_date_age_ms"])

    time_to_first_playing_ms = None
    first_playing_age_ms = None
    first_playing_pdt_age_ms = None
    first_playing_utc = None
    after_5s_ages = []
    after_5s_pdt_ages = []

    if first_playing_sample is not None:
        first_playing_utc = first_playing_sample.get("utc")
        if first_playing_sample.get("age_ms") is not None:
            first_playing_age_ms = float(first_playing_sample["age_ms"])
        if first_playing_sample.get("item_date_age_ms") is not None:
            first_playing_pdt_age_ms = float(first_playing_sample["item_date_age_ms"])

        if (
            first_decoded_sample is not None
            and first_decoded_sample.get("startup_elapsed_ms") is not None
            and first_decoded_sample.get("observation_mono_ms") is not None
            and first_playing_sample.get("observation_mono_ms") is not None
        ):
            delta_after_first_decode = (
                float(first_playing_sample["observation_mono_ms"])
                - float(first_decoded_sample["observation_mono_ms"])
            )
            time_to_first_playing_ms = float(first_decoded_sample["startup_elapsed_ms"]) + delta_after_first_decode

        t0_play_mono = float(first_playing_sample["observation_mono_ms"])
        for s in playing_samples:
            dt_ms = float(s["observation_mono_ms"]) - t0_play_mono
            if dt_ms > 5000.0:
                if s.get("age_ms") is not None:
                    after_5s_ages.append(float(s["age_ms"]))
                if s.get("item_date_age_ms") is not None:
                    after_5s_pdt_ages.append(float(s["item_date_age_ms"]))

    teardown_failures = (
        int(teardown_record.get("failure_count", 0))
        if teardown_record is not None
        else decode_failure_records
    )
    raw_native_errors = (
        teardown_record.get("native_error_log_events", [])
        if teardown_record is not None
        else []
    )

    fatal_native_errors = []
    ecn_advisories = []
    for ev in raw_native_errors:
        domain = ev.get("domain", "")
        status = ev.get("status")
        comment = ev.get("comment", "")
        # Whitelist ONLY the known CoreMedia -15410 ECN advisory when exact error fields match:
        # Real transport errors mentioning ECN remain fatal.
        if (
            domain == "CoreMediaErrorDomain"
            and status == -15410
            and comment == "Server should support ECN for Low Latency"
        ):
            ecn_advisories.append(ev)
        else:
            fatal_native_errors.append(ev)

    return {
        "exists": True,
        "teardown_present": teardown_record is not None,
        "decode_failure_count": max(decode_failure_records, teardown_failures),
        "native_error_log_events": raw_native_errors,
        "fatal_native_errors": fatal_native_errors,
        "ecn_advisories": ecn_advisories,
        "waiting_valid_samples_excluded": waiting_valid_excluded,
        "playing_samples_count": len(playing_samples),
        "playing_samples_after_5s_count": len(after_5s_ages),
        "first_playing_utc": first_playing_utc,
        "time_to_first_decoded_frame_ms": time_to_first_decoded_ms,
        "time_to_first_playing_sample_ms": time_to_first_playing_ms,
        "first_decoded_frame_age_ms": first_decoded_age_ms,
        "first_playing_frame_age_ms": first_playing_age_ms,
        "playing_age_median_after_5s_ms": calc_median(after_5s_ages),
        "playing_age_p95_after_5s_ms": calc_p95(after_5s_ages),
        "first_decoded_native_pdt_age_ms": first_decoded_pdt_age_ms,
        "first_playing_native_pdt_age_ms": first_playing_pdt_age_ms,
        "playing_native_pdt_age_median_after_5s_ms": calc_median(after_5s_pdt_ages),
    }


def classify_playlist_role(path: str, query: dict, room_id: str) -> str | None:
    prefix = f"/live/{room_id}/"
    if not path.startswith(prefix):
        return None
    name = path[len(prefix):]
    has_hls_reload = ("_HLS_msn" in query) or ("_HLS_part" in query)
    if name == "master.m3u8":
        return "master"
    if name in ("vhi.m3u8", "vmid.m3u8", "vlo.m3u8", "video.m3u8"):
        return "video_reload" if has_hls_reload else "video"
    if name in ("a.m3u8", "audio.m3u8"):
        return "audio_reload" if has_hls_reload else "audio"
    return None


def correlate_trials(
    pdml_data: dict,
    trials_meta: list[dict],
    room_id: str,
    results_dir: str,
    *,
    run_id: str,
    stderr_health: dict | None = None,
) -> tuple[dict, list[dict], dict]:
    """
    Correlates PDML HTTP request/response pairs with the 12 sequential trials.
    Scopes media evidence to /media/<run_id>/ and AppleCoreMedia.
    Distinguishes required startup exchanges from later requests and normal teardown cancellations.
    """
    if stderr_health is None:
        stderr_health = {
            "capture_drops": "UNKNOWN",
            "has_drop_stats": False,
            "capture_truncated_warnings": 0,
            "raw_drop_lines": [],
        }

    canary_requests = []
    unrelated_traffic = []
    teardown_cancelled_blocking_reloads = []
    relevant_stream_gaps = []
    playlists_records = []

    for ureq in pdml_data.get("unmatched_requests", []):
        uri = ureq.get("uri", "")
        if f"/live/{room_id}/" not in uri and not uri.startswith(f"/media/{run_id}/"):
            unrelated_traffic.append(ureq)
        elif "_HLS_msn" in uri or "_HLS_part" in uri:
            teardown_cancelled_blocking_reloads.append(ureq)

    for uresp in pdml_data.get("unmatched_responses", []):
        uri_hint = uresp.get("uri_hint") or ""
        if uri_hint and f"/live/{room_id}/" not in uri_hint and not uri_hint.startswith(f"/media/{run_id}/"):
            unrelated_traffic.append(uresp)

    # Map each exchange to a trial by timestamp window, room/run URI, and User-Agent
    pairs_by_trial: dict[int, list[dict]] = {int(t["trial_index"]): [] for t in trials_meta}

    for pair in pdml_data.get("pairs", []):
        uri = pair["uri"]
        ua = pair["user_agent"]
        path = pair["path"]
        query = pair["query"]

        if "vg_canary" in uri or "VGCanary" in ua:
            canary_requests.append({
                "request_frame": pair["request_frame"],
                "response_frame": pair["response_frame"],
                "tcp_stream": pair["tcp_stream"],
                "uri": uri,
                "user_agent": ua,
                "request_time_epoch": pair["request_time_epoch"],
                "response_time_epoch": pair["response_time_epoch"],
                "status_code": pair["status_code"],
                "complete": pair["complete"],
            })
            continue

        is_room_playlist = path.startswith(f"/live/{room_id}/")
        is_run_media = path.startswith(f"/media/{run_id}/")
        if not is_room_playlist and not is_run_media:
            unrelated_traffic.append({
                "request_frame": pair["request_frame"],
                "uri": uri,
                "user_agent": ua,
                "time_epoch": pair["request_time_epoch"],
            })
            continue

        if "AppleCoreMedia" not in ua:
            unrelated_traffic.append({
                "reason": "non_apple_core_media",
                "request_frame": pair["request_frame"],
                "uri": uri,
                "user_agent": ua,
            })
            continue

        if pair["stream_gaps"]:
            relevant_stream_gaps.extend(pair["stream_gaps"])

        role = classify_playlist_role(path, query, room_id)
        if role is None:
            # Media request
            continue

        req_t = pair["request_time_epoch"]
        resp_t = pair["response_time_epoch"]
        matched_trials = []
        for t in trials_meta:
            t_idx = int(t["trial_index"])
            t_start = float(t["launch_epoch_s"]) - 0.05
            t_end = float(t["end_epoch_s"]) + 0.50
            if req_t is not None and resp_t is not None and (t_start <= req_t <= t_end) and (t_start <= resp_t <= t_end):
                matched_trials.append(t_idx)

        if len(matched_trials) == 1:
            pairs_by_trial[matched_trials[0]].append({**pair, "role": role})

    trial_summaries = []
    incomplete_initial_responses = []
    total_decoder_errors = 0

    for t in trials_meta:
        t_idx = int(t["trial_index"])
        trial_id = f"trial_{t_idx:02d}"
        trial_dir = os.path.join(results_dir, trial_id)
        probe_jsonl_path = os.path.join(trial_dir, "probe.jsonl")
        access_log_path = os.path.join(trial_dir, "access.log")

        probe_info = parse_probe_jsonl(probe_jsonl_path)
        access_info = parse_access_log_slice(
            access_log_path,
            room_id,
            run_id=run_id,
            trial_launch_epoch_s=t.get("launch_epoch_s"),
            trial_end_epoch_s=t.get("end_epoch_s"),
        )
        total_decoder_errors += probe_info["decode_failure_count"]

        first_play_epoch = None
        if probe_info.get("first_playing_utc"):
            try:
                first_play_epoch = parse_iso8601_utc(probe_info["first_playing_utc"])
            except Exception:
                pass

        tpairs = sorted(
            pairs_by_trial.get(t_idx, []),
            key=lambda x: (x["request_time_epoch"] or 0.0, x["request_frame"])
        )

        initial_master = None
        initial_video = None
        initial_audio = None

        for p in tpairs:
            role = p["role"]
            is_initial = False
            if role == "master" and initial_master is None:
                initial_master = p
                is_initial = True
            elif role == "video" and initial_video is None:
                initial_video = p
                is_initial = True
            elif role == "audio" and initial_audio is None:
                initial_audio = p
                is_initial = True

            edge_info = (
                parse_playlist_edge(p["body_text"] or "", p["response_time_epoch"])
                if p["complete"] and p["body_text"] is not None
                else {
                    "kind": "incomplete",
                    "valid_edge": False,
                    "reason": "incomplete_http_response",
                    "pdt_utc": None,
                    "pdt_epoch_s": None,
                    "completed_segments_count": 0,
                    "completed_extinf_s": None,
                    "completed_segment_parts_superseded": 0,
                    "trailing_parts_count": 0,
                    "trailing_parts_s": None,
                    "preload_hints_ignored": 0,
                    "advertised_edge_utc": None,
                    "advertised_edge_epoch_s": None,
                    "edge_age_at_response_ms": None,
                }
            )
            p["edge_info"] = edge_info
            p["is_initial"] = is_initial

            playlists_records.append({
                "trial_index": t_idx,
                "trial_id": trial_id,
                "role": role,
                "is_initial": is_initial,
                "request_frame": p["request_frame"],
                "response_frame": p["response_frame"],
                "tcp_stream": p["tcp_stream"],
                "uri": p["uri"],
                "user_agent": p["user_agent"],
                "request_time_epoch": p["request_time_epoch"],
                "request_utc": format_utc_iso(p["request_time_epoch"]) if p["request_time_epoch"] else None,
                "response_time_epoch": p["response_time_epoch"],
                "response_utc": format_utc_iso(p["response_time_epoch"]) if p["response_time_epoch"] else None,
                "status_code": p["status_code"],
                "complete": p["complete"],
                "incomplete_reasons": p["incomplete_reasons"],
                "body_bytes_len": p["body_bytes_len"],
                "body_sha256": p["body_sha256"],
                "body_text": p["body_text"],
                "edge_timing": edge_info,
            })

            if is_initial and not p["complete"]:
                incomplete_initial_responses.append({
                    "trial_index": t_idx,
                    "role": role,
                    "request_frame": p["request_frame"],
                    "response_frame": p["response_frame"],
                    "reasons": p["incomplete_reasons"],
                })

        invalidation_reasons = []

        # 1. Capture drop statistics & integrity
        has_stats = stderr_health.get("has_drop_stats", False)
        drop_val = stderr_health.get("capture_drops")
        if not has_stats or drop_val == "UNKNOWN":
            invalidation_reasons.append("capture_drop_statistics_unknown")
        elif isinstance(drop_val, int) and drop_val > 0:
            invalidation_reasons.append("capture_drops_present")

        if stderr_health.get("capture_truncated_warnings", 0) > 0 or len(pdml_data.get("truncated_packets", [])) > 0:
            invalidation_reasons.append("truncated_packets_present")

        if not t.get("capture_active_before", False) or not t.get("capture_active_after", False):
            invalidation_reasons.append("capture_inactive_during_trial")

        # 2. Check for unmatched startup requests within trial window
        t_start = float(t["launch_epoch_s"]) - 0.05
        t_end = float(t["end_epoch_s"]) + 0.50
        for ureq in pdml_data.get("unmatched_requests", []):
            uri = ureq.get("uri", "")
            ut = ureq.get("time_epoch")
            if ut is None or not (t_start <= ut <= t_end):
                continue
            if "_HLS_msn" in uri or "_HLS_part" in uri:
                continue
            if f"/live/{room_id}/" not in uri and not uri.startswith(f"/media/{run_id}/"):
                continue
            # If an unmatched request occurred before first playing sample for a required startup playlist:
            if first_play_epoch is not None and ut <= first_play_epoch:
                invalidation_reasons.append(f"unmatched_startup_request:{uri}")

        # 3. Initial playlists presence, completeness & edge calculation
        for role_name, init_obj in [
            ("master", initial_master),
            ("video", initial_video),
            ("audio", initial_audio),
        ]:
            if init_obj is None:
                invalidation_reasons.append(f"missing_initial_{role_name}_playlist")
            else:
                if not init_obj["complete"]:
                    invalidation_reasons.append(f"incomplete_initial_{role_name}_response")
                if init_obj["stream_gaps"]:
                    invalidation_reasons.append(f"tcp_stream_gap_on_initial_{role_name}")
                if role_name in ("video", "audio"):
                    ei = init_obj["edge_info"]
                    if not ei["valid_edge"]:
                        invalidation_reasons.append(f"{role_name}_playlist_edge_unavailable:{ei['reason']}")

        # 4. Frontend HTTP/2 access.log correlation
        if not access_info["exists"]:
            invalidation_reasons.append("missing_access_log")
        else:
            # Match each required initial playlist by exact URI/query, AppleCoreMedia UA,
            # successful nonzero transfer and response-time interval:
            for role_name, init_pair in [
                ("master", initial_master),
                ("video", initial_video),
                ("audio", initial_audio),
            ]:
                if init_pair is None:
                    continue

                exp_uri = init_pair.get("uri")
                exp_ua = init_pair.get("user_agent")
                exp_resp = init_pair.get("response_time_epoch")
                exp_bytes = init_pair.get("body_bytes_len")

                if not exp_uri or not exp_ua or exp_bytes is None or exp_bytes <= 0:
                    invalidation_reasons.append(f"missing_captured_pair_evidence:{role_name}")
                    continue

                match_res = match_initial_playlist_exchange(
                    access_info.get("exchanges", []),
                    expected_uri=exp_uri,
                    expected_user_agent=exp_ua,
                    expected_bytes=exp_bytes,
                    expected_response_epoch_s=exp_resp,
                    trial_launch_epoch_s=t.get("launch_epoch_s"),
                    first_playing_epoch_s=first_play_epoch,
                )
                if match_res["status"] == "ambiguous":
                    invalidation_reasons.append(f"ambiguous_initial_{role_name}_delivery_evidence")
                elif match_res["status"] == "missing":
                    invalidation_reasons.append(f"missing_initial_{role_name}_delivery_evidence")

            if access_info["media_h2_200"] < 1:
                invalidation_reasons.append("missing_h2_access_log_media")
            if not access_info["has_nonzero_transfers"]:
                invalidation_reasons.append("missing_nonzero_transfer_evidence")
            if access_info["non_h2_protocols"]:
                invalidation_reasons.append("non_h2_frontend_protocol_detected")
            if access_info["startup_failures"]:
                invalidation_reasons.append("frontend_non_200_status_detected")

        # 5. Probe execution & playing frame requirements
        if t.get("exit_code") != 0:
            invalidation_reasons.append(f"probe_nonzero_exit:{t.get('exit_code')}")
        if not probe_info["exists"] or not probe_info["teardown_present"]:
            invalidation_reasons.append("missing_probe_teardown")
        if probe_info["decode_failure_count"] > 0:
            invalidation_reasons.append("marker_decode_failures_present")
        if probe_info["fatal_native_errors"]:
            invalidation_reasons.append("fatal_native_error_log_events_present")
        if probe_info["first_playing_frame_age_ms"] is None:
            invalidation_reasons.append("no_valid_playing_samples")
        if probe_info["playing_age_median_after_5s_ms"] is None:
            invalidation_reasons.append("no_playing_samples_after_5s")

        valid_trial = len(invalidation_reasons) == 0

        video_edge_age_ms = (
            initial_video["edge_info"]["edge_age_at_response_ms"]
            if initial_video and initial_video["edge_info"]["valid_edge"]
            else None
        )
        audio_edge_age_ms = (
            initial_audio["edge_info"]["edge_age_at_response_ms"]
            if initial_audio and initial_audio["edge_info"]["valid_edge"]
            else None
        )

        trial_summaries.append({
            "trial_index": t_idx,
            "trial_id": trial_id,
            "valid_trial": valid_trial,
            "invalidation_reasons": invalidation_reasons,
            "pre_delay_target_s": t.get("pre_delay_target_s"),
            "launch_utc": t.get("launch_utc"),
            "launch_epoch_s": t.get("launch_epoch_s"),
            "launch_mono_ms": t.get("launch_mono_ms"),
            "end_utc": t.get("end_utc"),
            "end_epoch_s": t.get("end_epoch_s"),
            "end_mono_ms": t.get("end_mono_ms"),
            "probe_exit_code": t.get("exit_code"),
            "initial_playlists": {
                role_name: (
                    {
                        "request_frame": obj["request_frame"],
                        "response_frame": obj["response_frame"],
                        "tcp_stream": obj["tcp_stream"],
                        "uri": obj["uri"],
                        "request_utc": format_utc_iso(obj["request_time_epoch"]),
                        "response_utc": format_utc_iso(obj["response_time_epoch"]),
                        "request_time_epoch": obj["request_time_epoch"],
                        "response_time_epoch": obj["response_time_epoch"],
                        "body_sha256": obj["body_sha256"],
                        "body_bytes_len": obj["body_bytes_len"],
                        "complete": obj["complete"],
                        "advertised_edge_utc": obj["edge_info"]["advertised_edge_utc"],
                        "pdt_utc": obj["edge_info"]["pdt_utc"],
                        "completed_extinf_s": obj["edge_info"]["completed_extinf_s"],
                        "trailing_parts_s": obj["edge_info"]["trailing_parts_s"],
                        "edge_age_at_response_ms": obj["edge_info"]["edge_age_at_response_ms"],
                    }
                    if obj is not None
                    else None
                )
                for role_name, obj in [
                    ("master", initial_master),
                    ("video", initial_video),
                    ("audio", initial_audio),
                ]
            },
            "metrics_separated": {
                "initial_video_playlist_edge_age_at_response_ms": video_edge_age_ms,
                "initial_audio_playlist_edge_age_at_response_ms": audio_edge_age_ms,
                "first_playing_native_pdt_age_ms": probe_info["first_playing_native_pdt_age_ms"],
                "playing_native_pdt_age_median_after_5s_ms": probe_info["playing_native_pdt_age_median_after_5s_ms"],
                "first_playing_decoded_frame_age_ms": probe_info["first_playing_frame_age_ms"],
                "playing_frame_age_median_after_5s_ms": probe_info["playing_age_median_after_5s_ms"],
                "playing_frame_age_p95_after_5s_ms": probe_info["playing_age_p95_after_5s_ms"],
                "time_to_first_decoded_frame_ms": probe_info["time_to_first_decoded_frame_ms"],
                "time_to_first_playing_sample_ms": probe_info["time_to_first_playing_sample_ms"],
            },
            "probe_diagnostics": {
                "first_decoded_frame_age_ms": probe_info["first_decoded_frame_age_ms"],
                "first_decoded_native_pdt_age_ms": probe_info["first_decoded_native_pdt_age_ms"],
                "waiting_valid_samples_excluded": probe_info["waiting_valid_samples_excluded"],
                "playing_samples_count": probe_info["playing_samples_count"],
                "playing_samples_after_5s_count": probe_info["playing_samples_after_5s_count"],
                "decode_failure_count": probe_info["decode_failure_count"],
                "native_error_log_events": probe_info["native_error_log_events"],
                "fatal_native_errors": probe_info["fatal_native_errors"],
                "ecn_advisories": probe_info["ecn_advisories"],
            },
            "frontend_access_log": access_info,
        })

    is_healthy = (
        stderr_health.get("has_drop_stats", False)
        and stderr_health.get("capture_drops") == 0
        and stderr_health.get("capture_truncated_warnings", 0) == 0
        and len(pdml_data.get("truncated_packets", [])) == 0
        and len(relevant_stream_gaps) == 0
        and len(incomplete_initial_responses) == 0
        and total_decoder_errors == 0
    )

    capture_health = {
        "healthy": is_healthy,
        "total_packets_parsed": pdml_data.get("total_packets", 0),
        "capture_drops": stderr_health.get("capture_drops"),
        "has_drop_stats": stderr_health.get("has_drop_stats", False),
        "capture_truncated_warnings": stderr_health.get("capture_truncated_warnings", 0),
        "raw_drop_lines": stderr_health.get("raw_drop_lines", []),
        "truncated_packets_count": len(pdml_data.get("truncated_packets", [])),
        "truncated_packets": pdml_data.get("truncated_packets", []),
        "relevant_stream_gaps_count": len(relevant_stream_gaps),
        "relevant_stream_gaps": relevant_stream_gaps,
        "incomplete_initial_responses_count": len(incomplete_initial_responses),
        "incomplete_initial_responses": incomplete_initial_responses,
        "canary_requests_excluded_count": len(canary_requests),
        "canary_requests_excluded": canary_requests,
        "unrelated_traffic_count": len(unrelated_traffic),
        "unrelated_traffic": unrelated_traffic,
        "teardown_cancelled_blocking_reloads_count": len(teardown_cancelled_blocking_reloads),
        "teardown_cancelled_blocking_reloads": teardown_cancelled_blocking_reloads,
        "total_marker_decoder_errors": total_decoder_errors,
    }

    valid_trials = [t for t in trial_summaries if t["valid_trial"]]

    def agg_metric(key: str) -> dict:
        vals = [
            t["metrics_separated"][key]
            for t in valid_trials
            if t["metrics_separated"].get(key) is not None
        ]
        if not vals:
            return {"count": 0, "min": None, "median": None, "p95": None, "max": None, "spread": None}
        return {
            "count": len(vals),
            "min": round(min(vals), 3),
            "median": round(calc_median(vals), 3),
            "p95": round(calc_p95(vals), 3),
            "max": round(max(vals), 3),
            "spread": round(max(vals) - min(vals), 3),
        }

    v_edge = [t["metrics_separated"]["initial_video_playlist_edge_age_at_response_ms"] for t in valid_trials]
    a_edge = [t["metrics_separated"]["initial_audio_playlist_edge_age_at_response_ms"] for t in valid_trials]
    first_play = [t["metrics_separated"]["first_playing_decoded_frame_age_ms"] for t in valid_trials]
    steady_play = [t["metrics_separated"]["playing_frame_age_median_after_5s_ms"] for t in valid_trials]

    healthy_complete_success = bool(
        capture_health["healthy"]
        and len(valid_trials) > 0
        and len(trial_summaries) == 12
        and len(valid_trials) == len(trial_summaries)
        and pdml_data.get("total_packets", 0) > 0
    )

    summary = {
        "room_id": room_id,
        "run_id": run_id,
        "measurement_note": (
            "All decoded-frame marker ages measure same-host monotonic timestamp delta "
            "(CVPixelBuffer observation minus Cairo marker draw), NOT physical glass-to-glass latency. "
            "Reported relationships between initial playlist edge ages and playback frame ages are "
            "observational associations across trials, not proof of causation."
        ),
        "total_trials": len(trial_summaries),
        "valid_trials_count": len(valid_trials),
        "invalidated_trials_count": len(trial_summaries) - len(valid_trials),
        "capture_healthy": capture_health["healthy"],
        "healthy_complete_success": healthy_complete_success,
        "aggregates_valid_trials_only": {
            "initial_video_playlist_edge_age_at_response_ms": agg_metric("initial_video_playlist_edge_age_at_response_ms"),
            "initial_audio_playlist_edge_age_at_response_ms": agg_metric("initial_audio_playlist_edge_age_at_response_ms"),
            "first_playing_native_pdt_age_ms": agg_metric("first_playing_native_pdt_age_ms"),
            "playing_native_pdt_age_median_after_5s_ms": agg_metric("playing_native_pdt_age_median_after_5s_ms"),
            "first_playing_decoded_frame_age_ms": agg_metric("first_playing_decoded_frame_age_ms"),
            "playing_frame_age_median_after_5s_ms": agg_metric("playing_frame_age_median_after_5s_ms"),
            "time_to_first_decoded_frame_ms": agg_metric("time_to_first_decoded_frame_ms"),
            "time_to_first_playing_sample_ms": agg_metric("time_to_first_playing_sample_ms"),
        },
        "observational_associations": {
            "pearson_r_video_edge_age_vs_first_playing_frame_age": (
                calc_pearson_r(v_edge, first_play) if all(x is not None for x in v_edge + first_play) else None
            ),
            "pearson_r_video_edge_age_vs_playing_median_after_5s": (
                calc_pearson_r(v_edge, steady_play) if all(x is not None for x in v_edge + steady_play) else None
            ),
            "pearson_r_audio_edge_age_vs_first_playing_frame_age": (
                calc_pearson_r(a_edge, first_play) if all(x is not None for x in a_edge + first_play) else None
            ),
            "pearson_r_audio_edge_age_vs_playing_median_after_5s": (
                calc_pearson_r(a_edge, steady_play) if all(x is not None for x in a_edge + steady_play) else None
            ),
        },
        "trials": trial_summaries,
    }

    return capture_health, playlists_records, summary


def run_analysis(
    results_dir: str,
    room_id: str,
    trials_meta: list[dict],
    *,
    run_id: str,
) -> dict:
    """
    Full post-capture analysis pipeline:
    1. Runs TShark two-pass PDML extraction on results/upstream.pcapng -> results/http.pdml
    2. Parses capture.stderr.log and http.pdml
    3. Correlates trials and writes results/capture-health.json, results/playlists.jsonl, results/summary.json
    """
    pcapng_path = os.path.join(results_dir, "upstream.pcapng")
    pdml_path = os.path.join(results_dir, "http.pdml")
    stderr_log_path = os.path.join(results_dir, "capture.stderr.log")

    extract_pdml_with_tshark(pcapng_path, pdml_path, stderr_log_path)

    stderr_text = ""
    if os.path.exists(stderr_log_path):
        with open(stderr_log_path, "r", encoding="utf-8", errors="replace") as f:
            stderr_text = f.read()
    stderr_health = parse_capture_stderr(stderr_text)

    pdml_data = parse_pdml_stream(pdml_path)
    capture_health, playlists_records, summary = correlate_trials(
        pdml_data=pdml_data,
        trials_meta=trials_meta,
        room_id=room_id,
        results_dir=results_dir,
        run_id=run_id,
        stderr_health=stderr_health,
    )

    with open(os.path.join(results_dir, "capture-health.json"), "w", encoding="utf-8") as f:
        json.dump(capture_health, f, indent=2)

    with open(os.path.join(results_dir, "playlists.jsonl"), "w", encoding="utf-8") as f:
        for rec in playlists_records:
            f.write(json.dumps(rec) + "\n")

    with open(os.path.join(results_dir, "summary.json"), "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)

    return summary


def main():
    parser = argparse.ArgumentParser(description="Analyze passive upstream HTTP/1.1 capture and Probe trials.")
    parser.add_argument("--results-dir", required=True, help="Path to results directory")
    parser.add_argument("--room-id", required=True, help="Room ID to correlate")
    parser.add_argument("--run-id", required=True, help="Run ID to scope media and runs")
    args = parser.parse_args()

    events_path = os.path.join(args.results_dir, "events.jsonl")
    trials_meta = []
    if os.path.exists(events_path):
        with open(events_path, "r", encoding="utf-8") as f:
            for line in f:
                if not line.strip():
                    continue
                ev = json.loads(line)
                if ev.get("event") == "trial_completed":
                    trials_meta.append(ev)
    trials_meta.sort(key=lambda x: int(x["trial_index"]))
    run_analysis(args.results_dir, args.room_id, trials_meta, run_id=args.run_id)


if __name__ == "__main__":
    main()
