#!/usr/bin/env python3
"""Top-K retrieval parity check.

For each string i, treat it as a query and rank all other strings by cosine
similarity. Compare the Python-side ranking to the Swift-side ranking.
This is the parity test that actually predicts user-visible search quality:
even if embeddings drift, if top-K rankings agree we ship.

Usage:
    python compare-topk.py [--swift swift-output.json] [--python python-reference.json] [--k 5]

Exits 0 on full agreement, 1 on any per-query disagreement.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--swift", default="swift-output.json")
    parser.add_argument("--python", default="python-reference.json")
    parser.add_argument("--k", type=int, default=5)
    args = parser.parse_args()

    swift_records = json.loads(Path(args.swift).read_text())
    python_records = json.loads(Path(args.python).read_text())

    if len(swift_records) != len(python_records):
        print(
            f"ERROR: record count mismatch — swift={len(swift_records)} python={len(python_records)}",
            file=sys.stderr,
        )
        return 1

    # Inputs must align by position (both files were produced from the same
    # reference-strings.txt in order).
    for i, (s, p) in enumerate(zip(swift_records, python_records)):
        if s["input"] != p["input"]:
            print(
                f"ERROR: input mismatch at index {i}: swift={s['input']!r} python={p['input']!r}",
                file=sys.stderr,
            )
            return 1

    swift_emb = np.array([r["embedding"] for r in swift_records], dtype=np.float64)
    python_emb = np.array([r["embedding"] for r in python_records], dtype=np.float64)
    inputs = [r["input"] for r in swift_records]
    n = len(inputs)
    k = min(args.k, n - 1)

    swift_topk: list[list[int]] = []
    python_topk: list[list[int]] = []
    for i in range(n):
        # Embeddings are L2-normalized, so dot product == cosine similarity.
        swift_scores = swift_emb @ swift_emb[i]
        python_scores = python_emb @ python_emb[i]
        # Exclude self-similarity.
        swift_scores[i] = -np.inf
        python_scores[i] = -np.inf
        swift_topk.append(np.argsort(-swift_scores)[:k].tolist())
        python_topk.append(np.argsort(-python_scores)[:k].tolist())

    # Granular stats: top-1 / top-3-set / top-K-set / top-K-list agreement counts.
    # The list comparison is strict (order matters). The set comparison is
    # relevant for top-K retrieval because near-tied scores can flip positions
    # in the ranked list without changing which documents the user sees.
    top1_agree = sum(1 for i in range(n) if swift_topk[i][0] == python_topk[i][0])
    top3_set_agree = sum(
        1
        for i in range(n)
        if set(swift_topk[i][: min(3, k)]) == set(python_topk[i][: min(3, k)])
    )
    topk_set_agree = sum(
        1 for i in range(n) if set(swift_topk[i]) == set(python_topk[i])
    )
    topk_list_agree = sum(1 for i in range(n) if swift_topk[i] == python_topk[i])

    diff_count = 0
    print(f"{'idx':>3}  {'agree':<5}  query")
    print("-" * 80)
    for i in range(n):
        agree = swift_topk[i] == python_topk[i]
        if not agree:
            diff_count += 1
        label = "ok" if agree else "DIFF"
        truncated = inputs[i][:65] + ("..." if len(inputs[i]) > 65 else "")
        print(f"{i:>3}  {label:<5}  {truncated}")
        if not agree:
            print(f"     python top-{k}: {python_topk[i]}")
            print(f"     swift  top-{k}: {swift_topk[i]}")

    print()
    print(f"Top-1 agreement:      {top1_agree:>3}/{n}")
    print(f"Top-3 set agreement:  {top3_set_agree:>3}/{n}")
    print(f"Top-{k} set agreement:  {topk_set_agree:>3}/{n}")
    print(f"Top-{k} list agreement: {topk_list_agree:>3}/{n}")
    print()

    if topk_list_agree == n:
        print(f"RESULT: PASS — top-{k} retrieval lists match for all {n} queries.")
        return 0
    else:
        print(f"RESULT: FAIL — top-{k} lists disagree on {diff_count}/{n} queries.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
