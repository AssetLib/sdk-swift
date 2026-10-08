import importlib.util
import json
import unittest
from copy import deepcopy
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("generator", ROOT / "scripts/generate-catalog.py")
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)

class CodeGenerationTests(unittest.TestCase):
    def setUp(self):
        self.catalog = json.loads((ROOT / "Examples/catalog.json").read_text())

    def test_checked_in_output_is_deterministic(self):
        self.assertEqual(generator.generate(self.catalog), (ROOT / "Examples/Artwork.generated.swift").read_text())
        self.assertEqual(generator.generate(self.catalog), generator.generate(deepcopy(self.catalog)))

    def test_invalid_catalogs_fail_before_generating_source(self):
        cases = []
        for placements in [[], self.catalog["placements"] * 34]:
            value = deepcopy(self.catalog); value["placements"] = placements; cases.append(value)
        for group, member in [("travel", "ridge"), ("Travel", "store"), ("Travel", "bundle"), ("Travel", "all"), ("Store", "ridge"), ("Bundle", "ridge"), ("All", "ridge"), ("Bad group", "ridge")]:
            value = deepcopy(self.catalog); value["placements"][1]["symbol"] = [group, member]; cases.append(value)
        value = deepcopy(self.catalog); value["placements"][1]["key"] = value["placements"][0]["key"]; cases.append(value)
        value = deepcopy(self.catalog); value["placements"][0]["width"] = True; cases.append(value)
        value = deepcopy(self.catalog); value["placements"][0]["fallbackImageName"] = 'unsafe"name'; cases.append(value)
        for value in cases:
            with self.subTest(catalog=value), self.assertRaises(ValueError):
                generator.generate(value)

if __name__ == "__main__":
    unittest.main()
