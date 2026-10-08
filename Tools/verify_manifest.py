#!/usr/bin/env python3
"""Verify every file in a clean source snapshot against SOURCE-MANIFEST.json."""

import hashlib
import json
from pathlib import Path


root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / "SOURCE-MANIFEST.json").read_text(encoding="utf-8"))
expected = dict(manifest["files"])
expected.update(manifest.get("generatedFiles", {}))
actual = {
    p.relative_to(root).as_posix() for p in root.rglob("*")
    if p.is_file() and ".git" not in p.relative_to(root).parts
    and p.name != "SOURCE-MANIFEST.json"
}
if actual != set(expected):
    raise SystemExit(f"snapshot file mismatch: missing={sorted(set(expected)-actual)}, "
                     f"extra={sorted(actual-set(expected))}")
for path, digest in expected.items():
    if hashlib.sha256((root / path).read_bytes()).hexdigest() != digest:
        raise SystemExit(f"snapshot hash mismatch: {path}")
print(f"Verified {len(expected)} source files")
