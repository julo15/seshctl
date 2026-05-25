#!/usr/bin/env python3
"""Gate enforcement: compare Python reference to Swift harness output.

Reads `python-reference.json` and `swift-output.json` from this directory.
For each pair of records (matched by input string), asserts:

  - `token_ids` arrays are element-wise identical (after both are right-padded
    to the same length with 0). Fails fast on the first mismatch.
  - `attention_mask` arrays are element-wise identical.
  - Embedding L-infinity norm of the difference (max absolute per-element
    diff) is ≤ 1e-3.
  - Cosine similarity between the two embeddings is > 0.9999.

Prints a per-string summary table and exits 0 on full pass, 1 on any failure.

Usage:
    python compare-parity.py
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path

EMBEDDING_TOLERANCE = 1e-3
COSINE_THRESHOLD = 0.9999
EXPECTED_TOKEN_LEN = 256
EXPECTED_EMBEDDING_DIM = 384

SCRIPT_DIR = Path(__file__).resolve().parent
PYTHON_REF_PATH = SCRIPT_DIR / "python-reference.json"
SWIFT_OUT_PATH = SCRIPT_DIR / "swift-output.json"


def _right_pad(seq: list[int], target_len: int) -> list[int]:
    if len(seq) >= target_len:
        return list(seq[:target_len])
    return list(seq) + [0] * (target_len - len(seq))


def _max_abs_diff(a: list[float], b: list[float]) -> float:
    if len(a) != len(b):
        return float("inf")
    return max(abs(x - y) for x, y in zip(a, b))


def _cosine_similarity(a: list[float], b: list[float]) -> float:
    if len(a) != len(b):
        return float("-inf")
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0.0 or nb == 0.0:
        return float("-inf")
    return dot / (na * nb)


def _load_records(path: Path, label: str) -> list[dict]:
    if not path.exists():
        print(f"ERROR: {label} not found at {path}", file=sys.stderr)
        sys.exit(2)
    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, list):
        print(
            f"ERROR: {label} at {path} is not a JSON array (got {type(data).__name__})",
            file=sys.stderr,
        )
        sys.exit(2)
    return data


def _index_by_input(records: list[dict], label: str) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for rec in records:
        text = rec.get("input")
        if not isinstance(text, str):
            print(
                f"ERROR: {label} record is missing string `input` field: {rec!r}",
                file=sys.stderr,
            )
            sys.exit(2)
        if text in out:
            print(
                f"ERROR: {label} has duplicate `input` value: {text!r}",
                file=sys.stderr,
            )
            sys.exit(2)
        out[text] = rec
    return out


def main() -> int:
    py_records = _load_records(PYTHON_REF_PATH, "python-reference.json")
    sw_records = _load_records(SWIFT_OUT_PATH, "swift-output.json")

    py_by_input = _index_by_input(py_records, "python-reference.json")
    sw_by_input = _index_by_input(sw_records, "swift-output.json")

    missing_in_swift = sorted(set(py_by_input) - set(sw_by_input))
    missing_in_python = sorted(set(sw_by_input) - set(py_by_input))
    if missing_in_swift:
        print(f"ERROR: {len(missing_in_swift)} inputs missing from swift-output.json:")
        for s in missing_in_swift:
            print(f"  - {s!r}")
        return 1
    if missing_in_python:
        print(
            f"ERROR: {len(missing_in_python)} inputs present in swift-output.json "
            f"but absent from python-reference.json:"
        )
        for s in missing_in_python:
            print(f"  - {s!r}")
        return 1

    inputs = list(py_by_input.keys())

    header = f"{'idx':>3}  {'tokens':<6}  {'mask':<6}  {'max_diff':<12}  {'cos_sim':<10}  input"
    print(header)
    print("-" * len(header))

    any_failed = False
    for idx, text in enumerate(inputs):
        py = py_by_input[text]
        sw = sw_by_input[text]

        py_tokens = _right_pad(py["token_ids"], EXPECTED_TOKEN_LEN)
        sw_tokens = _right_pad(sw["token_ids"], EXPECTED_TOKEN_LEN)
        py_mask = _right_pad(py["attention_mask"], EXPECTED_TOKEN_LEN)
        sw_mask = _right_pad(sw["attention_mask"], EXPECTED_TOKEN_LEN)

        tokens_match = py_tokens == sw_tokens
        mask_match = py_mask == sw_mask

        py_emb = py["embedding"]
        sw_emb = sw["embedding"]
        max_diff = _max_abs_diff(py_emb, sw_emb)
        cos_sim = _cosine_similarity(py_emb, sw_emb)

        emb_match = max_diff <= EMBEDDING_TOLERANCE
        cos_match = cos_sim >= COSINE_THRESHOLD

        row_ok = tokens_match and mask_match and emb_match and cos_match
        any_failed = any_failed or not row_ok

        display = text if len(text) <= 50 else text[:47] + "..."
        print(
            f"{idx:>3}  "
            f"{'ok' if tokens_match else 'FAIL':<6}  "
            f"{'ok' if mask_match else 'FAIL':<6}  "
            f"{max_diff:<12.6g}  "
            f"{cos_sim:<10.6g}  "
            f"{display}"
        )

        # On the first failure, print detail to help diagnose.
        if not row_ok:
            if not tokens_match:
                first = next(
                    (
                        i
                        for i, (a, b) in enumerate(zip(py_tokens, sw_tokens))
                        if a != b
                    ),
                    None,
                )
                print(
                    f"     tokens diverge at position {first}: "
                    f"python={py_tokens[first] if first is not None else 'n/a'} "
                    f"swift={sw_tokens[first] if first is not None else 'n/a'}"
                )
            if not mask_match:
                first = next(
                    (i for i, (a, b) in enumerate(zip(py_mask, sw_mask)) if a != b),
                    None,
                )
                print(
                    f"     attention_mask diverges at position {first}: "
                    f"python={py_mask[first] if first is not None else 'n/a'} "
                    f"swift={sw_mask[first] if first is not None else 'n/a'}"
                )
            if not emb_match:
                print(
                    f"     embedding L-inf diff {max_diff:.6g} > {EMBEDDING_TOLERANCE}"
                )
            if not cos_match:
                print(
                    f"     cosine similarity {cos_sim:.6g} < {COSINE_THRESHOLD}"
                )

    print("")
    if any_failed:
        print("RESULT: FAIL — at least one string failed the parity gate.")
        print(
            "Stop Phase 2 work, document the failure in the spike README, "
            "and re-plan with Julian."
        )
        return 1

    print(
        f"RESULT: PASS — {len(inputs)} / {len(inputs)} strings within tolerance "
        f"(L_inf <= {EMBEDDING_TOLERANCE}, cos_sim >= {COSINE_THRESHOLD})."
    )
    print("Phase 1 gate cleared. Green-light Phase 2.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
