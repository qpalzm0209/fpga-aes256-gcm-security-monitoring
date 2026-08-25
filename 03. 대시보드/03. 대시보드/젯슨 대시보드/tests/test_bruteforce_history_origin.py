import sys
import tempfile
import threading
import unittest
from collections import deque
from pathlib import Path
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import server  # noqa: E402


class FakeGlobalState:
    def reserve(self, *_args):
        pass

    def running(self, *_args):
        pass

    def release(self, *_args):
        pass


class RunningProcess:
    def poll(self):
        return None


class BruteForceHistoryOriginTest(unittest.TestCase):
    def test_start_initializes_graph_history_at_zero(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manager = server.BruteForceManager.__new__(server.BruteForceManager)
            manager.operation_lock = threading.Lock()
            manager.lock = threading.Lock()
            manager.global_state = FakeGlobalState()
            manager._attack_preflight = lambda: None
            manager._capture_for_session = lambda _session_id: {"session_id": "0x1"}
            manager.session = {"seed_bits": 24, "session_id": "0x1"}
            manager.record = {"session_id": "0x1"}
            manager.process = None
            manager.run_id = 0
            manager.history = deque([{"t": 9.0, "tested": 99}], maxlen=720)
            manager.last_history_tested = 99
            manager.recovered_frame = {"old": True}
            manager.recovery = {"phase": "ready", "run_id": 0}
            manager.recovery_run_id = 0
            manager.runtime = root
            manager.directory = root
            manager.record_path = root / "record.bin"
            manager.status_path = root / "status.json"
            manager.recovered_metadata_path = root / "recovered.json"
            manager.log_stream = None
            manager.phase = "weak-ready"
            manager.last_error = None
            manager.snapshot = lambda: {"history": list(manager.history)}

            with patch.object(server.subprocess, "Popen", return_value=RunningProcess()):
                result = manager.start(24, "cuda-mid")

            self.assertEqual(result["history"], [{"t": 0.0, "tested": 0}])
            self.assertEqual(manager.last_history_tested, 0)
            manager.log_stream.close()


if __name__ == "__main__":
    unittest.main()
