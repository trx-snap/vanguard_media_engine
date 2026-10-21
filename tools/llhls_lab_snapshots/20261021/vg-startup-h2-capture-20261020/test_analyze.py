#!/usr/bin/env python3
"""
test_analyze.py - Offline unit tests and regressions for:
- Completed-segment/part non-double-counting and trailing published PART durations
- Successive PDT rounding tolerance (12 segments x 1.999s) vs 500ms inconsistency rejection
- Missing, discontinuous, and malformed PDT handling
- Waiting-sample exclusion vs valid playing samples
- Nonfatal -15410 ECN advisory retention without invalidation
- Atomic existing-results refusal without modification or cleanup
- Representation of absent capture drops as UNKNOWN and required statistics enforcement
- Unrelated traffic and normal teardown blocking reload cancellation handling
- Real TShark extraction on synthetic fixtures (split-response reassembly & chunked dechunking)
- Guaranteed cleanup of every owned resource even on prior failure
"""

import sys
sys.dont_write_bytecode = True

import io
import json
import os
import signal
import ssl
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch, MagicMock, mock_open

import analyze
import run


FIXTURES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")

SAMPLE_MASTER_M3U8 = (
    "#EXTM3U\n"
    "#EXT-X-VERSION:9\n"
    "#EXT-X-INDEPENDENT-SEGMENTS\n"
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="main",DEFAULT=YES,AUTOSELECT=YES,URI="a.m3u8"\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=3165000,CODECS="avc1.64001f,mp4a.40.2",RESOLUTION=720x1280,FRAME-RATE=30.000,AUDIO="aud"\n'
    "vhi.m3u8\n"
)

SAMPLE_VIDEO_M3U8 = (
    "#EXTM3U\n"
    "#EXT-X-VERSION:9\n"
    "#EXT-X-TARGETDURATION:1\n"
    "#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,HOLD-BACK=3.000,PART-HOLD-BACK=0.601,CAN-SKIP-UNTIL=6.000\n"
    "#EXT-X-PART-INF:PART-TARGET=0.200334\n"
    "#EXT-X-START:TIME-OFFSET=-1.200,PRECISE=YES\n"
    "#EXT-X-MEDIA-SEQUENCE:10\n"
    "#EXT-X-DISCONTINUITY-SEQUENCE:0\n"
    '#EXT-X-MAP:URI="/media/run_test/0/init.mp4"\n'
    "#EXT-X-PROGRAM-DATE-TIME:2026-10-20T16:00:00.000000Z\n"
    "#EXTINF:1.000000000,\n"
    "/media/run_test/0/10.m4s\n"
    "#EXT-X-PROGRAM-DATE-TIME:2026-10-20T16:00:01.000000Z\n"
    '#EXT-X-PART:DURATION=0.200000000,URI="/media/run_test/0/11.0.m4s",INDEPENDENT=YES\n'
    '#EXT-X-PART:DURATION=0.200000000,URI="/media/run_test/0/11.1.m4s"\n'
    '#EXT-X-PART:DURATION=0.200000000,URI="/media/run_test/0/11.2.m4s"\n'
    '#EXT-X-PART:DURATION=0.200000000,URI="/media/run_test/0/11.3.m4s"\n'
    '#EXT-X-PART:DURATION=0.200000000,URI="/media/run_test/0/11.4.m4s"\n'
    "#EXTINF:1.000000000,\n"
    "/media/run_test/0/11.m4s\n"
    "#EXT-X-PROGRAM-DATE-TIME:2026-10-20T16:00:02.000000Z\n"
    '#EXT-X-PART:DURATION=0.200000000,URI="/media/run_test/0/12.0.m4s",INDEPENDENT=YES\n'
    '#EXT-X-PART:DURATION=0.200000000,URI="/media/run_test/0/12.1.m4s"\n'
    '#EXT-X-PART:DURATION=0.200000000,URI="/media/run_test/0/12.2.m4s"\n'
    '#EXT-X-PRELOAD-HINT:TYPE=PART,URI="/media/run_test/0/12.3.m4s"\n'
)

SAMPLE_AUDIO_M3U8 = (
    "#EXTM3U\n"
    "#EXT-X-VERSION:9\n"
    "#EXT-X-TARGETDURATION:1\n"
    "#EXT-X-MEDIA-SEQUENCE:10\n"
    '#EXT-X-MAP:URI="/media/run_test/3/init.mp4"\n'
    "#EXT-X-PROGRAM-DATE-TIME:2026-10-20T16:00:00.000000Z\n"
    "#EXTINF:1.000000000,\n"
    "/media/run_test/3/10.m4s\n"
    "#EXT-X-PROGRAM-DATE-TIME:2026-10-20T16:00:01.000000Z\n"
    "#EXTINF:1.000000000,\n"
    "/media/run_test/3/11.m4s\n"
    "#EXT-X-PROGRAM-DATE-TIME:2026-10-20T16:00:02.000000Z\n"
    '#EXT-X-PART:DURATION=0.200000000,URI="/media/run_test/3/12.0.m4s",INDEPENDENT=YES\n'
    '#EXT-X-PART:DURATION=0.200000000,URI="/media/run_test/3/12.1.m4s"\n'
    '#EXT-X-PRELOAD-HINT:TYPE=PART,URI="/media/run_test/3/12.2.m4s"\n'
)


def _make_pdml_packet(
    frame_num: int,
    time_epoch: float,
    tcp_stream: int,
    http_fields: list[tuple[str, str, str]],
    frame_len: int = 500,
    cap_len: int = 500,
    tcp_anomalies: list[str] | None = None,
) -> str:
    def xml_esc(s: str) -> str:
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")

    tcp_extra = ""
    for anom in tcp_anomalies or []:
        tcp_extra += f'<field name="{xml_esc(anom)}" show="1"/>'
    http_xml = ""
    for fname, fshow, fval in http_fields:
        val_attr = f' value="{xml_esc(fval)}"' if fval else ""
        http_xml += f'<field name="{xml_esc(fname)}" show="{xml_esc(fshow)}"{val_attr}/>'
    return (
        f'<packet>'
        f'<proto name="frame">'
        f'<field name="frame.number" show="{frame_num}"/>'
        f'<field name="frame.time_epoch" show="{time_epoch:.6f}"/>'
        f'<field name="frame.len" show="{frame_len}"/>'
        f'<field name="frame.cap_len" show="{cap_len}"/>'
        f'</proto>'
        f'<proto name="tcp">'
        f'<field name="tcp.stream" show="{tcp_stream}"/>'
        f'{tcp_extra}'
        f'</proto>'
        f'<proto name="http">{http_xml}</proto>'
        f'</packet>'
    )


