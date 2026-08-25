import tempfile
import threading
import time
import unittest
import socket
import json
from pathlib import Path


import sys


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import server  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bruteforce"))
import session_control  # noqa: E402


class SnapshotSource:
    def __init__(self, value=None):
        self.value = value or {}

    def snapshot(self):
        return dict(self.value)


class ExitedProcess:
    returncode = 0

    def poll(self):
        return self.returncode


def wait_for_phase(manager, phase, timeout=2.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        snapshot = manager.snapshot()
        if snapshot["phase"] == phase:
            return snapshot
        time.sleep(0.01)
    raise AssertionError(f"phase did not become {phase}: {manager.snapshot()}")


def install_in_flight_prepare(manager):
    release = threading.Event()
    finished = threading.Event()

    def old_request():
        release.wait(1.0)
        finished.set()

    manager.global_state.reserve("bruteforce", "page3", None)
    manager.phase = "weak-preparing"
    manager.prepare_bits = 24
    manager.prepare_request_id = 101
    manager.prepare_cancel = threading.Event()
    thread = threading.Thread(target=old_request, daemon=True)
    manager.prepare_thread = thread
    thread.start()
    return release, finished, thread


class BruteForcePrepareRecoveryTest(unittest.TestCase):
    def make_manager(self, root):
        (root / "bruteforce").mkdir()
        return server.BruteForceManager(
            root,
            SnapshotSource(),
            SnapshotSource({"live": True, "mode": "ciphertext"}),
            SnapshotSource(),
            server.GlobalAttackState(),
        )

    def test_timeout_then_ack_reuses_one_request_id_and_prepare_returns_promptly(self):
        with tempfile.TemporaryDirectory() as temporary:
            manager = self.make_manager(Path(temporary))
            first_attempt_started = threading.Event()
            release_first_attempt = threading.Event()
            request_ids = []

            manager._attack_preflight = lambda: None

            def request(bits, request_id):
                request_ids.append(request_id)
                if len(request_ids) == 1:
                    first_attempt_started.set()
                    release_first_attempt.wait(1.0)
                    raise TimeoutError("simulated first ACK timeout")
                return {
                    "profile": "weak",
                    "request_id": request_id,
                    "session_id": "0x10203040",
                    "seed_bits": bits,
                    "tx_host": "10.10.15.2",
                }

            manager._request_weak_session = request
            manager._capture_for_session = lambda session_id, timeout=8.0: {
                "session_id": session_id,
            }
            manager._json_command = lambda *_args, **_kwargs: (_ for _ in ()).throw(
                AssertionError("prepare must not block in the HTTP request")
            )

            started = time.monotonic()
            first = manager.prepare(24)
            elapsed = time.monotonic() - started
            self.assertLess(elapsed, 0.2)
            self.assertEqual(first["phase"], "weak-preparing")
            self.assertTrue(first_attempt_started.wait(0.5))
            self.assertGreater(first["prepare_request_id"], 0)
            self.assertLessEqual(first["prepare_request_id"], 2**64 - 1)

            repeated = manager.prepare(24)
            self.assertEqual(repeated["prepare_request_id"], first["prepare_request_id"])
            release_first_attempt.set()

            ready = wait_for_phase(manager, "weak-ready")
            self.assertEqual(ready["session"]["request_id"], first["prepare_request_id"])
            self.assertGreaterEqual(len(request_ids), 2)
            self.assertEqual(set(request_ids), {first["prepare_request_id"]})

    def test_mismatched_capture_is_retried_until_matching_session_is_observed(self):
        with tempfile.TemporaryDirectory() as temporary:
            manager = self.make_manager(Path(temporary))
            request_ids = []
            captures = []

            manager._attack_preflight = lambda: None

            def request(bits, request_id):
                request_ids.append(request_id)
                return {
                    "profile": "weak",
                    "request_id": request_id,
                    "session_id": "0x55667788",
                    "seed_bits": bits,
                    "tx_host": "10.10.15.2",
                }

            def capture(session_id, timeout=8.0):
                captures.append(session_id)
                if len(captures) == 1:
                    return {"session_id": "0xdeadbeef"}
                return {"session_id": session_id, "frame_id": 17, "packet_id": 3}

            manager._request_weak_session = request
            manager._capture_for_session = capture
            manager._json_command = lambda *_args, **_kwargs: {
                "profile": "weak",
                "request_id": 1,
                "session_id": "0x55667788",
                "seed_bits": 24,
            }

            manager.prepare(24)
            ready = wait_for_phase(manager, "weak-ready")

            self.assertGreaterEqual(len(captures), 2)
            self.assertGreaterEqual(len(request_ids), 2)
            self.assertEqual(len(set(request_ids)), 1)
            self.assertEqual(ready["session"]["seed_bits"], 24)
            self.assertEqual(ready["record"]["session_id"], "0x55667788")

    def test_session_client_sends_the_backend_owned_64_bit_request_id(self):
        responder = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        responder.bind(("127.0.0.1", 0))
        responder.settimeout(1.0)
        original_port = session_control.CONTROL_PORT
        session_control.CONTROL_PORT = responder.getsockname()[1]
        received = []

        def respond():
            message, source = responder.recvfrom(1024)
            received.append(message.decode("ascii").strip())
            responder.sendto(
                b"WEAK_SESSION_ACTIVE 18446744073709551615 0x12345678 24\n",
                source,
            )

        thread = threading.Thread(target=respond, daemon=True)
        thread.start()
        try:
            result = session_control.request_session(
                "CREATE_WEAK_SESSION", "127.0.0.1", 24,
                timeout=0.5, request_id=2**64 - 1,
            )
        finally:
            session_control.CONTROL_PORT = original_port
            responder.close()
        thread.join(1.0)

        self.assertEqual(
            received,
            ["CREATE_WEAK_SESSION 18446744073709551615 24"],
        )
        self.assertEqual(result["request_id"], 2**64 - 1)

    def test_secure_waits_for_old_weak_request_and_matching_secure_packet(self):
        with tempfile.TemporaryDirectory() as temporary:
            manager = self.make_manager(Path(temporary))
            release_old, old_finished, old_thread = install_in_flight_prepare(manager)
            capture_calls = []
            allow_matching_capture = threading.Event()

            def request_secure(request_id):
                self.assertTrue(old_finished.is_set(), "secure request overlapped weak request")
                return {
                    "profile": "secure",
                    "request_id": request_id,
                    "session_id": "0xabcdef01",
                    "tx_host": "10.10.15.2",
                }

            def capture(session_id, timeout=8.0):
                capture_calls.append(session_id)
                if len(capture_calls) == 1:
                    return {"session_id": "0x11111111"}
                allow_matching_capture.wait(1.0)
                return {"session_id": session_id}

            manager._request_secure_session = request_secure
            manager._capture_for_session = capture
            manager._json_command = lambda *_args, **_kwargs: {
                "profile": "secure",
                "request_id": 1,
                "session_id": "0xabcdef01",
            }

            try:
                started = time.monotonic()
                transition = manager.secure()
                self.assertLess(time.monotonic() - started, 0.2)
                self.assertEqual(transition["phase"], "returning-secure")
                self.assertFalse(old_finished.is_set())

                release_old.set()
                deadline = time.monotonic() + 1.0
                while len(capture_calls) < 2 and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertGreaterEqual(len(capture_calls), 2)
                self.assertEqual(manager.snapshot()["phase"], "returning-secure")

                allow_matching_capture.set()
                secured = wait_for_phase(manager, "secure")
                self.assertEqual(secured["session"]["session_id"], "0xabcdef01")
                self.assertIsNone(secured["record"])
            finally:
                release_old.set()
                allow_matching_capture.set()
                old_thread.join(1.0)

    def test_reset_during_prepare_uses_the_same_serial_secure_transition(self):
        with tempfile.TemporaryDirectory() as temporary:
            manager = self.make_manager(Path(temporary))
            release_old, old_finished, old_thread = install_in_flight_prepare(manager)
            secure_requested = threading.Event()

            def request_secure(request_id):
                self.assertTrue(old_finished.is_set(), "reset overlapped secure and weak requests")
                secure_requested.set()
                return {
                    "profile": "secure",
                    "request_id": request_id,
                    "session_id": "0x76543210",
                    "tx_host": "10.10.15.2",
                }

            manager._request_secure_session = request_secure
            manager._capture_for_session = lambda session_id, timeout=8.0: {
                "session_id": session_id,
            }

            try:
                started = time.monotonic()
                transition = manager.reset()
                self.assertLess(time.monotonic() - started, 0.2)
                self.assertEqual(transition["phase"], "returning-secure")
                self.assertFalse(secure_requested.is_set())

                release_old.set()
                secured = wait_for_phase(manager, "secure")
                self.assertTrue(secure_requested.is_set())
                self.assertEqual(secured["session"]["session_id"], "0x76543210")
            finally:
                release_old.set()
                old_thread.join(1.0)

    def test_finished_search_snapshot_cannot_overwrite_returning_secure_phase(self):
        with tempfile.TemporaryDirectory() as temporary:
            manager = self.make_manager(Path(temporary))
            allow_secure_ack = threading.Event()
            manager.process = ExitedProcess()
            manager.status_path.write_text(
                json.dumps({"phase": "found", "candidates_tested": 1}),
                encoding="utf-8",
            )

            def request_secure(request_id):
                allow_secure_ack.wait(1.0)
                return {
                    "profile": "secure",
                    "request_id": request_id,
                    "session_id": "0x12344321",
                }

            manager._request_secure_session = request_secure
            manager._capture_for_session = lambda session_id, timeout=8.0: {
                "session_id": session_id,
            }

            try:
                transition = manager.secure()
                self.assertEqual(transition["phase"], "returning-secure")
                self.assertEqual(manager.snapshot()["phase"], "returning-secure")
            finally:
                allow_secure_ack.set()

    def test_stop_does_not_release_an_active_secure_transition(self):
        with tempfile.TemporaryDirectory() as temporary:
            manager = self.make_manager(Path(temporary))
            allow_secure_ack = threading.Event()

            def request_secure(request_id):
                allow_secure_ack.wait(1.0)
                return {
                    "profile": "secure",
                    "request_id": request_id,
                    "session_id": "0xaabbccdd",
                }

            manager._request_secure_session = request_secure
            manager._capture_for_session = lambda session_id, timeout=8.0: {
                "session_id": session_id,
            }

            try:
                manager.secure()
                stopped = manager.stop()
                self.assertEqual(stopped["phase"], "returning-secure")
                self.assertEqual(stopped["attack_state"]["owner"], "page3")
            finally:
                allow_secure_ack.set()


if __name__ == "__main__":
    unittest.main()
