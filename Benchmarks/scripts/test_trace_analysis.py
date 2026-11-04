"""Guard presentation metrics against callback counts and window-boundary bias."""

import json
from pathlib import Path
import tempfile
import unittest

from analyze_trace import analyze
from export_trace import decode


class TraceAnalysisTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        for name in ["hitches-updates", "hitches-renders", "hitches-gpu",
                     "hitches-frame-lifetimes", "display-surface-swap"]:
            self.write(name, [])
        self.write("os-signpost", [self.sign("SteadyState", "Begin", 1),
                                    self.sign("SteadyState", "End", 2)])

    def write(self, name, rows):
        (self.folder / (name + ".json")).write_text(json.dumps(rows))

    @staticmethod
    def sign(name, event, seconds):
        return {"name": name, "event-type": event, "time": str(int(seconds * 1e9)),
                "subsystem": "org.zhongyr.SCGDemo"}

    @staticmethod
    def update(swap, seconds):
        return {"swap-id": str(swap), "surface-id": "10", "display": "1",
                "process": "SCGDemo (123)", "containment-level": "0",
                "start": str(int(seconds * 1e9)), "duration": "10000000"}

    def test_display_window_differs_from_update_window_and_callback_count(self):
        # Warmup update 1 presents in steady; steady update 3 presents too late.
        updates = [self.update(1, .8), self.update(2, 1.2), self.update(3, 1.8)]
        self.write("hitches-updates", updates)
        self.write("hitches-renders", updates + [dict(updates[1], **{"containment-level": "1"})])
        self.write("display-surface-swap", [
            {"swap-id": str(swap), "surface-id": "10", "timestamp": str(int(t * 1e9))}
            for swap, t in [(1, 1.1), (2, 1.5), (3, 2.2), (99, 1.7)]])
        self.write("os-signpost", [self.sign("SteadyState", "Begin", 1),
                                    self.sign("SteadyState", "End", 2)] + [
            self.sign("UpdateToCallback", "Begin", t) for t in [.9, 1, 1.2, 1.4, 1.8, 2]])
        result = analyze(self.folder)
        self.assertEqual(result["appRequestedUpdateCount"], 4)
        self.assertEqual(result["steadyDisplaySwapCount"], 2)
        self.assertEqual(result["steadyDisplaySwapsPerSecond"], 2)
        self.assertEqual(result["steadyDisplaySwapIntervalMS"]["mean"], 400)
        self.assertEqual(result["allDisplaySwapCountWithinSteady"], 3)
        self.assertEqual(result["appUpdateCount"], 2)
        self.assertEqual(result["matchedDisplaySwapCount"], 2)
        self.assertTrue(result["displayCadenceReliable"])
        self.assertEqual(result["stagesMS"]["hitches-renders"]["count"], 2)
        self.assertFalse(result["appMetalDataAvailable"])
        self.assertIsNone(result["appMetalCommandBufferCount"])

    def test_incomplete_or_restarted_steady_window_is_rejected(self):
        begin, end = self.sign("SteadyState", "Begin", 1), self.sign("SteadyState", "End", 2)
        for signs in [[begin], [end], [begin, end, begin, end]]:
            with self.subTest(signs=signs):
                self.write("os-signpost", signs)
                with self.assertRaisesRegex(ValueError, "exactly one complete"):
                    analyze(self.folder)

    def test_sparse_swap_stream_is_not_reported_as_reliable_cadence(self):
        self.write("hitches-updates", [self.update(1, 1.1), self.update(2, 1.2), self.update(3, 1.3)])
        self.write("display-surface-swap", [
            {"swap-id": "1", "surface-id": "10", "timestamp": "1400000000"}])
        result = analyze(self.folder)
        self.assertFalse(result["displayCadenceReliable"])
        self.assertAlmostEqual(result["displaySwapCorrelationCoverage"], 1 / 3)

    def test_swap_before_update_is_rejected(self):
        self.write("hitches-updates", [self.update(1, 1.5)])
        self.write("display-surface-swap", [
            {"swap-id": "1", "surface-id": "10", "timestamp": "1400000000"}])
        with self.assertRaisesRegex(ValueError, "precedes"):
            analyze(self.folder)

    def test_repeated_table_without_schema_keeps_columns_and_resolves_refs(self):
        path = self.folder / "signposts.xml"
        path.write_text('''<trace-query-result>
          <node><schema><col><mnemonic>name</mnemonic></col>
            <col><mnemonic>event-type</mnemonic></col></schema>
            <row><string id="1">SteadyState</string><string>Begin</string></row></node>
          <node><row><string ref="1"/><string>End</string></row></node>
        </trace-query-result>''')
        self.assertEqual(decode(path), [{"name": "SteadyState", "event-type": "Begin"},
                                         {"name": "SteadyState", "event-type": "End"}])


if __name__ == "__main__":
    unittest.main()