class TestAnalyzeOffline(unittest.TestCase):
    def test_completed_segment_part_no_double_counting_and_trailing_parts(self):
        base_epoch = analyze.parse_iso8601_utc("2026-10-20T16:00:00.000000Z")
        resp_epoch = base_epoch + 2.750
        res = analyze.parse_playlist_edge(SAMPLE_VIDEO_M3U8, response_epoch_s=resp_epoch)

        self.assertTrue(res["valid_edge"])
        self.assertEqual(res["reason"], "ok")
        self.assertEqual(res["completed_segments_count"], 2)
        self.assertAlmostEqual(res["completed_extinf_s"], 2.0, places=6)
        self.assertEqual(res["completed_segment_parts_superseded"], 5)
        self.assertEqual(res["trailing_parts_count"], 3)
        self.assertAlmostEqual(res["trailing_parts_s"], 0.6, places=6)
        self.assertEqual(res["preload_hints_ignored"], 1)
        self.assertEqual(res["advertised_edge_utc"], "2026-10-20T16:00:02.600000Z")
        self.assertAlmostEqual(res["edge_age_at_response_ms"], 150.0, places=3)

    def test_successive_pdt_rounding_tolerance_and_genuine_inconsistency_rejection(self):
        # 12 segments with 2-second PDT increments and EXTINF 1.999 must NOT fail solely through cumulative rounding
        lines_12 = ["#EXTM3U", "#EXT-X-VERSION:9", "#EXT-X-TARGETDURATION:2", "#EXT-X-MEDIA-SEQUENCE:1"]
        base_t = analyze.parse_iso8601_utc("2026-10-20T16:00:00.000000Z")
        for i in range(12):
            seg_pdt_epoch = base_t + (i * 2.0)
            lines_12.append(f"#EXT-X-PROGRAM-DATE-TIME:{analyze.format_utc_iso(seg_pdt_epoch)}")
            lines_12.append("#EXTINF:1.999000000,")
            lines_12.append(f"/media/run_test/0/{i+1}.m4s")

        res_12 = analyze.parse_playlist_edge("\n".join(lines_12) + "\n")
        self.assertTrue(res_12["valid_edge"])
        self.assertEqual(res_12["completed_segments_count"], 12)
        # Final edge should be based on 12th segment's explicit PDT + 1.999s = base + 22.0s + 1.999s = 23.999s
        expected_edge = analyze.format_utc_iso(base_t + 23.999)
        self.assertEqual(res_12["advertised_edge_utc"], expected_edge)

        # Genuine 500ms inconsistency must still be rejected
        lines_bad = [
            "#EXTM3U",
            "#EXT-X-VERSION:9",
            "#EXT-X-TARGETDURATION:2",
            "#EXT-X-PROGRAM-DATE-TIME:2026-10-20T16:00:00.000000Z",
            "#EXTINF:2.000000000,",
            "/media/run_test/0/1.m4s",
            # Next segment is 2.500s later, not 2.000s (500ms jump)
            "#EXT-X-PROGRAM-DATE-TIME:2026-10-20T16:00:02.500000Z",
            "#EXTINF:2.000000000,",
            "/media/run_test/0/2.m4s",
        ]
        res_bad = analyze.parse_playlist_edge("\n".join(lines_bad) + "\n")
        self.assertFalse(res_bad["valid_edge"])
        self.assertEqual(res_bad["reason"], "inconsistent_adjacent_pdt")

    def test_missing_and_ambiguous_pdt_handling(self):
        no_pdt = (
            "#EXTM3U\n"
            "#EXT-X-VERSION:9\n"
            "#EXTINF:1.000,\n"
            "/media/run_test/0/10.m4s\n"
        )
        r1 = analyze.parse_playlist_edge(no_pdt)
        self.assertFalse(r1["valid_edge"])
        self.assertEqual(r1["reason"], "missing_pdt")

        unanchored_disc = (
            "#EXTM3U\n"
            "#EXT-X-PROGRAM-DATE-TIME:2026-10-20T16:00:00.000000Z\n"
            "#EXTINF:1.000,\n"
            "/media/run_test/0/10.m4s\n"
            "#EXT-X-DISCONTINUITY\n"
            '#EXT-X-PART:DURATION=0.200,URI="/media/run_test/0/1.0.m4s"\n'
        )
        r2 = analyze.parse_playlist_edge(unanchored_disc)
        self.assertFalse(r2["valid_edge"])
        self.assertEqual(r2["reason"], "discontinuity_without_pdt")

    def test_waiting_sample_exclusion_and_playing_metrics(self):
        records = [
            {
                "utc": "2026-10-20T16:00:03.000Z",
                "observation_mono_ms": 1000,
                "startup_elapsed_ms": 420,
                "valid": True,
                "time_control_status": "waiting",
                "effective_timebase_rate": 0.0,
                "age_ms": 2010,
                "item_date_age_ms": 1990.0,
            },
            {
                "utc": "2026-10-20T16:00:03.260Z",
                "observation_mono_ms": 1260,
                "startup_elapsed_ms": 420,
                "valid": True,
                "time_control_status": "playing",
                "effective_timebase_rate": 1.0,
                "age_ms": 1747,
                "item_date_age_ms": 1730.0,
            },
            {
                "utc": "2026-10-20T16:00:08.500Z",
                "observation_mono_ms": 6500,
                "startup_elapsed_ms": 420,
                "valid": True,
                "time_control_status": "playing",
                "effective_timebase_rate": 1.0,
                "age_ms": 1720,
                "item_date_age_ms": 1710.0,
            },
            {
                "teardown": True,
                "first_valid_frame": True,
                "startup_elapsed_ms": 420,
                "failure_count": 0,
                "native_error_log_events": [],
            },
        ]
        jsonl_content = "\n".join(json.dumps(r) for r in records) + "\n"

        with patch("os.path.exists", return_value=True), patch(
            "builtins.open", return_value=io.StringIO(jsonl_content)
        ):
            info = analyze.parse_probe_jsonl("/virtual/trial_01/probe.jsonl")

        self.assertTrue(info["teardown_present"])
        self.assertEqual(info["waiting_valid_samples_excluded"], 1)
        self.assertEqual(info["first_decoded_frame_age_ms"], 2010.0)
        self.assertEqual(info["first_playing_frame_age_ms"], 1747.0)
        self.assertEqual(info["time_to_first_decoded_frame_ms"], 420.0)
        self.assertEqual(info["time_to_first_playing_sample_ms"], 680.0)

    def test_nonfatal_ecn_advisory_retained_without_invalidation(self):
        records = [
            {
                "utc": "2026-10-20T16:00:03.260Z",
                "observation_mono_ms": 1260,
                "startup_elapsed_ms": 420,
                "valid": True,
                "time_control_status": "playing",
                "effective_timebase_rate": 1.0,
                "age_ms": 1747,
            },
            {
                "teardown": True,
                "first_valid_frame": True,
                "startup_elapsed_ms": 420,
                "failure_count": 0,
                "native_error_log_events": [
                    {"domain": "CoreMediaErrorDomain", "status": -15410, "comment": "Server should support ECN for Low Latency"}
                ],
            },
        ]
        jsonl_content = "\n".join(json.dumps(r) for r in records) + "\n"

        with patch("os.path.exists", return_value=True), patch(
            "builtins.open", return_value=io.StringIO(jsonl_content)
        ):
            info = analyze.parse_probe_jsonl("/virtual/trial_01/probe.jsonl")

        self.assertEqual(len(info["native_error_log_events"]), 1)
        self.assertEqual(len(info["fatal_native_errors"]), 0)
        self.assertEqual(len(info["ecn_advisories"]), 1)

    def test_fatal_error_mentioning_ecn_is_not_whitelisted(self):
        records = [
            {
                "utc": "2026-10-20T16:00:03.260Z",
                "observation_mono_ms": 1260,
                "startup_elapsed_ms": 420,
                "valid": True,
                "time_control_status": "playing",
                "effective_timebase_rate": 1.0,
                "age_ms": 1747,
            },
            {
                "teardown": True,
                "first_valid_frame": True,
                "startup_elapsed_ms": 420,
                "failure_count": 0,
                "native_error_log_events": [
                    {"domain": "NSURLErrorDomain", "status": -1005, "comment": "ECN handshake connection lost"}
                ],
            },
        ]
        jsonl_content = "\n".join(json.dumps(r) for r in records) + "\n"

        with patch("os.path.exists", return_value=True), patch(
            "builtins.open", return_value=io.StringIO(jsonl_content)
        ):
            info = analyze.parse_probe_jsonl("/virtual/trial_01/probe.jsonl")

        self.assertEqual(len(info["native_error_log_events"]), 1)
        self.assertEqual(len(info["fatal_native_errors"]), 1)
        self.assertEqual(len(info["ecn_advisories"]), 0)

    def test_existing_results_directory_refusal(self):
        harness = run.H2CaptureHarness(nonce=12345)
        with patch("os.path.exists", return_value=True):
            with self.assertRaises(RuntimeError) as ctx:
                harness.acquire_results_directory()
            self.assertIn("BLOCKED: Results directory already exists", str(ctx.exception))
        self.assertFalse(harness.results_acquired)

        # Verify cleanup does not modify or touch filesystem when results were not acquired
        with patch("builtins.open") as mock_open:
            harness.cleanup()
            mock_open.assert_not_called()

    def test_unknown_capture_drop_statistics(self):
        stderr_no_stats = "dumpcap: listening on lo0\n"
        health = analyze.parse_capture_stderr(stderr_no_stats)
        self.assertEqual(health["capture_drops"], "UNKNOWN")
        self.assertFalse(health["has_drop_stats"])

    def test_unrelated_traffic_and_teardown_cancellation_do_not_contaminate(self):
        room = "room_h2cap_99"
        run_id = "vg_h2cap_99"
        t0 = analyze.parse_iso8601_utc("2026-10-20T16:00:00.000000Z")
        master_hex = SAMPLE_MASTER_M3U8.encode("utf-8").hex()
        video_hex = SAMPLE_VIDEO_M3U8.encode("utf-8").hex()
        audio_hex = SAMPLE_AUDIO_M3U8.encode("utf-8").hex()

        pdml_xml = (
            "<pdml>"
            # Unrelated room traffic (should not contaminate or invalidate)
            + _make_pdml_packet(
                1, t0 + 0.5, 0,
                [
                    ("http.request", "1", ""),
                    ("http.request.method", "GET", ""),
                    ("http.request.uri", "/live/unrelated_room/master.m3u8", ""),
                    ("http.user_agent", "AppleCoreMedia/1.0", ""),
                ],
            )
            # Startup exchanges for trial 1
            + _make_pdml_packet(
                2, t0 + 2.65, 1,
                [
                    ("http.request", "1", ""),
                    ("http.request.method", "GET", ""),
                    ("http.request.uri", f"/live/{room}/master.m3u8", ""),
                    ("http.user_agent", "AppleCoreMedia/1.0", ""),
                    ("http.response_in", "3", ""),
                ],
            )
            + _make_pdml_packet(
                3, t0 + 2.66, 1,
                [
                    ("http.response", "1", ""),
                    ("http.response.code", "200", ""),
                    ("http.request_in", "2", ""),
                    ("http.file_data", "", master_hex),
                ],
            )
            + _make_pdml_packet(
                4, t0 + 2.70, 2,
                [
                    ("http.request", "1", ""),
                    ("http.request.method", "GET", ""),
                    ("http.request.uri", f"/live/{room}/vhi.m3u8", ""),
                    ("http.user_agent", "AppleCoreMedia/1.0", ""),
                    ("http.response_in", "5", ""),
                ],
            )
            + _make_pdml_packet(
                5, t0 + 2.75, 2,
                [
                    ("http.response", "1", ""),
                    ("http.response.code", "200", ""),
                    ("http.request_in", "4", ""),
                    ("http.file_data", "", video_hex),
                ],
            )
            + _make_pdml_packet(
                6, t0 + 2.71, 3,
                [
                    ("http.request", "1", ""),
                    ("http.request.method", "GET", ""),
                    ("http.request.uri", f"/live/{room}/a.m3u8", ""),
                    ("http.user_agent", "AppleCoreMedia/1.0", ""),
                    ("http.response_in", "7", ""),
                ],
            )
            + _make_pdml_packet(
                7, t0 + 2.76, 3,
                [
                    ("http.response", "1", ""),
                    ("http.response.code", "200", ""),
                    ("http.request_in", "6", ""),
                    ("http.file_data", "", audio_hex),
                ],
            )
            # Normal teardown cancelled blocking reload (holding open until probe killed at 15s)
            + _make_pdml_packet(
                8, t0 + 17.5, 4,
                [
                    ("http.request", "1", ""),
                    ("http.request.method", "GET", ""),
                    ("http.request.uri", f"/live/{room}/vhi.m3u8?_HLS_msn=12&_HLS_part=3", ""),
                    ("http.user_agent", "AppleCoreMedia/1.0", ""),
                ],
            )
            + "</pdml>"
        )

        pdml_data = analyze.parse_pdml_stream(pdml_xml)
        trials_meta = [
            {
                "trial_index": 1,
                "trial_id": "trial_01",
                "pre_delay_target_s": 0.073,
                "launch_utc": "2026-10-20T16:00:02.600000Z",
                "launch_epoch_s": t0 + 2.60,
                "launch_mono_ms": 1000,
                "end_utc": "2026-10-20T16:00:18.000000Z",
                "end_epoch_s": t0 + 18.00,
                "end_mono_ms": 16400,
                "exit_code": 0,
                "capture_active_before": True,
                "capture_active_after": True,
            }
        ]
        access_log_text = (
            f'2026-10-20T17:00:02+01:00 client=192.168.0.136 protocol=HTTP/2.0 http3=- ssl_proto=TLSv1.3 ssl_cipher=AEAD method=GET uri="/live/{room}/master.m3u8" status=200 bytes=270 request_time=0.001 ua="AppleCoreMedia/1.0"\n'
            f'2026-10-20T17:00:02+01:00 client=192.168.0.136 protocol=HTTP/2.0 http3=- ssl_proto=TLSv1.3 ssl_cipher=AEAD method=GET uri="/live/{room}/vhi.m3u8" status=200 bytes=1206 request_time=0.001 ua="AppleCoreMedia/1.0"\n'
            f'2026-10-20T17:00:02+01:00 client=192.168.0.136 protocol=HTTP/2.0 http3=- ssl_proto=TLSv1.3 ssl_cipher=AEAD method=GET uri="/live/{room}/a.m3u8" status=200 bytes=580 request_time=0.001 ua="AppleCoreMedia/1.0"\n'
            f'2026-10-20T17:00:02+01:00 client=192.168.0.136 protocol=HTTP/2.0 http3=- ssl_proto=TLSv1.3 ssl_cipher=AEAD method=GET uri="/media/{run_id}/0/12.0.m4s" status=200 bytes=40000 request_time=0.002 ua="AppleCoreMedia/1.0"\n'
        )
        probe_jsonl_text = (
            json.dumps({
                "utc": "2026-10-20T16:00:03.000Z",
                "observation_mono_ms": 1400,
                "startup_elapsed_ms": 400,
                "valid": True,
                "time_control_status": "playing",
                "effective_timebase_rate": 1.0,
                "age_ms": 1750,
            }) + "\n" +
            json.dumps({
                "utc": "2026-10-20T16:00:09.000Z",
                "observation_mono_ms": 7000,
                "startup_elapsed_ms": 400,
                "valid": True,
                "time_control_status": "playing",
                "effective_timebase_rate": 1.0,
                "age_ms": 1740,
            }) + "\n" +
            json.dumps({
                "teardown": True,
                "first_valid_frame": True,
                "startup_elapsed_ms": 400,
                "failure_count": 0,
                "native_error_log_events": [],
            }) + "\n"
        )

        def fake_open(path, *args, **kwargs):
            if path.endswith("access.log"):
                return io.StringIO(access_log_text)
            if path.endswith("probe.jsonl"):
                return io.StringIO(probe_jsonl_text)
            raise FileNotFoundError(path)

        stderr_health = {
            "capture_drops": 0,
            "has_drop_stats": True,
            "capture_truncated_warnings": 0,
            "raw_drop_lines": ["Packets received/dropped on interface 'lo0': 500/0"],
        }

        with patch("os.path.exists", return_value=True), patch("builtins.open", side_effect=fake_open):
            health, playlists, summary = analyze.correlate_trials(
                pdml_data=pdml_data,
                trials_meta=trials_meta,
                room_id=room,
                results_dir="/virtual/results",
                run_id=run_id,
                stderr_health=stderr_health,
            )

        self.assertTrue(health["healthy"])
        self.assertEqual(len(health["unrelated_traffic"]), 1)
        self.assertEqual(len(health["teardown_cancelled_blocking_reloads"]), 1)
        self.assertEqual(summary["valid_trials_count"], 1)

    def test_split_response_reassembly_from_real_tshark_fixture(self):
        seg_pdml_path = os.path.join(FIXTURES_DIR, "segmented.pdml")
        self.assertTrue(os.path.exists(seg_pdml_path), "Missing fixtures/segmented.pdml")

        pdml_data = analyze.parse_pdml_stream(seg_pdml_path)
        self.assertEqual(len(pdml_data["pairs"]), 1)
        pair = pdml_data["pairs"][0]
        self.assertEqual(pair["path"], "/live/room_test/vhi.m3u8")
        self.assertEqual(pair["status_code"], 200)
        self.assertTrue(pair["complete"], f"Incomplete reasons: {pair['incomplete_reasons']}")
        self.assertIn("#EXTM3U", pair["body_text"])
        self.assertIn("/media/run_test/0/2.0.m4s", pair["body_text"])

    def test_chunked_body_extraction_from_real_tshark_fixture(self):
        chk_pdml_path = os.path.join(FIXTURES_DIR, "chunked.pdml")
        self.assertTrue(os.path.exists(chk_pdml_path), "Missing fixtures/chunked.pdml")

        pdml_data = analyze.parse_pdml_stream(chk_pdml_path)
        self.assertEqual(len(pdml_data["pairs"]), 1)
        pair = pdml_data["pairs"][0]
        self.assertEqual(pair["path"], "/live/room_test/a.m3u8")
        self.assertEqual(pair["status_code"], 200)
        self.assertTrue(pair["complete"], f"Incomplete reasons: {pair['incomplete_reasons']}")
        self.assertIn("#EXTM3U", pair["body_text"])
        self.assertIn("/media/run_test/3/1.m4s", pair["body_text"])

    def test_cleanup_attempts_every_owned_resource(self):
        harness = run.H2CaptureHarness(nonce=99999)
        harness.results_acquired = True

        mock_probe = MagicMock()
        mock_probe.poll.return_value = None
        mock_probe.terminate.side_effect = RuntimeError("probe terminate error")
        mock_probe.pid = 1111
        harness.probe_proc = mock_probe

        mock_nginx = MagicMock()
        mock_nginx.poll.return_value = None
        mock_nginx.pid = 2222
        harness.nginx_proc = mock_nginx

        mock_pub = MagicMock()
        mock_pub.poll.return_value = None
        mock_pub.pid = 3333
        harness.publisher_proc = mock_pub

        mock_lk = MagicMock()
        mock_lk.poll.return_value = None
        mock_lk.pid = 4444
        harness.lk_proc = mock_lk

        with patch("builtins.open", side_effect=lambda *args, **kwargs: io.StringIO()):
            harness.cleanup()

        # Verify that despite probe error, nginx, publisher, and lk terminate were still attempted
        mock_nginx.terminate.assert_called_once()
        mock_pub.terminate.assert_called_once()
        mock_lk.terminate.assert_called_once()
        self.assertFalse(harness.cleanup_success)
        self.assertTrue(harness.cleanup_completed)

    def test_historical_trial_2_h2_access_log_replay(self):
        hist_log_path = "/private/tmp/vg-startup-auto-20261020-1338/results/trial_2_H2_access.log"
        self.assertTrue(os.path.exists(hist_log_path), f"Missing historical log: {hist_log_path}")

        end_epoch = analyze.parse_iso8601_utc("2026-10-20T13:48:34+01:00")
        res = analyze.parse_access_log_slice(
            hist_log_path,
            "vg_auto_4294014020",
            run_id="vg_auto_4294014020",
            trial_launch_epoch_s=analyze.parse_iso8601_utc("2026-10-20T13:48:09+01:00"),
            trial_end_epoch_s=end_epoch,
        )

        self.assertTrue(res["exists"])
        self.assertEqual(len(res["exchanges"]), 344)
        status_200_count = sum(1 for e in res["exchanges"] if e["status"] == 200)
        self.assertEqual(status_200_count, 340)
        status_499_count = sum(1 for e in res["exchanges"] if e["status"] == 499)
        self.assertEqual(status_499_count, 4)

        self.assertTrue(res["has_nonzero_transfers"])
        self.assertGreater(res["total_bytes"], 0)
        self.assertEqual(res["non_h2_protocols"], [])

        # Teardown classification
        self.assertEqual(len(res["teardown_cancellations"]), 4)
        self.assertEqual(len(res["startup_failures"]), 0)

        # Without trial_end_epoch_s, non-200 responses are NOT blanket-ignored:
        res_no_end = analyze.parse_access_log_slice(
            hist_log_path,
            "vg_auto_4294014020",
            run_id="vg_auto_4294014020",
        )
        self.assertEqual(len(res_no_end["startup_failures"]), 4)

    def test_initial_playlist_matching_and_ambiguity_rejection(self):
        hist_log_path = "/private/tmp/vg-startup-auto-20261020-1338/results/trial_2_H2_access.log"
        launch_epoch = analyze.parse_iso8601_utc("2026-10-20T13:48:09+01:00")
        ua = "AppleCoreMedia/1.0.0.25F71 (Macintosh; U; Intel Mac OS X 26_5; en_gb)"
        res = analyze.parse_access_log_slice(
            hist_log_path,
            "vg_auto_4294014020",
            run_id="vg_auto_4294014020",
            trial_launch_epoch_s=launch_epoch,
            trial_end_epoch_s=launch_epoch + 25.0,
        )

        # Unambiguous master playlist match (single initial request)
        m_res = analyze.match_initial_playlist_exchange(
            res["exchanges"],
            expected_uri="/live/vg_auto_4294014020/master.m3u8",
            expected_user_agent=ua,
            expected_bytes=466,
            trial_launch_epoch_s=launch_epoch,
        )
        self.assertTrue(m_res["matched"])
        self.assertEqual(m_res["status"], "matched")
        self.assertEqual(m_res["exchange"]["uri"], "/live/vg_auto_4294014020/master.m3u8")

        # In historical trial_2, AVPlayer issued two vhi.m3u8 requests without query at 13:48:09:
        # Both share the same size (9521 bytes); ambiguous matches must be classified as ambiguous!
        v_res = analyze.match_initial_playlist_exchange(
            res["exchanges"],
            expected_uri="/live/vg_auto_4294014020/vhi.m3u8",
            expected_user_agent=ua,
            expected_bytes=9521,
            trial_launch_epoch_s=launch_epoch,
        )
        self.assertFalse(v_res["matched"])
        self.assertEqual(v_res["status"], "ambiguous")
        self.assertEqual(v_res["candidates_count"], 2)

    def test_transient_canary_checks_do_not_pollute_capture_drop_statistics(self):
        stderr_with_transient = (
            "[2026-10-20T16:00:00.000000Z] Prompted operator for capture\n"
            "[2026-10-20T16:00:01.000000Z] Transient pcapng write tail during canary check: cut short in the middle of a packet\n"
            "[2026-10-20T16:00:02.000000Z] Transient live check warning: less than expected header size\n"
            "Packets received/dropped on interface 'lo0': 500/0\n"
        )
        health = analyze.parse_capture_stderr(stderr_with_transient)
        self.assertEqual(health["capture_drops"], 0)
        self.assertTrue(health["has_drop_stats"])
        self.assertEqual(health["capture_truncated_warnings"], 0)

    def test_cleanup_signal_safety_and_probe_retention(self):
        harness = run.H2CaptureHarness(nonce=88888)
        self.assertFalse(harness.cleanup_in_progress)
        self.assertFalse(harness.cleanup_completed)

        harness.results_acquired = True
        with patch("builtins.open", side_effect=lambda *args, **kwargs: io.StringIO()):
            harness.cleanup()

        self.assertFalse(harness.cleanup_in_progress)
        self.assertTrue(harness.cleanup_completed)

        # Re-entrant call must return immediately without exception
        harness.cleanup()
        self.assertTrue(harness.cleanup_completed)

    def test_sigint_during_cleanup_in_isolated_child(self):
        """
        Regresses run.py:899-907: actual SIGINT arriving during cleanup in a
        deadline-bounded isolated child must not deadlock or reenter cleanup.
        """
        child_code = (
            "import sys\n"
            "sys.path.insert(0, '/private/tmp/vg-startup-h2-capture-20261020')\n"
            "import os, signal, time, run\n"
            "from unittest.mock import patch, MagicMock, mock_open\n"
            "harness = run.H2CaptureHarness(nonce=77777)\n"
            "harness.results_acquired = True\n"
            "def sigint_during_probe(*args, **kwargs):\n"
            "    os.kill(os.getpid(), signal.SIGINT)\n"
            "    time.sleep(0.05)\n"
            "mock_probe = MagicMock()\n"
            "mock_probe.poll.return_value = None\n"
            "mock_probe.terminate.side_effect = sigint_during_probe\n"
            "harness.probe_proc = mock_probe\n"
            "def handle_signal(sig, _frame):\n"
            "    if harness.cancelled_signal is None:\n"
            "        harness.cancelled_signal = sig\n"
            "signal.signal(signal.SIGINT, handle_signal)\n"
            "try:\n"
            "    with patch('builtins.open', mock_open()):\n"
            "        harness.cleanup()\n"
            "finally:\n"
            "    if harness.cancelled_signal is not None:\n"
            "        sys.exit(1)\n"
            "sys.exit(0)\n"
        )
        proc = subprocess.run(
            [sys.executable, "-B", "-c", child_code],
            capture_output=True,
            text=True,
            timeout=5,
            env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1"),
        )
        self.assertEqual(proc.returncode, 1)

    def test_cancellation_during_probe_waiting(self):
        """
        Regresses run.py cancellation during Probe waiting polled at <=250ms.
        """
        harness = run.H2CaptureHarness(nonce=66666)
        harness.results_acquired = True

        mock_proc = MagicMock()
        mock_proc.pid = 54321
        mock_proc.poll.return_value = None

        def poll_side_effect(timeout=None):
            # Simulate cancellation arriving during wait
            harness.cancelled_signal = signal.SIGINT
            raise subprocess.TimeoutExpired(cmd="probe", timeout=timeout)

        mock_proc.wait.side_effect = poll_side_effect

        def terminate_side_effect():
            mock_proc.poll.return_value = 0
            mock_proc.wait.side_effect = None
            mock_proc.wait.return_value = 0

        mock_proc.terminate.side_effect = terminate_side_effect

        with tempfile.TemporaryDirectory() as tmp_dir:
            with patch("run.NEW_RESULTS_DIR", tmp_dir), patch("run.is_capture_active", return_value=True), patch(
                "subprocess.Popen", return_value=mock_proc
            ), patch("builtins.open", mock_open()), patch("time.sleep"):
                # Calling run_h2_trials should raise HarnessCancelledError promptly
                with self.assertRaises(run.HarnessCancelledError):
                    harness.run_h2_trials()

        # In finally, terminate must have been attempted on probe
        mock_proc.terminate.assert_called()

    def test_failed_reaping_retention(self):
        """
        Regresses run.py:637-648: failed terminate/kill/wait must retain probe ownership
        and record failure so cleanup retries and marks failure.
        """
        harness = run.H2CaptureHarness(nonce=55555)
        harness.results_acquired = True

        mock_proc = MagicMock()
        mock_proc.pid = 9876
        # Process never exits
        mock_proc.poll.return_value = None

        def poll_side_effect(timeout=None):
            harness.cancelled_signal = signal.SIGTERM
            raise subprocess.TimeoutExpired(cmd="probe", timeout=timeout)

        mock_proc.wait.side_effect = poll_side_effect

        with tempfile.TemporaryDirectory() as tmp_dir:
            with patch("run.NEW_RESULTS_DIR", tmp_dir), patch("run.is_capture_active", return_value=True), patch(
                "subprocess.Popen", return_value=mock_proc
            ), patch("builtins.open", mock_open()), patch("time.sleep"):
                with self.assertRaises(RuntimeError) as ctx:
                    harness.run_h2_trials()
                self.assertIn("unconfirmed reaping", str(ctx.exception))

            # Probe ownership MUST be retained because reaping was not confirmed
            self.assertIs(harness.probe_proc, mock_proc)

            # Cleanup attempts to stop probe; failing to reap must report cleanup failure
            with patch("builtins.open", mock_open()):
                harness.cleanup()

        self.assertFalse(harness.cleanup_success)
        self.assertTrue(harness.cleanup_completed)

    def test_probe_reap_failure_without_cancellation_aborts_and_retries_cleanup(self):
        """
        Regresses run.py unconfirmed Probe reaping without cancellation:
        Simulate 50s timeout and failed kill/wait/terminate, assert exactly one Probe launch,
        retained original handle, immediate RuntimeError exception, and cleanup retry.
        Mock time and processes without waiting 50 seconds.
        """
        harness = run.H2CaptureHarness(nonce=33333)
        harness.results_acquired = True
        self.assertIsNone(harness.cancelled_signal)

        mock_proc = MagicMock()
        mock_proc.pid = 43210
        mock_proc.poll.return_value = None  # Never reaped
        mock_proc.wait.side_effect = subprocess.TimeoutExpired(cmd="probe", timeout=2)

        # Mock time.monotonic to advance by 30s per call, triggering 50s timeout without real sleeping
        current_mono = 100.0
        def fake_monotonic():
            nonlocal current_mono
            val = current_mono
            current_mono += 30.0
            return val

        mock_popen = MagicMock(return_value=mock_proc)

        with tempfile.TemporaryDirectory() as tmp_dir:
            with patch("run.NEW_RESULTS_DIR", tmp_dir), patch("run.is_capture_active", return_value=True), patch(
                "subprocess.Popen", mock_popen
            ), patch("builtins.open", mock_open()), patch("time.sleep"), patch("time.monotonic", side_effect=fake_monotonic):
                with self.assertRaises(RuntimeError) as ctx:
                    harness.run_h2_trials()
                self.assertIn("unconfirmed reaping", str(ctx.exception))

            # Exactly one Probe launch (trials loop aborted, did not launch trial_02..12)
            mock_popen.assert_called_once()

            # Retained original handle
            self.assertIs(harness.probe_proc, mock_proc)

            # Cleanup retry
            with patch("builtins.open", mock_open()):
                harness.cleanup()

            # Cleanup attempted terminate on probe
            mock_proc.terminate.assert_called()
            # Reported as cleanup failure due to unconfirmed reaping
            self.assertFalse(harness.cleanup_success)
            self.assertTrue(harness.cleanup_completed)

    def test_start_h2_nginx_uses_frozen_conf_without_regeneration(self):
        """
        Regresses run.py:start_h2_nginx: assert exact configuration argument, retained
        process ownership, 5s bind-readiness bound, early exit check, and no configuration
        write or generator call.
        """
        harness = run.H2CaptureHarness(nonce=22222)
        harness.results_acquired = True

        mock_nginx = MagicMock()
        mock_nginx.pid = 8888
        mock_nginx.poll.return_value = None

        mock_popen = MagicMock(return_value=mock_nginx)

        # Mock generator on experiment module if it exists
        mock_gen = MagicMock()
        with patch.object(run.experiment, "generate_h2_nginx_conf", mock_gen, create=True), patch(
            "subprocess.Popen", mock_popen
        ), patch.object(run.experiment, "check_port_free", return_value=False), patch("time.sleep"):
            # Spy on builtins.open to verify NEW_NGINX_CONF is NEVER opened for writing
            real_open = open
            def guarded_open(file, mode="r", *args, **kwargs):
                if file == run.NEW_NGINX_CONF and any(m in mode for m in ("w", "a", "+", "x")):
                    raise AssertionError(f"Forbidden write to frozen configuration: {file}")
                return real_open(file, mode, *args, **kwargs)

            with patch("builtins.open", side_effect=guarded_open):
                harness.start_h2_nginx()

        # 1. Exact configuration argument
        mock_popen.assert_called_once_with(
            ["nginx", "-c", run.NEW_NGINX_CONF],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        # 2. Retained process ownership and PID
        self.assertIs(harness.nginx_proc, mock_nginx)
        self.assertEqual(harness.nginx_pid, 8888)

        # 3. Generator never called
        mock_gen.assert_not_called()

        # 4. Early process exit check
        mock_failed_nginx = MagicMock()
        mock_failed_nginx.pid = 9999
        mock_failed_nginx.poll.return_value = 1
        mock_failed_nginx.returncode = 1
        mock_failed_nginx.communicate.return_value = (b"", b"nginx: [emerg] bind() failed")

        with patch("subprocess.Popen", return_value=mock_failed_nginx), patch(
            "time.sleep"
        ):
            with self.assertRaises(RuntimeError) as ctx:
                harness.start_h2_nginx()
            self.assertIn("exited prematurely with code 1", str(ctx.exception))

    def test_exact_uri_query_ua_mismatches_and_ambiguity(self):
        """
        Regresses analyze.py:897 and 1444-1451: require captured initial URI including query
        and exact User-Agent in match_initial_playlist_exchange.
        """
        ex = {
            "protocol": "HTTP/2.0",
            "status": 200,
            "bytes": 500,
            "uri": "/live/room_test/master.m3u8",
            "ua": "AppleCoreMedia/1.0.0.25F71 (Macintosh; U; Intel Mac OS X 26_5; en_gb)",
            "time_epoch": 1000.0,
        }

        # 1. Exact match
        r1 = analyze.match_initial_playlist_exchange(
            [ex],
            expected_uri="/live/room_test/master.m3u8",
            expected_user_agent=ex["ua"],
            expected_bytes=500,
            expected_response_epoch_s=1000.2,
        )
        self.assertTrue(r1["matched"])
        self.assertEqual(r1["status"], "matched")

        # 2. Query mismatch (query present in request)
        ex_query = {**ex, "uri": "/live/room_test/master.m3u8?unexpected=1"}
        r2 = analyze.match_initial_playlist_exchange(
            [ex_query],
            expected_uri="/live/room_test/master.m3u8",
            expected_user_agent=ex["ua"],
            expected_bytes=500,
            expected_response_epoch_s=1000.2,
        )
        self.assertFalse(r2["matched"])
        self.assertEqual(r2["status"], "missing")

        # 3. Exact User-Agent mismatch
        ex_ua = {**ex, "ua": "AppleCoreMedia/1.0.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X)"}
        r3 = analyze.match_initial_playlist_exchange(
            [ex_ua],
            expected_uri=ex["uri"],
            expected_user_agent="AppleCoreMedia/1.0.0.25F71 (Macintosh; U; Intel Mac OS X 26_5; en_gb)",
            expected_bytes=500,
            expected_response_epoch_s=1000.2,
        )
        self.assertFalse(r3["matched"])
        self.assertEqual(r3["status"], "missing")

        # 4. Rendition category mismatch (no rendition fallback)
        ex_vmid = {**ex, "uri": "/live/room_test/vmid.m3u8"}
        r4 = analyze.match_initial_playlist_exchange(
            [ex_vmid],
            expected_uri="/live/room_test/vhi.m3u8",
            expected_user_agent=ex["ua"],
            expected_bytes=500,
            expected_response_epoch_s=1000.2,
        )
        self.assertFalse(r4["matched"])
        self.assertEqual(r4["status"], "missing")

        # 5. Multiple candidates remain ambiguous
        r5 = analyze.match_initial_playlist_exchange(
            [ex, ex],
            expected_uri=ex["uri"],
            expected_user_agent=ex["ua"],
            expected_bytes=500,
            expected_response_epoch_s=1000.2,
        )
        self.assertFalse(r5["matched"])
        self.assertEqual(r5["status"], "ambiguous")
        self.assertEqual(r5["candidates_count"], 2)

    def test_teardown_499_versus_nearby_404_zero_byte_failures(self):
        """
        Regresses analyze.py:841-844: teardown-consistent cancellation requires status 499
        AND zero bytes, GET, AppleCoreMedia, owned room/run, and timestamp within [floor(end)-1, floor(end)+1].
        Ordinary 404/zero-byte responses remain failures.
        """
        room = "test_room"
        run_id = "test_run"
        trial_end_epoch = analyze.parse_iso8601_utc("2026-10-20T17:00:15+01:00")
        log_content = (
            # 1. Teardown 499 playlist cancellation at trial end
            f'2026-10-20T17:00:15+01:00 client=127.0.0.1 protocol=HTTP/2.0 http3= ssl_proto=TLSv1.3 ssl_cipher=AEAD method=GET uri="/live/{room}/a.m3u8?_HLS_msn=10" status=499 bytes=0 request_time=0.2 ua="AppleCoreMedia/1.0"\n'
            # 2. Teardown 499 media cancellation at trial end
            f'2026-10-20T17:00:15+01:00 client=127.0.0.1 protocol=HTTP/2.0 http3= ssl_proto=TLSv1.3 ssl_cipher=AEAD method=GET uri="/media/{run_id}/0/10.0.m4s" status=499 bytes=0 request_time=0.2 ua="AppleCoreMedia/1.0"\n'
            # 3. 404 zero-byte error at trial end (must remain failure!)
            f'2026-10-20T17:00:15+01:00 client=127.0.0.1 protocol=HTTP/2.0 http3= ssl_proto=TLSv1.3 ssl_cipher=AEAD method=GET uri="/live/{room}/missing.m3u8" status=404 bytes=0 request_time=0.001 ua="AppleCoreMedia/1.0"\n'
            # 4. 499 non-zero bytes (must remain failure!)
            f'2026-10-20T17:00:15+01:00 client=127.0.0.1 protocol=HTTP/2.0 http3= ssl_proto=TLSv1.3 ssl_cipher=AEAD method=GET uri="/live/{room}/vhi.m3u8" status=499 bytes=100 request_time=0.2 ua="AppleCoreMedia/1.0"\n'
            # 5. 499 zero-bytes outside teardown window (must remain failure!)
            f'2026-10-20T17:00:05+01:00 client=127.0.0.1 protocol=HTTP/2.0 http3= ssl_proto=TLSv1.3 ssl_cipher=AEAD method=GET uri="/live/{room}/a.m3u8" status=499 bytes=0 request_time=0.2 ua="AppleCoreMedia/1.0"\n'
        )

        with patch("os.path.exists", return_value=True), patch("builtins.open", return_value=io.StringIO(log_content)):
            res = analyze.parse_access_log_slice(
                "/virtual/access.log",
                room_id=room,
                run_id=run_id,
                trial_end_epoch_s=trial_end_epoch,
            )

        self.assertEqual(len(res["teardown_cancellations"]), 2)
        self.assertEqual(len(res["teardown_cancellations_playlist"]), 1)
        self.assertEqual(len(res["teardown_cancellations_media"]), 1)
        # All 3 non-teardown cases (404/0B, 499/100B, 499/0B outside window) MUST be startup/in-run failures
        self.assertEqual(len(res["startup_failures"]), 3)

    def test_ca_mismatch_and_missing_rejection(self):
        """
        Regresses run.py:create_lab_ssl_context:
        Reject missing or SHA-256 mismatched CA certificate.
        """
        # 1. Missing CA file
        with patch("run.LAB_CA_PATH", "/tmp/nonexistent_ca_path_12345.crt"):
            with self.assertRaises(RuntimeError) as ctx:
                run.create_lab_ssl_context()
            self.assertIn("missing", str(ctx.exception).lower())

        # 2. Mismatched SHA-256
        with tempfile.NamedTemporaryFile(suffix=".crt") as tmp_ca:
            tmp_ca.write(b"bad cert content")
            tmp_ca.flush()
            with patch("run.LAB_CA_PATH", tmp_ca.name):
                with self.assertRaises(RuntimeError) as ctx:
                    run.create_lab_ssl_context()
                self.assertIn("mismatch", str(ctx.exception).lower())

    def test_lab_ssl_context_verification_and_strict_flag(self):
        """
        Regresses run.py:create_lab_ssl_context:
        Verify required CERT_REQUIRED, check_hostname=True, and clearing ONLY VERIFY_X509_STRICT.
        """
        ctx = run.create_lab_ssl_context()
        # 1. Required certificate and hostname verification
        self.assertEqual(ctx.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(ctx.check_hostname)

        # 2. Strict-flag-only adjustment
        if hasattr(ssl.VerifyFlags, "VERIFY_X509_STRICT"):
            self.assertEqual(ctx.verify_flags & ssl.VerifyFlags.VERIFY_X509_STRICT, 0)
            ref_ctx = ssl.create_default_context(cafile=run.LAB_CA_PATH)
            # Confirms NO OTHER flags were changed or cleared
            self.assertEqual(ctx.verify_flags, ref_ctx.verify_flags & ~ssl.VerifyFlags.VERIFY_X509_STRICT)

    def test_tls_failure_before_publisher_launch_and_cleanup(self):
        """
        Regresses run.py:verify_h2_tls_preflight and execute_experiment:
        Immediately after owned Nginx startup, before publishing media, HTTPS check against
        /__vg_tls_preflight__ occurs; HTTP 404 is success, other outcomes fail immediately.
        TLS failure aborts BEFORE publisher launch, and cleanup retains & cleans Nginx.
        """
        harness = run.H2CaptureHarness(nonce=77777)
        harness.results_acquired = True

        with tempfile.TemporaryDirectory() as tmp_dir:
            with patch("run.NEW_RESULTS_DIR", tmp_dir), patch("builtins.open", mock_open()):
                # Test 1: 404 counts as successful TLS verification
                mock_cm_404 = MagicMock()
                mock_cm_404.__enter__.return_value.status = 404
                with patch("urllib.request.urlopen", return_value=mock_cm_404), patch("run.create_lab_ssl_context"):
                    # Should not raise
                    harness.verify_h2_tls_preflight()

                # Test 2: HTTPError 404 also counts as successful TLS verification
                err_404 = urllib.error.HTTPError(
                    url="https://192.168.0.136:18445/__vg_tls_preflight__",
                    code=404,
                    msg="Not Found",
                    hdrs={},
                    fp=io.BytesIO(b""),
                )
                with patch("urllib.request.urlopen", side_effect=err_404), patch("run.create_lab_ssl_context"):
                    harness.verify_h2_tls_preflight()

                # Test 3: Other errors fail immediately with actual error
                err_500 = urllib.error.HTTPError(
                    url="https://192.168.0.136:18445/__vg_tls_preflight__",
                    code=500,
                    msg="Server Error",
                    hdrs={},
                    fp=io.BytesIO(b""),
                )
                with patch("urllib.request.urlopen", side_effect=err_500), patch("run.create_lab_ssl_context"):
                    with self.assertRaises(RuntimeError) as ctx:
                        harness.verify_h2_tls_preflight()
                    self.assertIn("500", str(ctx.exception))

        # Test 4: Sequence in execute_experiment: failure aborts BEFORE publisher launch
        harness2 = run.H2CaptureHarness(nonce=88888)
        publish_called = False
        def fake_publish():
            nonlocal publish_called
            publish_called = True

        tls_check_called = False
        def fake_preflight_fail():
            nonlocal tls_check_called
            tls_check_called = True
            raise RuntimeError("Simulated TLS handshake / cert error")

        mock_nginx = MagicMock()
        mock_nginx.poll.return_value = None

        with patch.object(harness2, "acquire_results_directory"), \
             patch.object(harness2, "verify_prerequisites"), \
             patch.object(harness2, "start_h2_nginx"), \
             patch.object(harness2, "verify_h2_tls_preflight", side_effect=fake_preflight_fail), \
             patch.object(harness2, "publish_media", side_effect=fake_publish), \
             patch.object(harness2, "cleanup") as mock_cleanup:

            harness2.nginx_proc = mock_nginx
            with self.assertRaises(RuntimeError) as ctx:
                harness2.execute_experiment()
            self.assertIn("Simulated TLS handshake", str(ctx.exception))

        self.assertTrue(tls_check_called)
        self.assertFalse(publish_called, "publish_media must NOT be called when TLS preflight fails")
        mock_cleanup.assert_called_once()

    def test_consistent_retry_paths_and_refusal(self):
        """
        Regresses retry04 paths and refusal:
        - NEW_RESULTS_DIR ends with results_retry04
        - NEW_NGINX_CONF ends with nginx-retry04.conf
        - OPERATOR_DUMPCAP_CMD references results_retry04
        - nginx-retry04.conf has consistent results_retry04 paths
        - Refuse existing results_retry04 directory without touching historical evidence
        """
        self.assertTrue(run.NEW_RESULTS_DIR.endswith("results_retry04"))
        self.assertTrue(run.NEW_NGINX_CONF.endswith("nginx-retry04.conf"))
        self.assertIn("results_retry04/upstream.pcapng", run.OPERATOR_DUMPCAP_CMD)
        self.assertIn("results_retry04/capture.stderr.log", run.OPERATOR_DUMPCAP_CMD)

        # Check nginx-retry04.conf on disk
        self.assertTrue(os.path.isfile(run.NEW_NGINX_CONF))
        with open(run.NEW_NGINX_CONF, "r", encoding="utf-8") as f:
            conf_lines = f.readlines()
        self.assertTrue(any("results_retry04/nginx.pid" in line for line in conf_lines))
        self.assertTrue(any("results_retry04/nginx_error.log" in line for line in conf_lines))
        self.assertTrue(any("results_retry04/nginx_access.log" in line for line in conf_lines))
        # Ensure no old results/, results_retry01/, results_retry02/, or results_retry03/ references remain in nginx-retry04.conf
        for line in conf_lines:
            if any(p in line for p in ("results/", "results_retry01/", "results_retry02/", "results_retry03/")):
                self.fail(f"Found stale results path in retry config: {line}")

        # Refusal of existing retry output
        harness = run.H2CaptureHarness(nonce=99999)
        with tempfile.TemporaryDirectory() as tmp_parent:
            fake_retry_dir = os.path.join(tmp_parent, "results_retry04")
            os.mkdir(fake_retry_dir)
            with patch("run.NEW_RESULTS_DIR", fake_retry_dir):
                with self.assertRaises(RuntimeError) as ctx:
                    harness.acquire_results_directory()
                self.assertIn("BLOCKED: Results directory already exists", str(ctx.exception))
                self.assertFalse(harness.results_acquired)

    def test_operator_capture_pipeline_command_boundaries(self):
        """
        Regresses run.py:OPERATOR_DUMPCAP_CMD:
        - Subshell with set -o pipefail.
        - Explicit root dumpcap: sudo -u root /opt/homebrew/bin/dumpcap.
        - Non-root tee: /usr/bin/tee writes upstream.pcapng as invoking user.
        - Dumpcap writes binary stream to stdout (-w -).
        - Separated stderr redirected to capture.stderr.log (never mixed into binary stream).
        - Preserves packet filter, 300s duration, and 200000kB bounds.
        - Rejects sudo on tee, root-shell wrapper, stderr mixing (2>&1), and group flags (-g).
        """
        cmd = run.OPERATOR_DUMPCAP_CMD
        self.assertIn("set -o pipefail", cmd)
        self.assertIn("sudo -u root /opt/homebrew/bin/dumpcap", cmd)
        self.assertIn("-i lo0", cmd)
        self.assertIn("-s 0", cmd)
        self.assertIn("-f 'tcp port 18080'", cmd)
        self.assertIn("-a duration:300", cmd)
        self.assertIn("-a filesize:200000", cmd)
        self.assertIn("-w -", cmd)
        self.assertIn("2>> /private/tmp/vg-startup-h2-capture-20261020/results_retry04/capture.stderr.log", cmd)
        self.assertIn("| /usr/bin/tee /private/tmp/vg-startup-h2-capture-20261020/results_retry04/upstream.pcapng > /dev/null", cmd)

        # Boundary negatives
        self.assertNotIn("sudo /usr/bin/tee", cmd)
        self.assertNotIn("sudo tee", cmd)
        self.assertNotIn("2>&1", cmd)
        self.assertNotIn("-g", cmd)
        self.assertNotIn("staff", cmd)

    def test_tee_pipeline_invoking_user_ownership_readability_and_pid_detection(self):
        """
        Real OFFLINE TemporaryDirectory proof test:
        - Feeds existing segmented.pcapng bytes through /usr/bin/tee stdin.
        - Verifies invoking-user file ownership (st_uid == os.getuid()), readability,
          and exact byte-for-byte fidelity without BPF/network.
        - Verifies path-based PID detector (get_dumpcap_pids) finds the tee writer while stdin is open.
        - Boundedly reaps exact owned tee process upon closing stdin.
        - Note: This proves non-root tee filesystem lifecycle; does not claim hardware/BPF proof.
        """
        segmented_path = os.path.join(FIXTURES_DIR, "segmented.pcapng")
        self.assertTrue(os.path.isfile(segmented_path), f"Missing fixture {segmented_path}")
        with open(segmented_path, "rb") as f:
            original_bytes = f.read()
        self.assertGreater(len(original_bytes), 0)

        with tempfile.TemporaryDirectory() as tmp_dir:
            target_pcap = os.path.join(tmp_dir, "upstream.pcapng")

            # Launch non-sudo tee with target_pcap
            proc = subprocess.Popen(
                ["/usr/bin/tee", target_pcap],
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
            )
            try:
                # Feed fixture bytes through tee stdin
                proc.stdin.write(original_bytes)
                proc.stdin.flush()

                # While stdin is open and tee is alive, verify path-PID detector finds it
                with patch("run.PCAPNG_PATH", target_pcap):
                    detected_pids = run.get_dumpcap_pids()
                self.assertIn(proc.pid, detected_pids, f"Tee PID {proc.pid} not found in {detected_pids}")
            finally:
                # Close stdin and boundedly reap exact owned tee
                if proc.stdin and not proc.stdin.closed:
                    proc.stdin.close()
                proc.wait(timeout=5)

            self.assertEqual(proc.returncode, 0)
            self.assertTrue(os.path.isfile(target_pcap))
            self.assertTrue(os.access(target_pcap, os.R_OK))

            # Verify invoking-user ownership and exact bytes
            st = os.stat(target_pcap)
            self.assertEqual(st.st_uid, os.getuid())
            with open(target_pcap, "rb") as f:
                written_bytes = f.read()
            self.assertEqual(written_bytes, original_bytes)

    def test_operator_capture_600s_timeout_and_canary_deadline(self):
        """
        Regresses run.py:wait_for_capture_and_verify_canary 600s operator-start/canary bound:
        - Verifies timeout raised after 600s deadline.
        - Preserves overall 1200s and trial timeouts.
        """
        harness = run.H2CaptureHarness(nonce=44444)
        harness.results_acquired = True

        with tempfile.TemporaryDirectory() as tmp_dir:
            pcap_file = os.path.join(tmp_dir, "upstream.pcapng")
            # Simulate timeout reached without capture start
            with patch("run.NEW_RESULTS_DIR", tmp_dir), \
                 patch("run.CAPTURE_STDERR_LOG", os.path.join(tmp_dir, "capture.stderr.log")), \
                 patch("run.PCAPNG_PATH", pcap_file), \
                 patch("run.get_dumpcap_pids", return_value=[]), \
                 patch("time.monotonic", side_effect=[0.0, 601.0]), \
                 patch("time.sleep"):

                with self.assertRaises(RuntimeError) as ctx:
                    harness.wait_for_capture_and_verify_canary()
                self.assertIn("600s", str(ctx.exception))

    def test_unreadable_capture_rejection_before_tshark(self):
        """
        Regresses run.py:wait_for_capture_and_verify_canary capture permission enforcement:
        - Detects active capture process and non-empty capture file.
        - Records file uid, gid, mode, and readability in events.jsonl before any canary attempt.
        - Unreadable capture (e.g. root:wheel 0600) fails with explicit capture-permission error.
        - Ensures non-root TShark is NEVER invoked on unreadable output.
        - Note: Mocked permissions verify harness enforcement logic offline;
          they do not claim to prove real BPF/file access.
        """
        harness = run.H2CaptureHarness(nonce=33333)
        harness.results_acquired = True

        with tempfile.TemporaryDirectory() as tmp_dir:
            pcap_file = os.path.join(tmp_dir, "upstream.pcapng")
            events_file = os.path.join(tmp_dir, "events.jsonl")
            with open(pcap_file, "wb") as f:
                f.write(b"\n" * 100)

            # Simulated unreadable capture file (e.g. root:wheel mode 0600)
            mock_stat = MagicMock()
            mock_stat.st_uid = 0
            mock_stat.st_gid = 0
            mock_stat.st_mode = 0o100600

            mock_tshark = MagicMock()

            # First os.path.exists check ensures no file before operator prompt;
            # subsequent check inside wait loop confirms capture file creation.
            exists_count = 0
            real_exists = os.path.exists
            def fake_exists(p):
                nonlocal exists_count
                if p == pcap_file:
                    exists_count += 1
                    return exists_count > 1
                return real_exists(p)

            with patch("run.NEW_RESULTS_DIR", tmp_dir), \
                 patch("run.CAPTURE_STDERR_LOG", os.path.join(tmp_dir, "capture.stderr.log")), \
                 patch("run.PCAPNG_PATH", pcap_file), \
                 patch("run.get_dumpcap_pids", return_value=[9999]), \
                 patch("os.path.exists", side_effect=fake_exists), \
                 patch("os.path.getsize", return_value=100), \
                 patch("os.stat", return_value=mock_stat), \
                 patch("os.access", return_value=False), \
                 patch("subprocess.run", mock_tshark), \
                 patch("urllib.request.urlopen") as mock_http:

                with self.assertRaises(RuntimeError) as ctx:
                    harness.wait_for_capture_and_verify_canary()

                err_msg = str(ctx.exception)
                self.assertIn("permission", err_msg.lower())
                self.assertIn("unreadable", err_msg.lower())

                # TShark must NEVER be called on unreadable capture file
                mock_tshark.assert_not_called()
                # Canary HTTP request must not have been sent
                mock_http.assert_not_called()

                # Verify events.jsonl recorded uid/gid/mode and readability
                self.assertTrue(os.path.isfile(events_file))
                with open(events_file, "r", encoding="utf-8") as f:
                    event_lines = [json.loads(line) for line in f if line.strip()]

                perm_events = [e for e in event_lines if e.get("event") == "capture_file_permissions"]
                self.assertEqual(len(perm_events), 1)
                pe = perm_events[0]
                self.assertEqual(pe["uid"], 0)
                self.assertEqual(pe["gid"], 0)
                self.assertEqual(pe["mode"], "0o100600")
                self.assertFalse(pe["readable"])

    def test_vm_binaries_realistic_argv_and_both_orders(self):
        """
        Regresses run.py:inspect_vm_binaries:
        - Candidate command argv parsed with shlex.split.
        - Executable basename must be connects-egress.
        - Role determined exclusively from argv[1] (supervisor or worker).
        - Parsed argv retained in records.
        - Realistic worker argv carrying --supervisor-uid=0 does NOT overwrite supervisor.
        - Process-list orders (supervisor first, or worker first) both correctly identify
          supervisor identity and exactly one worker.
        """
        harness = run.H2CaptureHarness(nonce=12345)
        expected_hash = run.EXPECTED_HASHES["egress_runtime"]

        sup_cmd = "/opt/connects-egress/bin/connects-egress supervisor --config=/etc/connects-egress/supervisor.toml"
        worker_cmd = (
            "/opt/connects-egress/bin/connects-egress worker "
            f"--source-id={harness.run_id} --mode=publisher "
            f"--ipc-socket=/run/connects-egress/{harness.run_id}.sock "
            f"--state-dir=/var/lib/connects-egress/{harness.run_id} "
            f"--run={harness.run_id} --url=https://stage.livekit.cloud "
            f"--room={harness.room_id} --room-id={harness.room_id} "
            "--host=127.0.0.1 --supervisor-uid=0 --capacity=1"
        )

        def make_subprocess_run(ps_lines):
            def fake_run(cmd, *args, **kwargs):
                cmd_str = " ".join(cmd)
                mock_res = MagicMock()
                mock_res.returncode = 0
                if "ps -eo pid,args" in cmd_str:
                    mock_res.stdout = "\n".join(ps_lines) + "\n"
                elif "sha256sum /proc/" in cmd_str:
                    mock_res.stdout = f"{expected_hash}  -\n"
                elif "sha256sum /opt/connects-egress/bin/connects-egress" in cmd_str:
                    mock_res.stdout = f"{expected_hash}  /opt/connects-egress/bin/connects-egress\n"
                else:
                    mock_res.stdout = ""
                return mock_res
            return fake_run

        # Order 1: Supervisor listed before Worker
        ps_order1 = [
            f"101 {sup_cmd}",
            f"202 {worker_cmd}",
        ]
        with patch("subprocess.run", side_effect=make_subprocess_run(ps_order1)):
            vm_info_1 = harness.inspect_vm_binaries()

        # Verify supervisor identity
        self.assertEqual(vm_info_1["supervisor"]["pid"], "101")
        self.assertEqual(vm_info_1["supervisor"]["cmd"], sup_cmd)
        self.assertEqual(vm_info_1["supervisor"]["argv"][0], "/opt/connects-egress/bin/connects-egress")
        self.assertEqual(vm_info_1["supervisor"]["argv"][1], "supervisor")
        self.assertEqual(vm_info_1["supervisor"]["sha256"], expected_hash)

        # Verify worker record
        self.assertEqual(len(vm_info_1["workers"]), 1)
        w1 = vm_info_1["workers"][0]
        self.assertEqual(w1["pid"], "202")
        self.assertEqual(w1["cmd"], worker_cmd)
        self.assertEqual(w1["argv"][0], "/opt/connects-egress/bin/connects-egress")
        self.assertEqual(w1["argv"][1], "worker")
        self.assertIn("--supervisor-uid=0", w1["argv"])
        self.assertIn(f"--run={harness.run_id}", w1["argv"])
        self.assertEqual(w1["sha256"], expected_hash)

        # Order 2: Worker listed before Supervisor
        ps_order2 = [
            f"202 {worker_cmd}",
            f"101 {sup_cmd}",
        ]
        with patch("subprocess.run", side_effect=make_subprocess_run(ps_order2)):
            vm_info_2 = harness.inspect_vm_binaries()

        # Verify supervisor identity is preserved and not overwritten
        self.assertEqual(vm_info_2["supervisor"]["pid"], "101")
        self.assertEqual(vm_info_2["supervisor"]["cmd"], sup_cmd)
        self.assertEqual(vm_info_2["supervisor"]["argv"][1], "supervisor")
        self.assertEqual(vm_info_2["supervisor"]["sha256"], expected_hash)

        # Verify exactly one worker
        self.assertEqual(len(vm_info_2["workers"]), 1)
        w2 = vm_info_2["workers"][0]
        self.assertEqual(w2["pid"], "202")
        self.assertEqual(w2["argv"][1], "worker")
        self.assertIn("--supervisor-uid=0", w2["argv"])
        self.assertIn(f"--run={harness.run_id}", w2["argv"])

    def test_vm_binaries_rejection_of_malformed_and_unrelated_commands(self):
        """
        Regresses run.py:inspect_vm_binaries filtering:
        - Malformed command line with unclosed quotes must never satisfy verification.
        - Other executables (e.g. bash, python, grep) even with connects-egress in cmd are ignored.
        - Other roles (e.g. bridge, --help, bare binary) are ignored.
        """
        harness = run.H2CaptureHarness(nonce=12345)
        ps_lines = [
            "  PID ARGS",
            '301 /opt/connects-egress/bin/connects-egress worker "unclosed quote --run=bad',
            "302 /usr/bin/python3 /opt/connects-egress/bin/connects-egress worker --run=bad",
            "303 /bin/bash -c 'connects-egress supervisor'",
            "304 /usr/bin/grep connects-egress",
            "305 /opt/connects-egress/bin/connects-egress bridge --source-id=foo",
            "306 /opt/connects-egress/bin/connects-egress --help",
            "307 /opt/connects-egress/bin/connects-egress",
        ]
        def fake_run(cmd, *args, **kwargs):
            mock_res = MagicMock()
            mock_res.returncode = 0
            if "ps -eo pid,args" in " ".join(cmd):
                mock_res.stdout = "\n".join(ps_lines) + "\n"
            else:
                mock_res.stdout = ""
            return mock_res

        with patch("subprocess.run", side_effect=fake_run):
            vm_info = harness.inspect_vm_binaries()

        # None of the malformed or unrelated commands should register
        self.assertEqual(vm_info["supervisor"], {})
        self.assertEqual(vm_info["workers"], [])

    def test_worker_exact_run_matching_and_prefix_rejection(self):
        """
        Regresses run.py:541-550 exact argument --run=<self.run_id> matching:
        - Exact argument match matches target worker.
        - Another run sharing the target prefix (e.g. run_abc_other vs run_abc) is rejected.
        - If multiple workers for different runs are present, exactly one target worker matches.
        - If no exact match exists, 0 workers matched.
        """
        harness = run.H2CaptureHarness(nonce=12345)
        target_run = harness.run_id
        target_arg = f"--run={target_run}"

        w_target = {
            "pid": "501",
            "cmd": f"/opt/connects-egress/bin/connects-egress worker {target_arg} --supervisor-uid=0",
            "argv": ["/opt/connects-egress/bin/connects-egress", "worker", target_arg, "--supervisor-uid=0"],
            "sha256": run.EXPECTED_HASHES["egress_runtime"],
        }
        w_prefix_ext = {
            "pid": "502",
            "cmd": f"/opt/connects-egress/bin/connects-egress worker --run={target_run}_extra --supervisor-uid=0",
            "argv": ["/opt/connects-egress/bin/connects-egress", "worker", f"--run={target_run}_extra", "--supervisor-uid=0"],
            "sha256": run.EXPECTED_HASHES["egress_runtime"],
        }
        w_other = {
            "pid": "503",
            "cmd": "/opt/connects-egress/bin/connects-egress worker --run=completely_different_run --supervisor-uid=0",
            "argv": ["/opt/connects-egress/bin/connects-egress", "worker", "--run=completely_different_run", "--supervisor-uid=0"],
            "sha256": run.EXPECTED_HASHES["egress_runtime"],
        }

        vm_info = {"workers": [w_prefix_ext, w_target, w_other]}

        # Exact match picks ONLY w_target, rejecting prefix-sharing w_prefix_ext
        matched_workers = [
            w for w in vm_info.get("workers", [])
            if target_arg in w.get("argv", [])
        ]
        self.assertEqual(len(matched_workers), 1)
        self.assertEqual(matched_workers[0]["pid"], "501")
        self.assertEqual(matched_workers[0]["argv"], w_target["argv"])

        # When target worker is absent and only prefix-sharing worker exists
        vm_info_without_target = {"workers": [w_prefix_ext, w_other]}
        matched_workers_none = [
            w for w in vm_info_without_target.get("workers", [])
            if target_arg in w.get("argv", [])
        ]
        self.assertEqual(len(matched_workers_none), 0)

    def test_start_egress_and_verify_worker_lifecycle(self):
        """
        Regresses run.py:start_egress_and_verify_worker worker lifecycle:
        - Verifies worker hash and writes worker_info.json and provenance.json.
        - Fails if hash mismatches.
        - Fails if worker count != 1.
        """
        harness = run.H2CaptureHarness(nonce=54321)
        expected_hash = run.EXPECTED_HASHES["egress_runtime"]

        target_arg = f"--run={harness.run_id}"
        matching_worker = {
            "pid": "888",
            "cmd": f"/opt/connects-egress/bin/connects-egress worker {target_arg} --supervisor-uid=0",
            "argv": ["/opt/connects-egress/bin/connects-egress", "worker", target_arg, "--supervisor-uid=0"],
            "sha256": expected_hash,
        }
        vm_mock = {
            "supervisor": {"pid": "777", "cmd": "connects-egress supervisor", "argv": ["connects-egress", "supervisor"], "sha256": expected_hash},
            "installed": {"path": "/opt/connects-egress/bin/connects-egress", "sha256": expected_hash},
            "workers": [matching_worker],
        }

        err_404 = urllib.error.HTTPError(
            url="http://127.0.0.1:18080/runs/test",
            code=404,
            msg="Not Found",
            hdrs={},
            fp=io.BytesIO(b""),
        )

        with tempfile.TemporaryDirectory() as tmp_dir:
            with patch("run.NEW_RESULTS_DIR", tmp_dir), \
                 patch.object(harness, "inspect_vm_binaries", return_value=vm_mock), \
                 patch("urllib.request.urlopen") as mock_url:

                post_resp = MagicMock()
                post_resp.read.return_value = json.dumps({"status": "created"}).encode("utf-8")
                post_resp.status = 200

                state_resp = MagicMock()
                state_resp.read.return_value = json.dumps({"state": "running"}).encode("utf-8")
                state_resp.status = 200

                m3u_resp = MagicMock()
                m3u_resp.read.return_value = b"#EXTM3U\n#EXT-X-VERSION:9\n"
                m3u_resp.status = 200

                mock_cm_post = MagicMock()
                mock_cm_post.__enter__.return_value = post_resp

                mock_cm_state = MagicMock()
                mock_cm_state.__enter__.return_value = state_resp

                mock_cm_m3u = MagicMock()
                mock_cm_m3u.__enter__.return_value = m3u_resp

                mock_url.side_effect = [err_404, mock_cm_post, mock_cm_state, mock_cm_m3u]

                prov_path = os.path.join(tmp_dir, "provenance.json")
                with open(prov_path, "w", encoding="utf-8") as f:
                    json.dump({"verified_at_utc": "2026-10-20T17:00:00Z"}, f)

                harness.start_egress_and_verify_worker()

                self.assertTrue(harness.run_created)
                worker_info_path = os.path.join(tmp_dir, "worker_info.json")
                self.assertTrue(os.path.isfile(worker_info_path))
                with open(worker_info_path, "r", encoding="utf-8") as f:
                    winfo = json.load(f)
                self.assertEqual(winfo["worker"]["pid"], "888")
                self.assertEqual(winfo["worker"]["sha256"], expected_hash)
                self.assertTrue(winfo["match"])

                with open(prov_path, "r", encoding="utf-8") as f:
                    prov_updated = json.load(f)
                self.assertIn("worker_info", prov_updated)

            # Test hash mismatch raises RuntimeError
            vm_mock_bad_hash = {
                "workers": [{
                    "pid": "888",
                    "cmd": f"/opt/connects-egress/bin/connects-egress worker {target_arg}",
                    "argv": ["/opt/connects-egress/bin/connects-egress", "worker", target_arg],
                    "sha256": "badhash123",
                }]
            }
            harness_bad_hash = run.H2CaptureHarness(nonce=54322)
            target_arg_bad = f"--run={harness_bad_hash.run_id}"
            vm_mock_bad_hash["workers"][0]["argv"][2] = target_arg_bad
            with patch("run.NEW_RESULTS_DIR", tmp_dir), \
                 patch.object(harness_bad_hash, "inspect_vm_binaries", return_value=vm_mock_bad_hash), \
                 patch("urllib.request.urlopen") as mock_url:
                mock_url.side_effect = [err_404, mock_cm_post, mock_cm_state, mock_cm_m3u]
                with self.assertRaises(RuntimeError) as ctx:
                    harness_bad_hash.start_egress_and_verify_worker()
                self.assertIn("Worker binary hash mismatch", str(ctx.exception))

            # Test 0 matched workers raises RuntimeError
            vm_mock_no_workers = {"workers": []}
            harness_no_workers = run.H2CaptureHarness(nonce=54323)
            with patch("run.NEW_RESULTS_DIR", tmp_dir), \
                 patch.object(harness_no_workers, "inspect_vm_binaries", return_value=vm_mock_no_workers), \
                 patch("urllib.request.urlopen") as mock_url:
                mock_url.side_effect = [err_404, mock_cm_post, mock_cm_state, mock_cm_m3u]
                with self.assertRaises(RuntimeError) as ctx:
                    harness_no_workers.start_egress_and_verify_worker()
                self.assertIn("Expected exactly 1 worker process", str(ctx.exception))

    def test_capture_stderr_colon_interface_parsing_and_drop_accounting(self):
        """
        Regresses analyze.py:138: parse_capture_stderr regex with quoted interface
        names containing colons, e.g. 'Loopback: lo0'.
        - Verifies exact dumpcap received/dropped summary line from retry04.
        - Verifies zero drops parsed with has_drop_stats=True.
        - Verifies nonzero drops accounted properly with has_drop_stats=True.
        - Verifies missing drop summary returns UNKNOWN with has_drop_stats=False.
        - Verifies malformed line returns UNKNOWN with has_drop_stats=False.
        - Verifies harness logs starting with '[' do not contaminate capture drop statistics.
        """
        # 1. Actual retry04 dumpcap summary line
        actual_retry04_line = (
            "Packets captured: 33726\n"
            "Packets received/dropped on interface 'Loopback: lo0': 33726/0 (pcap:0/dumpcap:0/flushed:0/ps_ifdrop:0) (100.0%)\n"
        )
        res1 = analyze.parse_capture_stderr(actual_retry04_line)
        self.assertTrue(res1["has_drop_stats"])
        self.assertEqual(res1["capture_drops"], 0)
        self.assertEqual(len(res1["raw_drop_lines"]), 1)
        self.assertIn("Loopback: lo0", res1["raw_drop_lines"][0])

        # 2. Nonzero drops on colon-containing interface
        nonzero_line = (
            "Packets received/dropped on interface 'Loopback: lo0': 33726/42 (pcap:0/dumpcap:42/flushed:0/ps_ifdrop:0) (99.8%)\n"
        )
        res2 = analyze.parse_capture_stderr(nonzero_line)
        self.assertTrue(res2["has_drop_stats"])
        self.assertEqual(res2["capture_drops"], 42)

        # 3. Absent / empty stats -> UNKNOWN
        res3 = analyze.parse_capture_stderr("dumpcap: listening on Loopback: lo0\n")
        self.assertFalse(res3["has_drop_stats"])
        self.assertEqual(res3["capture_drops"], "UNKNOWN")

        # 4. Malformed ratio -> UNKNOWN
        malformed = "Packets received/dropped on interface 'Loopback: lo0': not_numbers\n"
        res4 = analyze.parse_capture_stderr(malformed)
        self.assertFalse(res4["has_drop_stats"])
        self.assertEqual(res4["capture_drops"], "UNKNOWN")

        # 5. Harness logs starting with '[' containing drop string must not contaminate stats
        harness_log = (
            "[2026-10-20T17:54:42.954609Z] All trials complete. Packets received/dropped on interface 'Loopback: lo0': 100/5\n"
            "Packets received/dropped on interface 'Loopback: lo0': 33726/0 (pcap:0/dumpcap:0/flushed:0/ps_ifdrop:0) (100.0%)\n"
        )
        res5 = analyze.parse_capture_stderr(harness_log)
        self.assertTrue(res5["has_drop_stats"])
        self.assertEqual(res5["capture_drops"], 0)

    def test_match_initial_playlist_exchange_body_byte_matching_and_ambiguity(self):
        """
        Regresses analyze.py:918-970: required captured body-byte-count matching:
        - Mismatched body length fails with status 'missing'.
        - Absent body length (None or <= 0) fails closed with status 'missing'.
        - Same URI + UA + time with different sizes uniquely matches the candidate matching expected_bytes.
        - Same-size repeated requests remain ambiguous (candidates_count > 1); neither first nor nearest selected.
        """
        base_ex = {
            "protocol": "HTTP/2.0",
            "status": 200,
            "uri": "/live/room_test/vhi.m3u8",
            "ua": "AppleCoreMedia/1.0.0.25F71 (Macintosh; U; Intel Mac OS X 26_5; en_gb)",
            "time_epoch": 1000.0,
        }

        # 1. Mismatched body length
        ex_500 = {**base_ex, "bytes": 500}
        r_mismatch = analyze.match_initial_playlist_exchange(
            [ex_500],
            expected_uri=base_ex["uri"],
            expected_user_agent=base_ex["ua"],
            expected_bytes=600,
            expected_response_epoch_s=1000.2,
        )
        self.assertFalse(r_mismatch["matched"])
        self.assertEqual(r_mismatch["status"], "missing")

        # 2. Absent body length (None) fails closed
        r_absent = analyze.match_initial_playlist_exchange(
            [ex_500],
            expected_uri=base_ex["uri"],
            expected_user_agent=base_ex["ua"],
            expected_bytes=None,
            expected_response_epoch_s=1000.2,
        )
        self.assertFalse(r_absent["matched"])
        self.assertEqual(r_absent["status"], "missing")
        self.assertEqual(r_absent["reason"], "missing_expected_evidence")

        # 3. Same URI + UA + time but different sizes uniquely matching
        ex_a = {**base_ex, "bytes": 500}
        ex_b = {**base_ex, "bytes": 600}
        r_unique_a = analyze.match_initial_playlist_exchange(
            [ex_a, ex_b],
            expected_uri=base_ex["uri"],
            expected_user_agent=base_ex["ua"],
            expected_bytes=500,
            expected_response_epoch_s=1000.2,
        )
        self.assertTrue(r_unique_a["matched"])
        self.assertEqual(r_unique_a["status"], "matched")
        self.assertEqual(r_unique_a["exchange"]["bytes"], 500)

        r_unique_b = analyze.match_initial_playlist_exchange(
            [ex_a, ex_b],
            expected_uri=base_ex["uri"],
            expected_user_agent=base_ex["ua"],
            expected_bytes=600,
            expected_response_epoch_s=1000.2,
        )
        self.assertTrue(r_unique_b["matched"])
        self.assertEqual(r_unique_b["status"], "matched")
        self.assertEqual(r_unique_b["exchange"]["bytes"], 600)

        # 4. Same-size repeated requests remain ambiguous
        ex_dup1 = {**base_ex, "bytes": 500}
        ex_dup2 = {**base_ex, "bytes": 500}
        r_ambig = analyze.match_initial_playlist_exchange(
            [ex_dup1, ex_dup2],
            expected_uri=base_ex["uri"],
            expected_user_agent=base_ex["ua"],
            expected_bytes=500,
            expected_response_epoch_s=1000.2,
        )
        self.assertFalse(r_ambig["matched"])
        self.assertEqual(r_ambig["status"], "ambiguous")
        self.assertEqual(r_ambig["candidates_count"], 2)

    def test_results_retry04_readonly_replay_and_trial08_failure_preservation(self):
        """
        Read-only verification of results_retry04 historical data:
        - capture.stderr.log parses successfully with 0 drops (has_drop_stats=True).
        - Trial 08 real 404 for /vhi/90.5.m4s at 17:53:32Z is strictly preserved and detected
          as a startup failure / frontend 404; no excuse or blanket ignoring.
        - Valid trials requirement (12 valid trials) is not met; no complete PASS claimed.
        - Historical results files remain read-only and unmodified.
        """
        retry04_dir = "/private/tmp/vg-startup-h2-capture-20261020/results_retry04"
        capture_stderr_path = os.path.join(retry04_dir, "capture.stderr.log")
        access_log_path = os.path.join(retry04_dir, "nginx_access.log")
        summary_path = os.path.join(retry04_dir, "summary.json")

        self.assertTrue(os.path.isfile(capture_stderr_path))
        self.assertTrue(os.path.isfile(access_log_path))
        self.assertTrue(os.path.isfile(summary_path))

        # 1. Parse retry04 capture.stderr.log
        with open(capture_stderr_path, "r", encoding="utf-8") as f:
            stderr_content = f.read()
        health = analyze.parse_capture_stderr(stderr_content)
        self.assertTrue(health["has_drop_stats"])
        self.assertEqual(health["capture_drops"], 0)

        # 2. Inspect trial 08 in nginx_access.log: verify real 404 is detected as failure
        trial08_404_epoch = analyze.parse_iso8601_utc("2026-10-20T18:53:32+01:00")
        access_slice = analyze.parse_access_log_slice(
            access_log_path,
            room_id="room_h2cap_1792518626",
            run_id="vg_h2cap_1792518626",
            trial_launch_epoch_s=trial08_404_epoch - 5.0,
            trial_end_epoch_s=trial08_404_epoch + 15.0,
        )
        self.assertGreater(len(access_slice["startup_failures"]), 0)
        has_404_failure = any(
            f.get("status") == 404 and "90.5.m4s" in f.get("uri", "")
            for f in access_slice["startup_failures"]
        )
        self.assertTrue(has_404_failure, "Trial 08 404 for 90.5.m4s must remain a failure")

        # 3. Verify retry04 summary.json: valid_trials_count is 0, not 12
        with open(summary_path, "r", encoding="utf-8") as f:
            summary_data = json.load(f)
        self.assertNotEqual(summary_data.get("valid_trials_count"), 12)
        trial08_summary = next(
            (t for t in summary_data.get("trials", []) if t.get("trial_id") == "trial_08"),
            None,
        )
        self.assertIsNotNone(trial08_summary)
        self.assertIn("frontend_non_200_status_detected", trial08_summary.get("invalidation_reasons", []))


if __name__ == "__main__":
    unittest.main()
