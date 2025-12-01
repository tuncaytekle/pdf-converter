#!/usr/bin/env python3
import os
import re
import json
import argparse
from typing import Set


NSLOCALIZED_REGEX = re.compile(
    r'NSLocalizedString\(\s*"([^"]+)"\s*,',  # captures first string argument
)


def collect_swift_keys(root_dir: str) -> Set[str]:
    """
    Walk the given directory and collect all NSLocalizedString keys from .swift files.
    """
    keys = set()

    for dirpath, _, filenames in os.walk(root_dir):
        for filename in filenames:
            if not filename.endswith(".swift"):
                continue
            full_path = os.path.join(dirpath, filename)
            try:
                with open(full_path, "r", encoding="utf-8") as f:
                    content = f.read()
            except (UnicodeDecodeError, OSError) as e:
                print(f"Warning: could not read {full_path}: {e}")
                continue

            for match in NSLOCALIZED_REGEX.finditer(content):
                key = match.group(1)
                keys.add(key)

    return keys


def collect_xcstrings_keys(xcstrings_path: str) -> Set[str]:
    """
    Load keys from a .xcstrings JSON file.

    Expected structure (Xcode 15+):
    {
      "sourceLanguage": "en",
      "strings": {
        "SomeKey": { ... },
        "AnotherKey": { ... }
      }
    }
    """
    try:
        with open(xcstrings_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (UnicodeDecodeError, OSError, json.JSONDecodeError) as e:
        raise SystemExit(f"Error: unable to read/parse xcstrings file '{xcstrings_path}': {e}")

    if "strings" not in data or not isinstance(data["strings"], dict):
        raise SystemExit(
            f"Error: file '{xcstrings_path}' does not look like a valid .xcstrings JSON (missing 'strings' dict)."
        )

    return set(data["strings"].keys())


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Cross-check NSLocalizedString keys in Swift against a .xcstrings file.\n"
            "Reports keys missing from xcstrings and keys in xcstrings that are unused in Swift."
        )
    )
    parser.add_argument(
        "swift_root",
        help="Root directory of your Swift source files (e.g. path to your project).",
    )
    parser.add_argument(
        "xcstrings_path",
        help="Path to your Localized.xcstrings file.",
    )

    args = parser.parse_args()

    print(f"📂 Scanning Swift files under: {args.swift_root}")
    swift_keys = collect_swift_keys(args.swift_root)
    print(f"➡️  Found {len(swift_keys)} NSLocalizedString key(s) in Swift.")

    print(f"\n📄 Reading xcstrings file: {args.xcstrings_path}")
    xcstrings_keys = collect_xcstrings_keys(args.xcstrings_path)
    print(f"➡️  Found {len(xcstrings_keys)} key(s) in xcstrings.")

    # Keys used in Swift but not in xcstrings
    missing_in_xcstrings = sorted(swift_keys - xcstrings_keys)
    # Keys in xcstrings but never used in Swift
    unused_in_swift = sorted(xcstrings_keys - swift_keys)

    print("\n=== 🔎 Keys used in Swift but MISSING from Localized.xcstrings ===")
    if not missing_in_xcstrings:
        print("✅ All NSLocalizedString keys in Swift are present in Localized.xcstrings.")
    else:
        for key in missing_in_xcstrings:
            print(key)
        print(f"\nTotal missing: {len(missing_in_xcstrings)}")

    print("\n=== 🧹 Keys in Localized.xcstrings but UNUSED in Swift ===")
    if not unused_in_swift:
        print("✅ No unused keys found in Localized.xcstrings.")
    else:
        for key in unused_in_swift:
            print(key)
        print(f"\nTotal unused: {len(unused_in_swift)}")


if __name__ == "__main__":
    main()

