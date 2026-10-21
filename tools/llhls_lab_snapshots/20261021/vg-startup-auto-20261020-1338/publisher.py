#!/usr/bin/env python3
"""
publisher.py - Media publisher for VGLL startup latency experiment.
Owns test media pipelines and binary marker generation.
"""

import argparse
import os
import signal
import struct
import sys
import time
import zlib

import gi
gi.require_version("Gst", "1.0")
gi.require_foreign("cairo")
from gi.repository import Gst, GLib
import cairo


def get_monotonic_ms() -> int:
    """Return CLOCK_MONOTONIC in milliseconds as uint64."""
    return int(time.clock_gettime(time.CLOCK_MONOTONIC) * 1000)


def draw_marker_on_context(ctx: cairo.Context, nonce: int, frame: int, mono_ms: int):
    """
    Paints background, 32px border, 16x12 binary marker cells, and optional text.
    Payload: VGLL(4), nonce(4), frame(4), mono_ms(8), crc32(4) -> 24 bytes (192 bits).
    MSB-first row-major 16 cols x 12 rows, 32px cells at origin (104, 448).
    """
    prefix = struct.pack(">4sIIQ", b"VGLL", nonce & 0xFFFFFFFF, frame & 0xFFFFFFFF, mono_ms & 0xFFFFFFFFFFFFFFFF)
    crc = zlib.crc32(prefix) & 0xFFFFFFFF
    payload = prefix + struct.pack(">I", crc)

    # 1. Dark background over full frame
    ctx.set_source_rgb(0.04, 0.04, 0.04)
    ctx.rectangle(0, 0, 720, 1280)
    ctx.fill()

    # 2. White 32px border surrounding 16x12 cells at origin (104, 448)
    # Grid: x in [104, 616], y in [448, 832] -> border x in [72, 648], y in [416, 864]
    ctx.set_source_rgb(1.0, 1.0, 1.0)
    ctx.rectangle(72, 416, 576, 448)
    ctx.fill()

    # 3. Inner grid base: black
    ctx.set_source_rgb(0.0, 0.0, 0.0)
    ctx.rectangle(104, 448, 512, 384)
    ctx.fill()

    # 4. Binary cells (16 cols x 12 rows, 32px each)
    ctx.set_source_rgb(1.0, 1.0, 1.0)
    for r in range(12):
        for c in range(16):
            bit_idx = r * 16 + c
            byte_idx = bit_idx // 8
            bit_in_byte = 7 - (bit_idx % 8)
            bit = (payload[byte_idx] >> bit_in_byte) & 1
            if bit == 1:
                ctx.rectangle(104 + c * 32, 448 + r * 32, 32, 32)
    ctx.fill()

    # 5. Optional visible text outside marker
    ctx.set_source_rgb(0.9, 0.9, 0.9)
    ctx.select_font_face("monospace", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD)
    ctx.set_font_size(24)
    ctx.move_to(72, 390)
    ctx.show_text(f"VGLL NONCE:{nonce} FRAME:{frame}")
    ctx.move_to(72, 895)
    ctx.show_text(f"MONO:{mono_ms} ms")


def generate_calibration_png(png_path: str, nonce: int):
    """Writes one marker PNG via cairo without starting live pipelines."""
    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, 720, 1280)
    ctx = cairo.Context(surface)
    mono_ms = get_monotonic_ms()
    draw_marker_on_context(ctx, nonce, 1, mono_ms)
    surface.write_to_png(png_path)
    sys.stderr.write(
        f"[publisher] Calibration PNG written to {png_path} (nonce={nonce}, frame=1, mono={mono_ms})\n"
    )
    sys.stderr.flush()


