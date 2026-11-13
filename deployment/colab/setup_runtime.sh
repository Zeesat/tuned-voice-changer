#!/usr/bin/env bash
# ==============================================================================
# setup_runtime.sh — Idempotent Colab GPU Runtime & Python 3.10 Environment Setup
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/config.env"
fi

COLAB_WORKSPACE_DIR="${COLAB_WORKSPACE_DIR:-/content/voice-changer}"
VC_ENV_DIR="${VC_ENV_DIR:-/content/vc_env}"
REQ_FILE="${REQ_FILE:-${SCRIPT_DIR}/requirements-colab.txt}"

log_info()  { printf "\033[1;34m[setup_runtime][INFO]\033[0m  %s\n" "$*"; }
log_ok()    { printf "\033[1;32m[setup_runtime][OK]\033[0m    %s\n" "$*"; }
log_warn()  { printf "\033[1;33m[setup_runtime][WARN]\033[0m  %s\n" "$*"; }
log_error() { printf "\033[1;31m[setup_runtime][ERROR]\033[0m %s\n" "$*" >&2; }

# 1. Verify we are not placing the virtualenv on Google Drive
if [[ "${VC_ENV_DIR}" == /content/drive* ]]; then
    log_error "VC_ENV_DIR (${VC_ENV_DIR}) must not be located on Google Drive FUSE storage."
    exit 1
fi

# 2. Check GPU availability via nvidia-smi
log_info "Checking NVIDIA GPU hardware availability..."
if command -v nvidia-smi >/dev/null 2>&1; then
    GPU_SUMMARY="$(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader | head -n 1)"
    log_ok "Detected GPU: ${GPU_SUMMARY}"
else
    log_error "nvidia-smi not found. Ensure the Google Colab runtime is provisioned with a GPU accelerator (T4/L4/A100)."
    exit 1
fi

# 3. Install required system packages idempotently
log_info "Ensuring required system packages (libportaudio2, libsndfile1, ffmpeg, psmisc, curl, unzip)..."
MISSING_PKGS=()
for pkg in libportaudio2 libsndfile1 ffmpeg psmisc curl unzip git; do
    if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
        MISSING_PKGS+=("${pkg}")
    fi
done

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    log_info "Installing missing apt packages: ${MISSING_PKGS[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq "${MISSING_PKGS[@]}"
    log_ok "System packages installed."
else
    log_ok "All required system packages are already installed."
fi

# 4. Ensure uv package manager is available
export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
if ! command -v uv >/dev/null 2>&1; then
    log_info "Installing uv package manager..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
fi
log_ok "uv version: $(uv --version)"

# 5. Fast-path check: if VC_ENV_DIR already exists and passes verification, skip reinstall
verify_environment() {
    local py_bin="${VC_ENV_DIR}/bin/python"
    if [[ ! -x "${py_bin}" ]]; then
        return 1
    fi
    local nv_libs
    nv_libs="$("${py_bin}" -c 'import glob, os, site; print(":".join(p for sp in site.getsitepackages() for p in glob.glob(os.path.join(sp, "nvidia", "*", "lib"))))' 2>/dev/null || true)"
    LD_LIBRARY_PATH="${nv_libs}:${LD_LIBRARY_PATH:-}" "${py_bin}" - <<'PYEOF'
import sys
assert sys.version_info[:2] == (3, 10), f"Expected Python 3.10, got {sys.version}"
import numpy as np
assert int(np.__version__.split(".")[0]) < 2, f"Expected numpy<2, got {np.__version__}"
import torch
import torchaudio
assert torch.cuda.is_available(), "torch.cuda.is_available() is False"
import onnxruntime as ort
assert ort.__version__.startswith("1.19."), f"Expected onnxruntime-gpu 1.19.x (CUDA 12), got {ort.__version__}"
import fairseq
import faiss
import pyworld
import uvicorn
import fastapi
import socketio
print(
    f"Verified: Python={sys.version.split()[0]} | "
    f"Torch={torch.__version__} (CUDA={torch.version.cuda}, Device={torch.cuda.get_device_name(0)}) | "
    f"ORT={ort.__version__} (Providers={ort.get_available_providers()}) | "
    f"NumPy={np.__version__} | Fairseq={fairseq.__version__}"
)
PYEOF
}

if [[ "${FORCE_REINSTALL:-0}" != "1" ]] && verify_environment 2>/dev/null; then
    log_ok "Existing Python 3.10 environment at ${VC_ENV_DIR} passed full compatibility verification."
    exit 0
fi

# 6. Provision dedicated Python 3.10 virtual environment
log_info "Provisioning Python 3.10 virtual environment at ${VC_ENV_DIR}..."
uv venv "${VC_ENV_DIR}" --python 3.10 --seed --clear

PY_BIN="${VC_ENV_DIR}/bin/python"

# 7. Stage 1 build prerequisites + PyTorch cu121 (required before fairseq and pyworld C/Cython extensions)
log_info "Installing Stage 1 build prerequisites and PyTorch 2.4.1+cu121..."
uv pip install --python "${PY_BIN}" \
    --extra-index-url https://download.pytorch.org/whl/cu121 \
    --index-strategy unsafe-best-match \
    "pip<24.1" \
    "setuptools<70.0.0" \
    "wheel" \
    "cython<3.0.0" \
    "numpy==1.26.4" \
    "torch==2.4.1+cu121" \
    "torchaudio==2.4.1+cu121"

# 8. Stage 2 native extensions requiring --no-build-isolation
# NOTE: PyPI sdist fairseq-0.12.2.tar.gz omits fairseq/clib/libbase/balanced_assignment.cpp
# from MANIFEST.in. Setting READTHEDOCS=1 causes setup.py to skip unused C++ extensions (libbase)
# while preserving full fairseq.checkpoint_utils needed by RVC / HuBERT.
log_info "Installing pyworld==0.3.4 and fairseq==0.12.2 with --no-build-isolation..."
READTHEDOCS=1 uv pip install --python "${PY_BIN}" --no-build-isolation \
    "setuptools<70.0.0" \
    "numpy==1.26.4" \
    "pyworld==0.3.4" \
    "fairseq==0.12.2"

# 9. Stage 3 full pinned dependency matrix
if [[ ! -f "${REQ_FILE}" ]]; then
    log_error "Requirements file not found at ${REQ_FILE}"
    exit 1
fi
log_info "Installing pinned dependency matrix from ${REQ_FILE}..."
READTHEDOCS=1 uv pip install --python "${PY_BIN}" --no-build-isolation --index-strategy unsafe-best-match -r "${REQ_FILE}"

# 10. Final verification
log_info "Running post-installation verification check..."
if verify_environment; then
    log_ok "Runtime setup completed and verified successfully."
else
    log_error "Runtime verification failed after dependency installation."
    exit 1
fi
