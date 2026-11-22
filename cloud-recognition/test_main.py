"""Safety and schema regression tests. No network or AI calls."""
import unittest
from main import normalize, number

class NormalizationTests(unittest.TestCase):
    def test_missing_measurements_stay_missing(self):
        result = normalize({"holes":[{"x":12.5,"y":None,"diameter":6}]})
        self.assertIsNone(result["width"])
        self.assertIsNone(result["holes"][0]["y"])
        self.assertFalse(result["verified"])

    def test_refuse_hallucinated_invalid_dimensions(self):
        for value in [True, "25", -1, float("inf"), float("nan"), 100001]:
            self.assertIsNone(number(value))
        self.assertIsNone(normalize({"width":0})["width"])

    def test_reject_overlarge_hole_list(self):
        with self.assertRaises(ValueError):
            normalize({"holes":[{}] * 151})

    def test_notes_and_metadata_bounded(self):
        result=normalize({"material":"a"*1000, "warnings":["w"*1000]*100})
        self.assertEqual(len(result["material"]),100)
        self.assertEqual(len(result["warnings"]),30)
        self.assertEqual(len(result["warnings"][0]),300)

    def test_reject_non_objects(self):
        with self.assertRaises(ValueError):
            normalize([])
        self.assertEqual(normalize({"holes":[1,{},None]})["holes"],
                         [{"x":None,"y":None,"diameter":None}])

if __name__=="__main__":
    unittest.main()
