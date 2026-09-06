import importlib.util
import pathlib
import unittest

MODULE_PATH = pathlib.Path(__file__).resolve().parents[1] / "icloud-entitlements.py"
spec = importlib.util.spec_from_file_location("icloud_entitlements", MODULE_PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CloudProfileTests(unittest.TestCase):
    def test_exact_production_profile(self):
        module.validate_profile({"Entitlements": module.REQUIRED.copy()})

    def test_apple_profile_grant_forms(self):
        grants = module.REQUIRED.copy()
        grants["com.apple.developer.icloud-services"] = "*"
        grants["com.apple.developer.icloud-container-environment"] = ["Production", "Development"]
        module.validate_profile({"Entitlements": grants})

    def test_other_app_and_development_only_profiles_are_rejected(self):
        for key, value in [
            ("com.apple.developer.icloud-container-identifiers", ["iCloud.other.app"]),
            ("com.apple.developer.icloud-services", ["CloudDocuments"]),
            ("com.apple.developer.icloud-container-environment", ["Development"]),
        ]:
            with self.subTest(key=key):
                grants = module.REQUIRED.copy()
                grants[key] = value
                with self.assertRaises(ValueError):
                    module.validate_profile({"Entitlements": grants})

    def test_missing_grants_are_rejected(self):
        with self.assertRaises(ValueError):
            module.validate_profile({"Entitlements": {}})


if __name__ == "__main__":
    unittest.main()
