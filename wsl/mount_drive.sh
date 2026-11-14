#!/usr/bin/env bash
# ==============================================================================
# mount_drive.sh — Provision/Reuse Colab Session & Mount Google Drive in WSL
# ==============================================================================
# Usage:
#   ./mount_drive.sh            # Uses T4 GPU by default (testing)
#   ./mount_drive.sh A100       # Uses A100 GPU (production)
#   ./mount_drive.sh T4 <id>    # Uses/creates a specific session ID
# ==============================================================================
set -euo pipefail

GPU_TYPE="${1:-T4}"
SESSION_ID="${2:-}"
COLAB_BIN="${HOME}/.local/bin/colab"

if [[ ! -x "${COLAB_BIN}" ]]; then
    echo "[ERROR] google-colab-cli not found at ${COLAB_BIN}" >&2
    exit 1
fi

get_active_session() {
    "${COLAB_BIN}" sessions 2>/dev/null | grep -F " | Hardware: " | sed -n 's/^\[\([^]?]*\)\] .*/\1/p' | head -n 1 || true
}

# 1. Detect existing active session if SESSION_ID not provided
if [[ -z "${SESSION_ID}" ]]; then
    SESSION_ID="$(get_active_session)"
fi

# 2. Provision a new GPU session if none is active
if [[ -z "${SESSION_ID}" ]]; then
    SESSION_ID="vc"
    echo "[1/3] No active Colab session found. Creating a new ${GPU_TYPE} GPU session ('${SESSION_ID}')..."
    "${COLAB_BIN}" new -s "${SESSION_ID}" --gpu "${GPU_TYPE}"
else
    echo "[1/3] Reusing active Colab session '${SESSION_ID}'..."
fi

echo "[2/3] Mounting Google Drive (/content/drive) on session '${SESSION_ID}'..."
echo "      (If an OAuth URL is printed, open it in your browser, approve access, and press Enter here.)"
"${COLAB_BIN}" drivemount -s "${SESSION_ID}" /content/drive

echo "[3/3] Verifying /content/drive/MyDrive on session '${SESSION_ID}'..."
"${COLAB_BIN}" ls -s "${SESSION_ID}" /content/drive/MyDrive

echo ""
echo "[OK] Google Drive is mounted on session '${SESSION_ID}'."
echo "     To stop this session when finished: colab stop -s ${SESSION_ID}"
