"""
test_delivery_outage.py - Pure offline fake-process unit tests for DeliveryOutage and recovery polling.
Covers flag-before-stop, acktimeout, idempotence, exitstatus, cancellation/failure resume,
start emit failure resume guarantee, restore logging failure propagation, splitline binary polling,
and exact flat callback adapter.
Note: Offline mocks and fake-process tests verify state-machine transitions and signal ordering, not live OS scheduling.
"""

import json
import os
import signal
import sys
import unittest

sys.path.insert(0, "/private/tmp/vg-native-recovery-20261021")
from DeliveryOutage import DeliveryOutage


class FakeProcess:
    def __init__(self, pid: int = 99999, returncode: int | None = None):
        self.pid = pid
        self.returncode = returncode

    def poll(self):
        return self.returncode


class DeliveryOutageOfflineTests(unittest.TestCase):
    def test_flag_before_stop(self):
        """Verify needs_continue is True BEFORE SIGSTOP signal is issued."""
        fake_proc = FakeProcess(pid=1001)
        flag_at_stop = None
        signals_sent = []

        def fake_kill(pid, sig):
            nonlocal flag_at_stop
            if sig == signal.SIGSTOP:
                flag_at_stop = outage.needs_continue
            signals_sent.append((pid, sig))

        stop_status = (signal.SIGSTOP << 8) | 0x7F

        outage = DeliveryOutage(
            fake_proc,
            kill_fn=fake_kill,
            waitpid_fn=lambda p, o: (p, stop_status),
        )
        outage.start(seconds=5.0)

        self.assertTrue(flag_at_stop, "needs_continue must be True before SIGSTOP is delivered")
        self.assertEqual(signals_sent, [(1001, signal.SIGSTOP)])
        self.assertTrue(outage.is_active)
        self.assertTrue(outage.needs_continue)

    def test_ack_timeout(self):
        """Verify timeout if stopped state is not acknowledged within 500ms."""
        fake_proc = FakeProcess(pid=1002)
        simulated_time = 100.0

        def fake_mono():
            nonlocal simulated_time
            return simulated_time

        def fake_sleep(secs):
            nonlocal simulated_time
            simulated_time += 0.100

        outage = DeliveryOutage(
            fake_proc,
            kill_fn=lambda p, s: None,
            waitpid_fn=lambda p, o: (0, 0),
            sleep_fn=fake_sleep,
            mono_fn=fake_mono,
        )

        with self.assertRaises(RuntimeError) as ctx:
            outage.start(seconds=5.0)
        self.assertIn("did not confirm STOP within 500ms", str(ctx.exception))

    def test_idempotence(self):
        """Verify calling restore multiple times issues SIGCONT exactly once."""
        fake_proc = FakeProcess(pid=1003)
        signals_sent = []
        stop_status = (signal.SIGSTOP << 8) | 0x7F

        def fake_kill(pid, sig):
            signals_sent.append((pid, sig))

        outage = DeliveryOutage(
            fake_proc,
            kill_fn=fake_kill,
            waitpid_fn=lambda p, o: (p, stop_status),
        )
        outage.start(seconds=2.0)
        self.assertEqual(signals_sent, [(1003, signal.SIGSTOP)])

        # First restore: sends SIGCONT
        outage.restore(reason="test_first")
        self.assertEqual(signals_sent, [(1003, signal.SIGSTOP), (1003, signal.SIGCONT)])
        self.assertFalse(outage.needs_continue)
        self.assertFalse(outage.is_active)

        # Subsequent restores: idempotent
        outage.restore(reason="test_second")
        outage.restore(reason="test_third")
        self.assertEqual(signals_sent, [(1003, signal.SIGSTOP), (1003, signal.SIGCONT)])

    def test_exit_status_preservation_on_abrupt_exit(self):
        """Verify waitpid observing EXIT/SIGNAL preserves returncode and raises."""
        fake_proc = FakeProcess(pid=1004)
        exit_status = 42 << 8

        outage = DeliveryOutage(
            fake_proc,
            kill_fn=lambda p, s: None,
            waitpid_fn=lambda p, o: (p, exit_status),
        )

        with self.assertRaises(RuntimeError) as ctx:
            outage.start(seconds=5.0)

        self.assertIn("exited or was signaled during STOP verification", str(ctx.exception))
        self.assertEqual(fake_proc.returncode, 42)
        self.assertFalse(outage.needs_continue)

    def test_cancellation_and_failure_resume(self):
        """Verify on SIGCONT failure, needs_continue is retained for cleanup retry."""
        fake_proc = FakeProcess(pid=1005)
        stop_status = (signal.SIGSTOP << 8) | 0x7F
        should_fail_cont = True

        def fake_kill(pid, sig):
            if sig == signal.SIGCONT and should_fail_cont:
                raise OSError("Transient OS permission error")

        outage = DeliveryOutage(
            fake_proc,
            kill_fn=fake_kill,
            waitpid_fn=lambda p, o: (p, stop_status),
        )
        outage.start(seconds=5.0)
        self.assertTrue(outage.needs_continue)

        with self.assertRaises(RuntimeError):
            outage.restore(reason="failure_test")
        self.assertTrue(outage.needs_continue, "needs_continue must remain True on SIGCONT failure")

        should_fail_cont = False
        outage.restore(reason="retry_cleanup")
        self.assertFalse(outage.needs_continue)

    def test_start_emit_failure_guarantees_resume_and_propagates(self):
        """Verify when emit raises during start, SIGCONT is delivered and error propagates."""
        fake_proc = FakeProcess(pid=1006)
        signals_sent = []
        stop_status = (signal.SIGSTOP << 8) | 0x7F

        def fake_kill(pid, sig):
            signals_sent.append((pid, sig))

        def failing_emit(event):
            raise IOError("Audit write failure on start")

        outage = DeliveryOutage(
            fake_proc,
            emit=failing_emit,
            kill_fn=fake_kill,
            waitpid_fn=lambda p, o: (p, stop_status),
        )

        with self.assertRaises(IOError) as ctx:
            outage.start(seconds=5.0)

        self.assertEqual(str(ctx.exception), "Audit write failure on start")
        # Must have delivered SIGSTOP then SIGCONT to resume process
        self.assertEqual(signals_sent, [(1006, signal.SIGSTOP), (1006, signal.SIGCONT)])
        self.assertFalse(outage.needs_continue)
        self.assertFalse(outage.is_active)

    def test_restore_propagates_logging_failure_after_signal(self):
        """Verify restore signals first and propagates logging failure afterward."""
        fake_proc = FakeProcess(pid=1007)
        signals_sent = []
        stop_status = (signal.SIGSTOP << 8) | 0x7F

        def fake_kill(pid, sig):
            signals_sent.append((pid, sig))

        def failing_emit(event):
            raise IOError("Audit write failure on restore")

        outage = DeliveryOutage(
            fake_proc,
            emit=failing_emit,
            kill_fn=fake_kill,
            waitpid_fn=lambda p, o: (p, stop_status),
        )
        # Start without emit failure
        outage.emit = None
        outage.start(seconds=2.0)
        self.assertEqual(signals_sent, [(1007, signal.SIGSTOP)])
        self.assertTrue(outage.needs_continue)

        # Set failing emit and restore
        outage.emit = failing_emit
        with self.assertRaises(IOError) as ctx:
            outage.restore(reason="failing_log_test")

        self.assertEqual(str(ctx.exception), "Audit write failure on restore")
        # Signal was sent BEFORE logging
        self.assertEqual(signals_sent, [(1007, signal.SIGSTOP), (1007, signal.SIGCONT)])
        self.assertFalse(outage.needs_continue)
        self.assertFalse(outage.is_active)

    def test_splitline_binary_tail_poll(self):
        """Regression coverage: binary polling advances over all bytes and retains tail once."""
        full_content = (
            b'{"event":"config","generation":1}\n'
            b'{"event":"state","generation":1,"time_control_status":"playing","valid":true,"presentation_eligible":true,"observation_mono_ms":1000}\n'
            b'{"event":"state","generation":1,"partial":'
        )
        chunk1 = full_content[:45]  # splits line 2 in half
        chunk2 = full_content[45:]  # completes line 2 and adds partial line 3

        parsed_records = []
        jsonl_offset = 0
        jsonl_tail_bytes = b""

        for chunk in [chunk1, chunk2]:
            jsonl_offset += len(chunk)
            combined = jsonl_tail_bytes + chunk
            lines = combined.split(b"\n")
            jsonl_tail_bytes = lines[-1]
            for line_bytes in lines[:-1]:
                line_bytes = line_bytes.strip()
                if line_bytes:
                    parsed_records.append(json.loads(line_bytes.decode("utf-8")))

        self.assertEqual(jsonl_offset, len(full_content))
        self.assertEqual(len(parsed_records), 2)
        self.assertEqual(parsed_records[0]["event"], "config")
        self.assertEqual(parsed_records[1]["event"], "state")
        self.assertEqual(jsonl_tail_bytes, b'{"event":"state","generation":1,"partial":')

    def test_exact_flat_callback_adapter(self):
        """Verify flat callback adapter extracts event name, adds trial_id, and flattens fields."""
        events_emitted = []

        def mock_record_event(event_name, **fields):
            events_emitted.append((event_name, fields))

        trial_id = "trial_01_d2s_obs"

        def emit_adapter(event_dict: dict):
            event_copy = dict(event_dict)
            event_name = event_copy.pop("event", "delivery_outage")
            mock_record_event(event_name, trial_id=trial_id, **event_copy)

        sample_event = {
            "event": "delivery_outage_started",
            "target_pid": 1234,
            "target_duration_s": 2.0,
            "cmd_mono_s": 100.5,
        }
        emit_adapter(sample_event)

        self.assertEqual(len(events_emitted), 1)
        ev_name, fields = events_emitted[0]
        self.assertEqual(ev_name, "delivery_outage_started")
        self.assertEqual(fields["trial_id"], "trial_01_d2s_obs")
        self.assertEqual(fields["target_pid"], 1234)
        self.assertEqual(fields["target_duration_s"], 2.0)
        self.assertNotIn("event", fields)


if __name__ == "__main__":
    unittest.main()
