import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

from server import BruteForceManager  # noqa: E402


class LocalVlmGateTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        self.image = root / "recovered.png"
        self.image.write_bytes(b"real recovered image bytes")
        self.status = root / "search-status.json"
        self.status.write_text(
            json.dumps({"phase": "found", "tag_verified": True}), encoding="utf-8"
        )
        self.manager = BruteForceManager.__new__(BruteForceManager)
        self.manager.status_path = self.status
        self.manager.lock = threading.Lock()
        self.manager.run_id = 12
        self.manager.phase = "found"
        self.manager.recovery = {"phase": "ready", "run_id": 12}
        self.manager.recovered_frame = {
            "run_id": 12,
            "sha256": "abc123",
            "desktop_path": str(self.image),
            "frame_id": 442804,
        }

    def tearDown(self):
        self.temporary.cleanup()

    def test_current_verified_recovered_image_is_accepted(self):
        path, metadata = self.manager.vlm_source(12, "abc123")
        self.assertEqual(path, self.image)
        self.assertEqual(metadata["frame_id"], 442804)

    def test_searching_state_is_rejected(self):
        self.manager.phase = "searching"
        with self.assertRaisesRegex(RuntimeError, "not complete"):
            self.manager.vlm_source(12, "abc123")

    def test_wrong_image_identity_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "identity"):
            self.manager.vlm_source(12, "wrong")


if __name__ == "__main__":
    unittest.main()
