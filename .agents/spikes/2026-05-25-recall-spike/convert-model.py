#!/usr/bin/env python3
"""Convert sentence-transformers/all-MiniLM-L6-v2 from HF to CoreML mlprogram + INT8.

Outputs (in this script's directory):
  - all-MiniLM-L6-v2-int8.mlpackage  — CoreML model. Input: (input_ids[1,256] int32,
    attention_mask[1,256] int32). Output: token_embeddings[1,256,384] float.
  - tokenizer.json                    — copied from the HF cache.
  - tokenizer_config.json             — copied from the HF cache. Required by
    swift-transformers `AutoTokenizer.from(modelFolder:)`.

Mean pooling + L2 normalization are NOT baked into the CoreML graph. The Swift
harness and dump-python-reference.py do those steps themselves so the graph
stays minimal and the consumer code matches recall/embedding.py one-to-one.

Asserts: the .mlpackage size is between 15MB and 60MB. Outside that band,
the script exits non-zero and the caller is expected to stop and reconsider
quantization config rather than silently shipping a degraded model.

Usage:
    python convert-model.py
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

import numpy as np
import torch

import coremltools as ct
from coremltools.optimize.coreml import (
    OpLinearQuantizerConfig,
    OptimizationConfig,
    linear_quantize_weights,
)
from transformers import AutoModel, AutoTokenizer

MODEL_ID = "sentence-transformers/all-MiniLM-L6-v2"
MAX_SEQ_LEN = 256
EMBEDDING_DIM = 384

SCRIPT_DIR = Path(__file__).resolve().parent
OUT_MLPACKAGE = SCRIPT_DIR / "all-MiniLM-L6-v2-int8.mlpackage"
OUT_TOKENIZER_JSON = SCRIPT_DIR / "tokenizer.json"
OUT_TOKENIZER_CONFIG = SCRIPT_DIR / "tokenizer_config.json"

# Hard size bounds in MB. Outside this band the script fails loudly.
MIN_SIZE_MB = 15.0
MAX_SIZE_MB = 60.0


class TokenEmbeddingsWrapper(torch.nn.Module):
    """Thin wrapper exposing just the raw token embeddings.

    sentence-transformers ships a Transformer + Pooling + Normalize layer
    stack, but we deliberately stop at the Transformer's last_hidden_state
    so that mean pooling + L2 normalize happen in the consumer (Swift +
    Accelerate) — same pattern as recall/embedding.py.
    """

    def __init__(self, base_model: torch.nn.Module) -> None:
        super().__init__()
        self.base = base_model

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        outputs = self.base(input_ids=input_ids, attention_mask=attention_mask)
        # last_hidden_state: [batch, seq_len, hidden]
        return outputs.last_hidden_state


def _dir_size_bytes(path: Path) -> int:
    total = 0
    for child in path.rglob("*"):
        if child.is_file():
            total += child.stat().st_size
    return total


def main() -> int:
    print(f">> Loading {MODEL_ID} from Hugging Face")
    tokenizer = AutoTokenizer.from_pretrained(MODEL_ID)
    base_model = AutoModel.from_pretrained(MODEL_ID, torchscript=True)
    base_model.eval()

    wrapped = TokenEmbeddingsWrapper(base_model).eval()

    print(f">> Tracing the model (max_seq_len={MAX_SEQ_LEN})")
    dummy_input_ids = torch.zeros((1, MAX_SEQ_LEN), dtype=torch.int32)
    dummy_attention_mask = torch.ones((1, MAX_SEQ_LEN), dtype=torch.int32)
    with torch.no_grad():
        traced = torch.jit.trace(
            wrapped,
            (dummy_input_ids.long(), dummy_attention_mask.long()),
        )

    # Quick sanity check on the traced model's output shape.
    with torch.no_grad():
        sanity_out = traced(dummy_input_ids.long(), dummy_attention_mask.long())
    expected_shape = (1, MAX_SEQ_LEN, EMBEDDING_DIM)
    if tuple(sanity_out.shape) != expected_shape:
        print(
            f"ERROR: traced model output shape {tuple(sanity_out.shape)} != "
            f"expected {expected_shape}",
            file=sys.stderr,
        )
        return 1

    print(">> Converting to CoreML mlprogram")
    input_ids_spec = ct.TensorType(
        name="input_ids",
        shape=(1, MAX_SEQ_LEN),
        dtype=np.int32,
    )
    attention_mask_spec = ct.TensorType(
        name="attention_mask",
        shape=(1, MAX_SEQ_LEN),
        dtype=np.int32,
    )

    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[input_ids_spec, attention_mask_spec],
        outputs=[ct.TensorType(name="token_embeddings")],
        minimum_deployment_target=ct.target.macOS14,
        compute_units=ct.ComputeUnit.ALL,
        compute_precision=ct.precision.FLOAT16,
    )

    print(">> Applying INT8 linear weight quantization")
    op_config = OpLinearQuantizerConfig(mode="linear_symmetric", weight_threshold=512)
    config = OptimizationConfig(global_config=op_config)
    quantized = linear_quantize_weights(mlmodel, config=config)

    if OUT_MLPACKAGE.exists():
        print(f">> Removing existing {OUT_MLPACKAGE.name}")
        shutil.rmtree(OUT_MLPACKAGE)

    print(f">> Saving {OUT_MLPACKAGE.name}")
    quantized.save(str(OUT_MLPACKAGE))

    # Copy tokenizer.json + tokenizer_config.json next to the .mlpackage so the
    # Swift harness can point AutoTokenizer.from(modelFolder:) at this directory.
    print(">> Copying tokenizer.json + tokenizer_config.json")
    backend_tokenizer = tokenizer.backend_tokenizer
    backend_tokenizer.save(str(OUT_TOKENIZER_JSON))
    # transformers's AutoTokenizer also writes a tokenizer_config.json. Round-trip
    # by saving the full HF tokenizer to a temp dir and copying the config out.
    tmp_dir = SCRIPT_DIR / ".hf-tokenizer-tmp"
    if tmp_dir.exists():
        shutil.rmtree(tmp_dir)
    tokenizer.save_pretrained(str(tmp_dir))
    src_config = tmp_dir / "tokenizer_config.json"
    if not src_config.exists():
        print(
            f"ERROR: HF did not produce tokenizer_config.json at {src_config}",
            file=sys.stderr,
        )
        return 1
    shutil.copyfile(src_config, OUT_TOKENIZER_CONFIG)
    shutil.rmtree(tmp_dir)

    # Size gate.
    size_bytes = _dir_size_bytes(OUT_MLPACKAGE)
    size_mb = size_bytes / (1024.0 * 1024.0)
    print(f">> .mlpackage size: {size_mb:.2f} MB ({size_bytes} bytes)")
    if size_mb < MIN_SIZE_MB or size_mb > MAX_SIZE_MB:
        print(
            f"ERROR: .mlpackage size {size_mb:.2f} MB outside expected band "
            f"[{MIN_SIZE_MB}, {MAX_SIZE_MB}] MB. Reconsider quantization config "
            f"before proceeding.",
            file=sys.stderr,
        )
        return 1

    print("")
    print("Done.")
    print(f"  CoreML model:        {OUT_MLPACKAGE}")
    print(f"  tokenizer.json:      {OUT_TOKENIZER_JSON}")
    print(f"  tokenizer_config.json: {OUT_TOKENIZER_CONFIG}")
    print("")
    print("Next: python dump-python-reference.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
