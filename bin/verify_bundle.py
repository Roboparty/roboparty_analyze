#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0
# Copyright (C) 2026 RoboParty

"""Verify an analyze session directory or exported diagnostic ZIP.

Checks files.sha256 against the actual files and reports manifest metadata
gaps. Exit code 1 on missing files or checksum mismatches; metadata gaps are
reported as warnings so old evidence remains inspectable.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys
import zipfile


def _hash(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _parse_sums(text: str) -> dict[str, str]:
    result = {}
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) != 2:
            raise ValueError(f"invalid checksum line: {line[:80]}")
        digest, name = parts
        result[name.lstrip("*")] = digest.lower()
    return result


def _manifest_warnings(manifest: dict) -> list[str]:
    warnings = []
    if not any(key in manifest for key in ("started_at", "started_at_unix", "captured_at")):
        warnings.append("manifest has no start time")
    if not any(key in manifest for key in ("ended_at", "ended_at_unix")):
        warnings.append("manifest has no end time")
    if not any(key in manifest for key in ("serial", "device_id", "hostname")):
        warnings.append("manifest has no device identity")
    return warnings


def verify_directory(root: Path) -> dict:
    sums_path = root / "files.sha256"
    manifest_path = root / "manifest.json"
    result = {"ok": False, "kind": "directory", "path": str(root),
              "missing": [], "mismatch": [], "extras": [], "warnings": []}
    if not sums_path.is_file():
        result["missing"].append("files.sha256")
        return result
    expected = _parse_sums(sums_path.read_text(encoding="utf-8"))
    actual = {str(path.relative_to(root)): path for path in root.rglob("*") if path.is_file()}
    result["extras"] = sorted(set(actual) - set(expected) - {"files.sha256"})
    for name, digest in expected.items():
        path = root / name
        if not path.is_file():
            result["missing"].append(name)
        elif _hash(path.read_bytes()) != digest:
            result["mismatch"].append(name)
    if manifest_path.is_file():
        try:
            result["warnings"] = _manifest_warnings(json.loads(manifest_path.read_text(encoding="utf-8")))
        except ValueError:
            result["warnings"].append("manifest.json is not valid JSON")
    else:
        result["missing"].append("manifest.json")
    result["ok"] = not result["missing"] and not result["mismatch"]
    return result


def verify_zip(path: Path) -> dict:
    result = {"ok": False, "kind": "zip", "path": str(path),
              "missing": [], "mismatch": [], "extras": [], "warnings": []}
    with zipfile.ZipFile(path) as archive:
        names = [name for name in archive.namelist() if not name.endswith("/")]
        sums_name = next((name for name in names if name.endswith("files.sha256")), None)
        if sums_name is None:
            result["missing"].append("files.sha256")
            return result
        base = sums_name[:-len("files.sha256")]
        expected = _parse_sums(archive.read(sums_name).decode("utf-8"))
        for name, digest in expected.items():
            member = base + name
            if member not in names:
                result["missing"].append(name)
            elif _hash(archive.read(member)) != digest:
                result["mismatch"].append(name)
        manifest_name = next((name for name in names if name.endswith("manifest.json")), None)
        if manifest_name:
            try:
                result["warnings"] = _manifest_warnings(
                    json.loads(archive.read(manifest_name).decode("utf-8")))
            except ValueError:
                result["warnings"].append("manifest.json is not valid JSON")
        else:
            result["missing"].append("manifest.json")
        result["extras"] = sorted(set(names) - {base + name for name in expected}
                                  - {sums_name, manifest_name})
    result["ok"] = not result["missing"] and not result["mismatch"]
    return result


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    path = Path(args.path)
    if not path.exists():
        print(f"not found: {path}", file=sys.stderr)
        return 1
    result = verify_zip(path) if path.is_file() else verify_directory(path)
    if args.json:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        print(f"{'ok' if result['ok'] else 'FAIL'} {result['kind']} {result['path']}")
        for key in ("missing", "mismatch", "extras", "warnings"):
            if result[key]:
                print(f"  {key}: {result[key]}")
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
