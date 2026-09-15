#!/usr/bin/env python3
"""Reverse the maintained patch, verify upstream hashes, then verify its forward apply."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent
manifest = json.loads((root / "upstream-files.json").read_text())["files"]
patch = (root / "scorebug.patch").read_bytes()
added = ['HaishinKit/Sources/Util/PublishingQueue.swift', 'HaishinKit/Sources/Codec/VerifiedVideoBitRate.swift', 'HaishinKit/Sources/Codec/VideoCodecInvalidation.swift']
paths = list(manifest) + added

with tempfile.TemporaryDirectory(prefix="scorebug-sdk-provenance-") as directory:
    baseline = Path(directory)
    for relative in paths:
        target = baseline / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / relative, target)
    subprocess.run(["patch", "--batch", "-R", "-p1"], cwd=baseline,
                   input=patch, check=True, stdout=subprocess.PIPE)
    for relative, expected in manifest.items():
        actual = hashlib.sha256((baseline / relative).read_bytes()).hexdigest()
        if actual != expected:
            raise SystemExit(f"Upstream hash mismatch: {relative}: {actual} != {expected}")
    for relative in added:
        if (baseline / relative).exists():
            raise SystemExit(f"Added file was not removed by reverse patch: {relative}")
    subprocess.run(["patch", "--batch", "-p1"], cwd=baseline,
                   input=patch, check=True, stdout=subprocess.PIPE)
    for relative in paths:
        if (baseline / relative).read_bytes() != (root / relative).read_bytes():
            raise SystemExit(f"Forward patch mismatch: {relative}")
    print(f"Verified {len(manifest)} original upstream SHA-256 hashes and exact patch round trip.")
