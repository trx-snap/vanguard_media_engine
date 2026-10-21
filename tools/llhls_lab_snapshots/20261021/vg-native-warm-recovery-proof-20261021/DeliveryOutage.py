"""
DeliveryOutage.py - Synchronous, main-thread-only delivery outage controller.
Pauses owned gateway process via SIGSTOP and restores via SIGCONT.
Tracks monotonic deadlines from stop-acknowledgment using POSIX CLOCK_MONOTONIC.
Guarantees SIGCONT on start logging failure and signal-before-logging on restoration.
"""

import os
import signal
import sys
import threading
import time
from datetime import datetime, timezone
from typing import Any, Callable, Dict, Optional


def _default_posix_mono() -> float:
    return time.clock_gettime(time.CLOCK_MONOTONIC)


class DeliveryOutage:
    """
    Manages an intentional delivery pause on a retained gateway Popen process handle.
    Must be invoked only on the main Python thread.
    """

    def __init__(
        self,
        process: Any,
        emit: Optional[Callable[[Dict[str, Any]], None]] = None,
        kill_fn: Callable[[int, int], None] = os.kill,
        waitpid_fn: Callable[[int, int], tuple[int, int]] = os.waitpid,
        sleep_fn: Callable[[float], None] = time.sleep,
        mono_fn: Callable[[], float] = _default_posix_mono,
    ):
        if not hasattr(process, "pid") or process.pid is None:
            raise ValueError("DeliveryOutage requires a retained process handle with a valid PID")
        self.process = process
        self.pid: int = process.pid
        self.emit = emit
        self._kill_fn = kill_fn
        self._waitpid_fn = waitpid_fn
        self._sleep_fn = sleep_fn
        self._mono_fn = mono_fn

        self.needs_continue: bool = False
        self.is_active: bool = False
        self.stop_cmd_mono: Optional[float] = None
        self.stop_cmd_utc: Optional[str] = None
        self.stop_ack_mono: Optional[float] = None
        self.stop_ack_utc: Optional[str] = None
        self.deadline_mono: Optional[float] = None
        self.target_duration_s: float = 0.0

    def _assert_main_thread(self) -> None:
        if threading.current_thread() is not threading.main_thread():
            raise RuntimeError("DeliveryOutage must be called exclusively on the main Python thread")

    def start(self, seconds: float) -> None:
        """
        Initiates delivery pause by sending SIGSTOP to the gateway process.
        Sets needs_continue before signal issuance, verifies stopped state within 500ms,
        and sets restoration deadline from the stop acknowledgment timestamp.
        On start emit failure, resumes via SIGCONT in a guaranteed path then propagates.
        """
        self._assert_main_thread()
        if seconds <= 0 or not (seconds == seconds and seconds < float("inf")):
            raise ValueError(f"Invalid outage duration: {seconds}")
        if self.is_active or self.needs_continue:
            raise RuntimeError(f"DeliveryOutage already active on PID {self.pid}")

        if hasattr(self.process, "poll") and self.process.poll() is not None:
            raise RuntimeError(
                f"Cannot start delivery outage: target process {self.pid} already exited with {self.process.returncode}"
            )

        self.target_duration_s = seconds
        self.stop_cmd_mono = self._mono_fn()
        self.stop_cmd_utc = datetime.now(timezone.utc).isoformat()

        # Flag needsContinue BEFORE SIGSTOP exact process.pid
        self.needs_continue = True

        try:
            self._kill_fn(self.pid, signal.SIGSTOP)
        except Exception as e:
            self.needs_continue = False
            raise RuntimeError(f"Failed sending SIGSTOP to PID {self.pid}: {e}") from e

        # Verify stopped within 500ms via waitpid(WNOHANG|WUNTRACED)
        verify_deadline = self.stop_cmd_mono + 0.500
        stopped_verified = False

        while self._mono_fn() <= verify_deadline:
            try:
                wpid, status = self._waitpid_fn(self.pid, os.WNOHANG | os.WUNTRACED)
            except ChildProcessError:
                wpid, status = 0, 0

            if wpid == self.pid:
                if os.WIFSTOPPED(status):
                    stopped_verified = True
                    self.stop_ack_mono = self._mono_fn()
                    self.stop_ack_utc = datetime.now(timezone.utc).isoformat()
                    break
                elif os.WIFEXITED(status) or os.WIFSIGNALED(status):
                    exitcode = os.waitstatus_to_exitcode(status)
                    if hasattr(self.process, "returncode"):
                        self.process.returncode = exitcode
                    self.needs_continue = False
                    raise RuntimeError(
                        f"Target process {self.pid} exited or was signaled during STOP verification: exitcode={exitcode}"
                    )

            self._sleep_fn(0.005)

        if not stopped_verified:
            try:
                self.restore(reason="stop_ack_timeout")
            except Exception:
                pass
            raise RuntimeError(f"Target process {self.pid} did not confirm STOP within 500ms")

        self.deadline_mono = self.stop_ack_mono + seconds
        self.is_active = True

        # Log command/ack mono+UTC; on emit failure, resume in guaranteed path THEN propagate
        if self.emit is not None:
            try:
                self.emit({
                    "event": "delivery_outage_started",
                    "target_pid": self.pid,
                    "target_duration_s": seconds,
                    "cmd_utc": self.stop_cmd_utc,
                    "cmd_mono_s": self.stop_cmd_mono,
                    "ack_utc": self.stop_ack_utc,
                    "ack_mono_s": self.stop_ack_mono,
                    "ack_latency_ms": (self.stop_ack_mono - self.stop_cmd_mono) * 1000.0,
                })
            except Exception as emit_err:
                try:
                    self._kill_fn(self.pid, signal.SIGCONT)
                    self.needs_continue = False
                    self.is_active = False
                except Exception:
                    pass
                raise emit_err

    def tick(self) -> None:
        """
        Called at interval <= 250ms while polling. Sends SIGCONT once deadline has elapsed.
        """
        self._assert_main_thread()
        if not self.is_active or not self.needs_continue:
            return
        if self.deadline_mono is None:
            return

        now = self._mono_fn()
        if now >= self.deadline_mono:
            self.restore(reason="deadline_elapsed")

    def restore(self, reason: str = "normal") -> None:
        """
        Restores traffic delivery by sending SIGCONT.
        Idempotent: returns cleanly if not currently paused.
        Sends signal BEFORE logging.
        Retains needs_continue on signal failure for cleanup retry.
        Propagates logging failure after guaranteed signal delivery.
        """
        self._assert_main_thread()
        if not self.needs_continue:
            return

        # Signal BEFORE logging
        try:
            self._kill_fn(self.pid, signal.SIGCONT)
            self.needs_continue = False
            self.is_active = False
        except ProcessLookupError:
            self.needs_continue = False
            self.is_active = False
        except Exception as e:
            # Retain needs_continue on signal failure for cleanup retry
            raise RuntimeError(f"Failed sending SIGCONT to PID {self.pid}: {e}") from e

        restore_mono = self._mono_fn()
        restore_utc = datetime.now(timezone.utc).isoformat()
        actual_dur_s = (restore_mono - self.stop_ack_mono) if self.stop_ack_mono is not None else None

        # Propagate logging failure afterward; process is already resumed
        if self.emit is not None:
            self.emit({
                "event": "delivery_outage_restored",
                "target_pid": self.pid,
                "reason": reason,
                "utc": restore_utc,
                "restore_mono_s": restore_mono,
                "actual_outage_duration_s": actual_dur_s,
            })
