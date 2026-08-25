import importlib.util
import unittest
from pathlib import Path


SERVER = Path(__file__).parents[1] / "backend" / "server.py"


def load_server():
    spec = importlib.util.spec_from_file_location("dashboard_server", SERVER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PacketSamplingScaleTest(unittest.TestCase):
    def test_deterministic_stride_expands_to_full_stream(self):
        server = load_server()
        value = server.expand_sampled_packet_timing({
            "packet_rate_pps": 150.0,
            "packet_rate_kpps": 0.15,
            "packet_inter_arrival_ms": 6.6666666667,
            "packet_timing_jitter_ms": 0.512,
        })

        self.assertEqual(value["packet_sample_stride"], 256)
        self.assertEqual(value["packet_rate_pps"], 38_400.0)
        self.assertEqual(value["packet_rate_kpps"], 38.4)
        self.assertAlmostEqual(value["packet_inter_arrival_ms"], 0.0260416667)
        self.assertAlmostEqual(value["packet_timing_jitter_ms"], 0.002)

    def test_drop_delta_uses_real_counter_difference_in_30_second_window(self):
        server = load_server()
        state = server.SystemMetricsState()

        self.assertEqual(state._drop_delta_30s(100.0, 7), 0)
        self.assertEqual(state._drop_delta_30s(110.0, 9), 2)
        self.assertEqual(state._drop_delta_30s(131.0, 10), 1)

    def test_bridge_direction_is_discovered_from_counter_rates(self):
        server = load_server()
        state = server.SystemMetricsState()
        samples = iter([
            {
                "tx_port": {"rx_bytes": 1000, "tx_bytes": 100},
                "rx_port": {"rx_bytes": 100, "tx_bytes": 1000},
            },
            {
                "tx_port": {"rx_bytes": 59_001_000, "tx_bytes": 200},
                "rx_port": {"rx_bytes": 200, "tx_bytes": 58_001_000},
            },
        ])
        state._bridge_nic_byte_state = lambda: next(samples)

        state._bridge_link_rates(10.0)
        value = state._bridge_link_rates(11.0)

        self.assertTrue(value["link_direction_split"])
        self.assertEqual(value["link_ingress_interface"], "tx_port")
        self.assertEqual(value["link_egress_interface"], "rx_port")
        self.assertAlmostEqual(value["link_ingress_mbps"], 472.0)
        self.assertAlmostEqual(value["link_egress_mbps"], 464.0)


if __name__ == "__main__":
    unittest.main()