class MediaPublisher:
    def __init__(self, nonce: int):
        self.nonce = nonce
        self.frame_counter = 0
        self.last_log_time = time.monotonic()
        self.last_log_frame = 0
        self.video_pipe = None
        self.audio_pipe = None
        self.loop = None
        self.running = False

    def on_draw(self, overlay, context, timestamp, duration):
        """Cairooverlay draw callback; captures monotonic time immediately before draw."""
        try:
            mono_ms = get_monotonic_ms()
            self.frame_counter += 1
            draw_marker_on_context(context, self.nonce, self.frame_counter, mono_ms)
        except Exception as e:
            sys.stderr.write(f"[publisher] Draw failure: {e}\n")
            sys.stderr.flush()
            self.stop()
            sys.exit(1)

    def on_stats_timer(self):
        """Logs generation rate per second to stderr."""
        now = time.monotonic()
        dt = now - self.last_log_time
        if dt >= 1.0:
            frames = self.frame_counter - self.last_log_frame
            fps = frames / dt
            mono_ms = get_monotonic_ms()
            sys.stderr.write(
                f"[publisher] fps={fps:.1f} total_frames={self.frame_counter} mono={mono_ms}ms\n"
            )
            sys.stderr.flush()
            self.last_log_time = now
            self.last_log_frame = self.frame_counter
        return True

    def on_bus_message(self, bus, message, stream_name):
        """Bus message handler: on error stop both pipelines and exit nonzero."""
        t = message.type
        if t == Gst.MessageType.ERROR:
            err, debug = message.parse_error()
            sys.stderr.write(f"[publisher] {stream_name} pipeline error: {err} ({debug})\n")
            sys.stderr.flush()
            self.stop()
            sys.exit(1)
        elif t == Gst.MessageType.EOS:
            sys.stderr.write(f"[publisher] {stream_name} pipeline EOS\n")
            sys.stderr.flush()
            self.stop()
            sys.exit(0)

    def stop(self):
        """Stops both GStreamer pipelines and terminates mainloop."""
        self.running = False
        if self.video_pipe:
            self.video_pipe.set_state(Gst.State.NULL)
        if self.audio_pipe:
            self.audio_pipe.set_state(Gst.State.NULL)
        if self.loop and self.loop.is_running():
            self.loop.quit()

    def run(self):
        """Initializes and runs video and audio GStreamer pipelines."""
        Gst.init(None)

        v_desc = (
            "videotestsrc is-live=true ! "
            "video/x-raw,format=BGRA,width=720,height=1280,framerate=30/1 ! "
            "cairooverlay name=stamp ! "
            "videoconvert ! "
            "vtenc_h264 realtime=true max-keyframe-interval=30 allow-frame-reordering=false bitrate=2500 ! "
            "h264parse config-interval=-1 ! "
            "video/x-h264,stream-format=byte-stream ! "
            "tcpserversink host=127.0.0.1 port=19101"
        )
        a_desc = (
            "audiotestsrc is-live=true freq=440 ! "
            "audio/x-raw,rate=48000,channels=1 ! "
            "opusenc bitrate=64000 ! "
            "oggmux ! "
            "tcpserversink host=127.0.0.1 port=19102"
        )

        try:
            self.video_pipe = Gst.parse_launch(v_desc)
            self.audio_pipe = Gst.parse_launch(a_desc)
        except Exception as e:
            sys.stderr.write(f"[publisher] Failed to create GStreamer pipelines: {e}\n")
            sys.stderr.flush()
            sys.exit(1)

        stamp = self.video_pipe.get_by_name("stamp")
        if not stamp:
            sys.stderr.write("[publisher] Failed to get cairooverlay element 'stamp'\n")
            sys.stderr.flush()
            sys.exit(1)
        stamp.connect("draw", self.on_draw)

        self.loop = GLib.MainLoop()

        bus_v = self.video_pipe.get_bus()
        bus_v.add_signal_watch()
        bus_v.connect("message", self.on_bus_message, "video")

        bus_a = self.audio_pipe.get_bus()
        bus_a.add_signal_watch()
        bus_a.connect("message", self.on_bus_message, "audio")

        GLib.timeout_add_seconds(1, self.on_stats_timer)

        ret_v = self.video_pipe.set_state(Gst.State.PLAYING)
        ret_a = self.audio_pipe.set_state(Gst.State.PLAYING)
        if ret_v == Gst.StateChangeReturn.FAILURE or ret_a == Gst.StateChangeReturn.FAILURE:
            sys.stderr.write("[publisher] Failed to transition pipelines to PLAYING\n")
            sys.stderr.flush()
            self.stop()
            sys.exit(1)

        self.running = True
        sys.stderr.write(
            f"[publisher] Live pipelines ACTIVE on 127.0.0.1:19101 (video) and 19102 (audio) (nonce={self.nonce})\n"
        )
        sys.stderr.flush()

        def sig_handler(sig, frame):
            sys.stderr.write(f"[publisher] Received signal {sig}, terminating gracefully\n")
            sys.stderr.flush()
            self.stop()
            sys.exit(0)

        signal.signal(signal.SIGINT, sig_handler)
        signal.signal(signal.SIGTERM, sig_handler)

        try:
            self.loop.run()
        except Exception as e:
            sys.stderr.write(f"[publisher] Event loop terminated with exception: {e}\n")
            sys.stderr.flush()
            self.stop()
            sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description="VGLL media publisher with binary frame markers.")
    parser.add_argument("--nonce", type=int, required=True, help="Session nonce (uint32)")
    parser.add_argument("--calibration-png", type=str, default=None, help="Generate calibration PNG and exit")
    args = parser.parse_args()

    if args.calibration_png:
        generate_calibration_png(args.calibration_png, args.nonce)
        sys.exit(0)

    publisher = MediaPublisher(nonce=args.nonce)
    publisher.run()


if __name__ == "__main__":
    main()
