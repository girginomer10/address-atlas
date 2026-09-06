#!/usr/bin/env python3
"""Bind production CloudKit signing to the exact authorized provisioning profile."""
import plistlib
import sys
from pathlib import Path

CONTAINER = "iCloud.com.addressatlas.mac"
REQUIRED = {
    "com.apple.developer.icloud-container-identifiers": [CONTAINER],
    "com.apple.developer.icloud-services": ["CloudKit"],
    "com.apple.developer.icloud-container-environment": "Production",
}


def validate_profile(profile):
    entitlements = profile.get("Entitlements", {})
    for key, expected in REQUIRED.items():
        actual = entitlements.get(key)
        if isinstance(expected, list):
            if key == "com.apple.developer.icloud-services" and actual in ("*", ["*"]):
                continue
            if not isinstance(actual, list) or not all(value in actual for value in expected):
                raise ValueError(f"Distribution profile does not authorize {key}")
        elif actual != expected and not (isinstance(actual, list) and expected in actual):
            raise ValueError(f"Distribution profile must authorize {key}={expected}")


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("prepare", "validate"):
        raise ValueError("Usage: icloud-entitlements.py prepare|validate PROFILE ENTITLEMENTS")
    mode, profile_path, target_path = sys.argv[1:]
    with open(profile_path, "rb") as source:
        validate_profile(plistlib.load(source))
    target = Path(target_path)
    with target.open("rb") as source:
        entitlements = plistlib.load(source)
    if mode == "prepare":
        entitlements.update(REQUIRED)
        with target.open("wb") as output:
            plistlib.dump(entitlements, output)
    elif any(entitlements.get(key) != value for key, value in REQUIRED.items()):
        raise ValueError("Signed CloudKit entitlements do not match the production container")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        sys.exit(str(error))
