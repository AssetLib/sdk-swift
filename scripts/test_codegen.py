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

    def test_description_literals_are_safe_and_raw_images_stay_native(self):
        self.catalog["placements"][0]["bundledAccessibility"] = {
            "defaultLocale": "en", "descriptions": {"en": 'A "coast" \\(unsafe)\n🌊', "th": "ชายฝั่ง"}
        }
        source = generator.generate(self.catalog)
        self.assertIn('var `coast`: Image', source)
        self.assertIn('Image(decorative: "coast", bundle: bundle)', source)
        self.assertIn('func `coastArtwork`', source)
        self.assertIn('\\\\(unsafe)', source)
        self.assertIn('\\u{a}\\u{1f30a}', source)

    def test_invalid_descriptions_and_generated_helper_collisions_fail(self):
        for metadata in [None, {}, {"defaultLocale": "en", "descriptions": {"en": "\ufeff\u00a0"}},
                         {"defaultLocale": "en", "descriptions": {"en": "Coast", "EN": "Other"}},
                         {"defaultLocale": "en", "descriptions": {"en": "🌿" * 501}},
                         {"defaultLocale": "fr", "descriptions": {"en": "Coast"}}]:
            value = deepcopy(self.catalog); value["placements"][0]["bundledAccessibility"] = metadata
            with self.subTest(metadata=metadata), self.assertRaises(ValueError):
                generator.generate(value)
        value = deepcopy(self.catalog); value["placements"][1]["symbol"] = ["Travel", "coastArtwork"]
        with self.assertRaises(ValueError):
            generator.generate(value)
        for dependency in ["Locale", "AssetAccessibility", "Image", "AssetImageStore", "AssetReference"]:
            value = deepcopy(self.catalog); value["placements"][0]["symbol"] = [dependency, "coast"]
            with self.subTest(dependency=dependency), self.assertRaises(ValueError):
                generator.generate(value)

    def test_template_rendering_reaches_only_template_references(self):
        original = generator.generate(self.catalog)
        value = deepcopy(self.catalog); value["placements"][0]["rendering"] = "original"
        self.assertEqual(generator.generate(value), original)
        value["placements"][0]["rendering"] = "template"
        source = generator.generate(value)
        self.assertIn('AssetReference(key: "travel.coast", width: 1200, height: 900, rendering: .template)', source)
        self.assertIn('AssetReference(key: "travel.ridge", width: 1200, height: 900)\n', source)
        self.assertEqual(source.count("rendering:"), 1)
        for rendering in ["Template", "palette", "", None, True]:
            value["placements"][0]["rendering"] = rendering
            with self.subTest(rendering=rendering), self.assertRaisesRegex(ValueError, "rendering"):
                generator.generate(value)

if __name__ == "__main__":
    unittest.main()
