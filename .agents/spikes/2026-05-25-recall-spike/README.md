# Recall parity spike — Phase 1 (2026-05-25)

This spike is a throwaway test rig that proves the load-bearing assumption of
the v0.5.0 native-recall rewrite: a CoreML-converted, INT8-quantized
`sentence-transformers/all-MiniLM-L6-v2` driven by
[`huggingface/swift-transformers`](https://github.com/huggingface/swift-transformers)
produces tokenization and embeddings that match the Python `tokenizers` +
`onnxruntime` pipeline used by `recall/embedding.py` today.

If parity holds, Phase 2 begins. If parity fails on a single string, we stop
and re-plan (likely swap the tokenizer library, swap the embedding model, or
revisit the "Swift rewrite" decision in favor of bundling onnxruntime-swift).

See the parent plan at
`.agents/plans/2026-05-25-0055-native-recall-rewrite.md`, Implementation Steps
→ Step 1.

## Gate criterion

For each of the 20 reference strings in `reference-strings.txt`:

1. **Token IDs must be element-wise identical** between the Python reference
   and the Swift harness (after both are right-padded to length 256 with 0).
2. **Embeddings must agree to L-infinity norm difference ≤ 1e-3**. That is,
   `max(abs(swift_vec - python_vec)) ≤ 1e-3`. This tolerance is intentionally
   loose because CoreML on Apple Silicon may use FP16 internally on the
   ANE/GPU and the INT8 quantization adds further drift.
3. **Cosine similarity between the two embeddings must be > 0.9999** as a
   sanity check on top of the L-infinity bound.

All 20 must pass. `compare-parity.py` enforces this and exits non-zero on any
failure.

## Prerequisites

- macOS 14+ (CoreML `mlprogram` + Apple Silicon recommended).
- Python 3.11 (managed via `asdf`). The conversion scripts pin against this.
- `swift --version` reporting Swift 6.0+ (Xcode 16 or the matching toolchain).
- A working internet connection on first run: `convert-model.py` downloads
  `sentence-transformers/all-MiniLM-L6-v2` from Hugging Face;
  `dump-python-reference.py` does the same if the model isn't already in
  `~/.recall/models/all-MiniLM-L6-v2/` from the existing Python recall install.
- ~700MB of free disk for the Python venv (torch alone is ~600MB CPU-only).

## Layout

```
.agents/spikes/2026-05-25-recall-spike/
├── README.md                    # this file
├── requirements.txt             # Python deps (torch, transformers, coremltools, ...)
├── setup.sh                     # creates .venv/ and installs requirements.txt
├── convert-model.py             # PyTorch -> CoreML mlprogram + INT8 quant
├── dump-python-reference.py     # tokens + embeddings from recall's exact path
├── reference-strings.txt        # 20 representative input strings
├── compare-parity.py            # gate: enforces ID identity + embedding tolerance
├── swift-harness/               # SwiftPM executable (tokenize + CoreML inference)
│   ├── Package.swift
│   └── Sources/SpikeHarness/main.swift
├── .gitignore
│
│ # Produced by running the spike (gitignored):
├── all-MiniLM-L6-v2-int8.mlpackage/   # output of convert-model.py
├── tokenizer.json                     # output of convert-model.py
├── tokenizer_config.json              # output of convert-model.py
├── python-reference.json              # output of dump-python-reference.py
└── swift-output.json                  # output of SpikeHarness
```

## Tokenizer folder note

`huggingface/swift-transformers` `AutoTokenizer.from(modelFolder:)` expects
`tokenizer.json` AND `tokenizer_config.json` in the same directory. The
conversion script writes both into the spike root so the Swift harness can
point at that root directly.

## Run order

From this directory (`.agents/spikes/2026-05-25-recall-spike/`):

```bash
# 1. One-time: create venv + install Python deps.
./setup.sh

# 2. Activate the venv for the Python steps.
source .venv/bin/activate

# 3. Convert MiniLM-L6-v2 from HF -> CoreML mlprogram with INT8 weights.
#    Outputs all-MiniLM-L6-v2-int8.mlpackage + tokenizer.json + tokenizer_config.json
#    in the spike directory. Asserts the mlpackage size lands between 15-60MB.
python convert-model.py

# 4. Dump the Python reference (token IDs + embeddings) for the 20 strings.
#    Uses HF tokenizers + onnxruntime to match recall/embedding.py byte-for-byte.
#    Writes python-reference.json.
python dump-python-reference.py

# 5. Build + run the Swift harness against the same 20 strings.
#    Writes swift-output.json.
cd swift-harness
swift build -c release
.build/release/SpikeHarness \
    ../all-MiniLM-L6-v2-int8.mlpackage \
    .. \
    ../reference-strings.txt \
    ../swift-output.json
cd ..

# 6. Gate: compare. Exits 0 on pass, 1 on any failure. Prints a per-string table.
python compare-parity.py
```

The Swift harness's second positional argument is the **folder** containing
`tokenizer.json` and `tokenizer_config.json` (here, the spike root), not the
tokenizer file itself. This matches the swift-transformers
`AutoTokenizer.from(modelFolder:)` API.

## Expected outcomes

- `convert-model.py` should run in ~30-90s on Apple Silicon. The resulting
  `.mlpackage` should weigh 15-60MB on disk (a hard floor/ceiling enforced by
  the script — outside that band, stop and reconsider quantization config).
- `dump-python-reference.py` should run in a few seconds; downloads
  `model.onnx` + `tokenizer.json` from HF if not already in
  `~/.recall/models/all-MiniLM-L6-v2/`.
- The Swift harness should run in a few seconds (first run includes CoreML
  model compilation; subsequent runs are cached).
- `compare-parity.py` should print a 20-row table where every row reports
  `tokens: ok`, `mask: ok`, `max_diff <= 1e-3`, `cos_sim >= 0.9999`, and
  exit 0.

## If parity fails

Stop. Document the failure mode (which string, which check, what the
mismatched values look like) in this README under a new "Findings" section,
then halt Phase 2 work and re-plan with Julian. Likely root causes:

- Tokenizer divergence (swift-transformers vs Python `tokenizers` library)
  on a specific Unicode edge case — surface in the failing string.
- Embedding drift large enough to fail 1e-3 — likely the INT8 quantization
  config is too aggressive, or CoreML is using a fundamentally different
  numeric path than the ONNX `CPUExecutionProvider`.
- The mean-pool / L2-normalize ordering differs between Python and Swift.

## Reproducibility

A future maintainer should be able to wipe the spike directory and reproduce
end-to-end in 30 minutes (most of it Python dep install).

Run order again, copy-paste friendly:

```bash
cd .agents/spikes/2026-05-25-recall-spike
./setup.sh
source .venv/bin/activate
python convert-model.py
python dump-python-reference.py
(cd swift-harness && swift build -c release && \
  .build/release/SpikeHarness \
    ../all-MiniLM-L6-v2-int8.mlpackage \
    .. \
    ../reference-strings.txt \
    ../swift-output.json)
python compare-parity.py
```
