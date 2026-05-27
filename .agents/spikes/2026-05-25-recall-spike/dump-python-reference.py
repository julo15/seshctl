#!/usr/bin/env python3
"""Dump token IDs + embeddings for the spike reference strings via recall's exact path.

This script reproduces `recall/embedding.py` byte-for-byte: HF `tokenizers`
(NOT transformers PyTorch) for tokenization, `onnxruntime` for inference,
max_length=256, padding to max, truncation enabled, mean-pool over the
attention mask, L2-normalize. The output is the ground truth that the Swift
harness must match.

Path resolution for the model + tokenizer:
1. If `~/.recall/models/all-MiniLM-L6-v2/onnx/model.onnx` and
   `~/.recall/models/all-MiniLM-L6-v2/tokenizer.json` already exist (recall
   was installed and run at least once on this machine), use them directly.
2. Otherwise download from Hugging Face into that same directory — same
   behavior as recall/embedding.py's `_ensure_model_files`.

Output: `python-reference.json` next to this script. Schema is a JSON array
of records, one per input string:

    {
      "input": "...",
      "token_ids": [101, 7592, ..., 0, 0, ...],     # length 256
      "attention_mask": [1, 1, ..., 0, 0, ...],     # length 256
      "embedding": [0.0432, -0.0192, ...]           # length 384, L2-normalized
    }

Usage:
    python dump-python-reference.py

The 20 input strings are read from `reference-strings.txt` (one per line,
blank lines ignored).
"""

from __future__ import annotations

import json
import os
import sys
import urllib.request
from pathlib import Path

import numpy as np

MAX_LEN = 256
EMBEDDING_DIM = 384
BATCH_SIZE = 64

SCRIPT_DIR = Path(__file__).resolve().parent
REFERENCE_STRINGS_PATH = SCRIPT_DIR / "reference-strings.txt"
OUTPUT_PATH = SCRIPT_DIR / "python-reference.json"

MODEL_DIR = Path(os.path.expanduser("~/.recall/models/all-MiniLM-L6-v2"))
ONNX_PATH = MODEL_DIR / "onnx" / "model.onnx"
TOKENIZER_PATH = MODEL_DIR / "tokenizer.json"

ONNX_URL = (
    "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/"
    "resolve/main/onnx/model.onnx"
)
TOKENIZER_URL = (
    "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/"
    "resolve/main/tokenizer.json"
)


def _download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f">> Downloading {dest.name} from {url}")
    urllib.request.urlretrieve(url, str(dest))


def _ensure_model_files() -> None:
    if not ONNX_PATH.exists():
        _download(ONNX_URL, ONNX_PATH)
    else:
        print(f">> Reusing existing {ONNX_PATH}")
    if not TOKENIZER_PATH.exists():
        _download(TOKENIZER_URL, TOKENIZER_PATH)
    else:
        print(f">> Reusing existing {TOKENIZER_PATH}")


def _read_reference_strings() -> list[str]:
    with REFERENCE_STRINGS_PATH.open("r", encoding="utf-8") as f:
        raw = f.read().splitlines()
    strings = [line for line in raw if line.strip()]
    if len(strings) != 20:
        print(
            f"ERROR: expected 20 reference strings, got {len(strings)} "
            f"in {REFERENCE_STRINGS_PATH}",
            file=sys.stderr,
        )
        sys.exit(1)
    return strings


def main() -> int:
    import onnxruntime as ort
    from tokenizers import Tokenizer

    _ensure_model_files()

    print(">> Loading ONNX session (CPUExecutionProvider, matching recall)")
    session = ort.InferenceSession(str(ONNX_PATH), providers=["CPUExecutionProvider"])
    input_names = {inp.name for inp in session.get_inputs()}

    print(">> Loading HF tokenizer + enabling padding/truncation to max_length=256")
    tokenizer = Tokenizer.from_file(str(TOKENIZER_PATH))
    # IMPORTANT: pad to a fixed length so token_ids are length-256 across the
    # board. recall/embedding.py uses dynamic padding (longest-in-batch) — for
    # parity testing we want fixed-length output so the Swift harness comparison
    # is dimension-stable. The embeddings are unaffected because the attention
    # mask correctly identifies the padding positions.
    tokenizer.enable_padding(pad_id=0, pad_token="[PAD]", length=MAX_LEN)
    tokenizer.enable_truncation(max_length=MAX_LEN)

    texts = _read_reference_strings()
    print(f">> Encoding {len(texts)} reference strings (batch_size={BATCH_SIZE})")

    records: list[dict] = []

    for start in range(0, len(texts), BATCH_SIZE):
        batch_texts = texts[start : start + BATCH_SIZE]
        encodings = tokenizer.encode_batch(batch_texts)

        input_ids = np.array([e.ids for e in encodings], dtype=np.int64)
        attention_mask = np.array(
            [e.attention_mask for e in encodings], dtype=np.int64
        )

        if input_ids.shape != (len(batch_texts), MAX_LEN):
            print(
                f"ERROR: tokenizer produced shape {input_ids.shape}, "
                f"expected ({len(batch_texts)}, {MAX_LEN}). enable_padding "
                f"length= argument may have been ignored.",
                file=sys.stderr,
            )
            return 1

        feeds: dict[str, np.ndarray] = {
            "input_ids": input_ids,
            "attention_mask": attention_mask,
        }
        if "token_type_ids" in input_names:
            feeds["token_type_ids"] = np.zeros_like(input_ids)

        outputs = session.run(None, feeds)
        token_embeddings = outputs[0]  # (batch, seq_len, 384)

        # Mean pooling — match recall/embedding.py exactly.
        mask_expanded = attention_mask[:, :, np.newaxis].astype(np.float32)
        sum_embeddings = np.sum(token_embeddings * mask_expanded, axis=1)
        sum_mask = np.clip(mask_expanded.sum(axis=1), a_min=1e-9, a_max=None)
        mean_pooled = sum_embeddings / sum_mask

        # L2 normalize — match recall/embedding.py exactly.
        norms = np.linalg.norm(mean_pooled, axis=1, keepdims=True)
        norms = np.clip(norms, a_min=1e-9, a_max=None)
        normalized = (mean_pooled / norms).astype(np.float32)

        if normalized.shape[1] != EMBEDDING_DIM:
            print(
                f"ERROR: embedding dim {normalized.shape[1]} != "
                f"expected {EMBEDDING_DIM}",
                file=sys.stderr,
            )
            return 1

        for i, text in enumerate(batch_texts):
            records.append(
                {
                    "input": text,
                    "token_ids": [int(x) for x in input_ids[i].tolist()],
                    "attention_mask": [int(x) for x in attention_mask[i].tolist()],
                    "embedding": [float(x) for x in normalized[i].tolist()],
                }
            )

    with OUTPUT_PATH.open("w", encoding="utf-8") as f:
        json.dump(records, f, indent=2)

    print("")
    print("Done.")
    print(f"  Wrote {len(records)} records to {OUTPUT_PATH}")
    print("")
    print("Next: build + run the Swift harness, then python compare-parity.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
