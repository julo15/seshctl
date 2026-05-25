#!/usr/bin/env bash
# Create a local .venv/ for the parity spike and install requirements.txt.
# Idempotent: safe to re-run; a pre-existing venv is reused.
#
# After this finishes, follow the README's "Run order" section starting with
# `source .venv/bin/activate && python convert-model.py`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

VENV_DIR=".venv"
REQ_FILE="requirements.txt"

if [ ! -d "$VENV_DIR" ]; then
    echo ">> Creating Python venv at $SCRIPT_DIR/$VENV_DIR"
    python3 -m venv "$VENV_DIR"
else
    echo ">> Reusing existing venv at $SCRIPT_DIR/$VENV_DIR"
fi

# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"

echo ">> Upgrading pip"
python -m pip install --upgrade pip >/dev/null

echo ">> Installing $REQ_FILE (this is ~700MB; torch wheel dominates)"
python -m pip install -r "$REQ_FILE"

echo ""
echo "Setup complete."
echo ""
echo "Next step:"
echo "  source $SCRIPT_DIR/$VENV_DIR/bin/activate"
echo "  python convert-model.py"
echo ""
echo "Then follow README.md's Run order section."
