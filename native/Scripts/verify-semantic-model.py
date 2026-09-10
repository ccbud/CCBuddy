#!/usr/bin/env python3
"""Verify pinned offline model artifacts with the Python standard library only."""

import hashlib
import json
import pathlib


def main():
    root = pathlib.Path(__file__).resolve().parents[1] / "Resources" / "SemanticSearch"
    manifest = json.loads((root / "manifest.json").read_text())
    required = {
        "MiniLMSemantic.mlpackage/Data/com.apple.CoreML/model.mlmodel",
        "MiniLMSemantic.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
        "MiniLMSemantic.mlpackage/Manifest.json",
        "minilm-vocab.txt", "MODEL-CARD.md", "MiniLM-LICENSE.txt",
    }
    if not required.issubset(manifest["sha256"]):
        raise SystemExit("Semantic model manifest is missing required artifacts")
    for relative, expected in manifest["sha256"].items():
        file = (root / relative).resolve()
        if not file.is_relative_to(root.resolve()):
            raise SystemExit(f"Invalid artifact path: {relative}")
        actual = hashlib.sha256(file.read_bytes()).hexdigest()
        if actual != expected:
            raise SystemExit(f"Semantic model checksum mismatch: {relative}")
    if manifest["license"] != "Apache-2.0" or manifest["max_tokens"] != 128 or manifest["dimensions"] != 384:
        raise SystemExit("Unexpected semantic model contract")
    if not all(score > 0.995 for score in manifest["reference_cosine_similarities"]):
        raise SystemExit("Semantic model conversion parity did not meet the required threshold")
    print(f"Verified {len(manifest['sha256'])} offline semantic model artifacts ({manifest['model']}).")


if __name__ == "__main__":
    main()
