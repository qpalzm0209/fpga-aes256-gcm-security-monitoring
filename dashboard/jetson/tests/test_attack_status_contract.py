import importlib.util
import unittest
from pathlib import Path


SERVER = Path(__file__).parents[1] / "backend" / "server.py"


def load_server():
    spec = importlib.util.spec_from_file_location("dashboard_server", SERVER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class AttackStatusContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = load_server()

    def test_tamper_exposes_only_attacker_side_fields(self):
        result = self.server.build_page2_attack_status({
            "attack_state": {
                "active": True, "mode": "tamper", "owner": "page2",
                "rate": 20, "run_id": 13,
            },
            "selected_mode": "tamper", "selected_rate": 20,
            "elapsed_s": 4.25,
            "engine": {
                "mode": "tamper", "eligible_frames_total": 60,
                "modified_frames_total": 5, "modified_packets_total": 5,
                "last_session_id": "0x79f17538", "last_frame_id": 6954,
                "last_packet_index": 0,
                "packet_rate_kpps": 39.0,
            },
        })
        self.assertEqual(result["source_role"], "jetson-attacker")
        self.assertTrue(result["active"])
        self.assertEqual(result["mode"], "tamper")
        self.assertEqual(result["rate"], 20)
        self.assertEqual(result["count"], 5)
        self.assertEqual(result["runtime_ms"], 4250)
        self.assertEqual(result["last_target"], {"frame_id": 6954, "packet_id": 0})
        self.assertNotIn("packet_rate_kpps", result)
        self.assertNotIn("tamper", result)
        self.assertNotIn("replay", result)
        self.assertNotIn("eligible_frames", result)
        self.assertNotIn("run_id", result)
        self.assertNotIn("observed_session_id", result)

    def test_replay_does_not_invent_target_before_injection(self):
        result = self.server.build_page2_attack_status({
            "attack_state": {
                "active": True, "mode": "replay", "owner": "page2",
                "rate": 10, "run_id": 88,
            },
            "selected_mode": "replay", "selected_rate": 10,
            "elapsed_s": 1.0,
            "engine": {
                "mode": "replay", "eligible_frames_total": 3,
                "injected_frames_total": 0, "source_frame_id": 10749,
                "source_session_id": "0x49688523",
            },
        })
        self.assertEqual(result["mode"], "replay")
        self.assertEqual(result["count"], 0)
        self.assertNotIn("last_target", result)

    def test_stopped_attack_retains_last_real_result(self):
        result = self.server.build_page2_attack_status({
            "attack_state": {
                "active": False, "mode": "none", "owner": None, "rate": None,
            },
            "selected_mode": "tamper", "selected_rate": 40,
            "elapsed_s": 30.125,
            "engine": {
                "mode": "tamper", "modified_frames_total": 430,
                "modified_packets_total": 430, "last_frame_id": 89412,
                "last_packet_index": 512,
            },
        })
        self.assertFalse(result["active"])
        self.assertEqual(result["mode"], "tamper")
        self.assertEqual(result["rate"], 40)
        self.assertEqual(result["count"], 430)
        self.assertEqual(result["runtime_ms"], 30125)
        self.assertEqual(result["last_target"], {
            "frame_id": 89412, "packet_id": 512,
        })


if __name__ == "__main__":
    unittest.main()
