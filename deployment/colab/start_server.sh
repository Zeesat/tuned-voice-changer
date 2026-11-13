#!/usr/bin/env bash
# ==============================================================================
# start_server.sh — Validate Environment & Launch Voice Changer Server on Colab
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/config.env"
fi

COLAB_WORKSPACE_DIR="${COLAB_WORKSPACE_DIR:-/content/voice-changer}"
VC_ENV_DIR="${VC_ENV_DIR:-/content/vc_env}"
DRIVE_PERSIST_DIR="${DRIVE_PERSIST_DIR:-/content/drive/MyDrive/VoiceChanger}"
VC_PID_FILE="${VC_PID_FILE:-/content/vc_server.pid}"
VC_LOG_FILE="${VC_LOG_FILE:-/content/vc_server.log}"

VC_HOST="${VC_HOST:-127.0.0.1}"
VC_PORT="${VC_PORT:-18888}"
VC_HTTPS="${VC_HTTPS:-False}"
VC_LOG_LEVEL="${VC_LOG_LEVEL:-error}"
VC_SAMPLE_MODE="${VC_SAMPLE_MODE:-}"
VC_CONTENT_VEC_ONNX_ON="${VC_CONTENT_VEC_ONNX_ON:-True}"

MODE="daemon"
if [[ "${1:-}" == "--foreground" ]]; then
    MODE="foreground"
elif [[ "${1:-}" == "--daemon" ]]; then
    MODE="daemon"
fi

log_info()  { printf "\033[1;34m[start_server][INFO]\033[0m  %s\n" "$*"; }
log_ok()    { printf "\033[1;32m[start_server][OK]\033[0m    %s\n" "$*"; }
log_warn()  { printf "\033[1;33m[start_server][WARN]\033[0m  %s\n" "$*"; }
log_error() { printf "\033[1;31m[start_server][ERROR]\033[0m %s\n" "$*" >&2; }

SERVER_DIR="${COLAB_WORKSPACE_DIR}/server"
PY_BIN="${VC_ENV_DIR}/bin/python"

# 1. Pre-flight validations
if [[ ! -x "${PY_BIN}" ]]; then
    log_error "Python environment not found at ${PY_BIN}. Run setup_runtime.sh first."
    exit 1
fi

if [[ ! -f "${SERVER_DIR}/MMVCServerSIO.py" ]]; then
    log_error "MMVCServerSIO.py not found in ${SERVER_DIR}. Run prepare_workspace.sh first."
    exit 1
fi

if [[ ! -e "${SERVER_DIR}/model_dir" ]] || [[ ! -e "${SERVER_DIR}/pretrain" ]]; then
    log_error "Persistent model_dir/pretrain links missing in ${SERVER_DIR}. Run prepare_workspace.sh first."
    exit 1
fi

# 2. Check if already running
if [[ -f "${VC_PID_FILE}" ]]; then
    EXISTING_PID="$(cat "${VC_PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${EXISTING_PID}" ]] && kill -0 "${EXISTING_PID}" 2>/dev/null; then
        log_ok "Voice Changer server is already running (PID: ${EXISTING_PID}, Port: ${VC_PORT})."
        exit 0
    fi
    rm -f "${VC_PID_FILE}"
fi

# Ensure port is free before starting
if command -v fuser >/dev/null 2>&1 && fuser "${VC_PORT}/tcp" >/dev/null 2>&1; then
    log_warn "Port ${VC_PORT}/tcp is currently occupied. Stopping stale process on port ${VC_PORT}..."
    "${SCRIPT_DIR}/stop_server.sh" || true
fi

# 3. Prepare directories, CUDA library paths & arguments
mkdir -p "${SERVER_DIR}/tmp_dir" "${SERVER_DIR}/upload_dir"
cd "${SERVER_DIR}"

NVIDIA_LIB_PATHS="$("${PY_BIN}" - <<'PYEOF' 2>/dev/null || true
import glob, os, site
paths = []
for sp in site.getsitepackages():
    paths.extend(glob.glob(os.path.join(sp, "nvidia", "*", "lib")))
print(":".join(paths))
PYEOF
)"
if [[ -n "${NVIDIA_LIB_PATHS}" ]]; then
    export LD_LIBRARY_PATH="${NVIDIA_LIB_PATHS}:${LD_LIBRARY_PATH:-}"
fi

SERVER_ARGS=(
    "MMVCServerSIO.py"
    "-p" "${VC_PORT}"
    "--host" "${VC_HOST}"
    "--https" "${VC_HTTPS}"
    "--logLevel" "${VC_LOG_LEVEL}"
    "--reload" "False"
    "--content_vec_500" "pretrain/checkpoint_best_legacy_500.pt"
    "--content_vec_500_onnx" "pretrain/content_vec_500.onnx"
    "--content_vec_500_onnx_on" "${VC_CONTENT_VEC_ONNX_ON}"
    "--hubert_base" "pretrain/hubert_base.pt"
    "--hubert_base_jp" "pretrain/rinna_hubert_base_jp.pt"
    "--hubert_soft" "pretrain/hubert/hubert-soft-0d54a1f4.pt"
    "--nsf_hifigan" "pretrain/nsf_hifigan/model"
    "--crepe_onnx_full" "pretrain/crepe_onnx_full.onnx"
    "--crepe_onnx_tiny" "pretrain/crepe_onnx_tiny.onnx"
    "--rmvpe" "pretrain/rmvpe.pt"
    "--rmvpe_onnx" "pretrain/rmvpe.onnx"
    "--model_dir" "model_dir"
    "--sample_mode" "${VC_SAMPLE_MODE}"
)

if [[ "${MODE}" == "foreground" ]]; then
    log_info "Starting Voice Changer server in foreground on ${VC_HOST}:${VC_PORT}..."
    exec "${PY_BIN}" -u "${SERVER_ARGS[@]}"
fi

# 4. Daemon launch with PID and log management
log_info "Starting Voice Changer server in background on ${VC_HOST}:${VC_PORT}..."
: > "${VC_LOG_FILE}"
nohup "${PY_BIN}" -u "${SERVER_ARGS[@]}" >> "${VC_LOG_FILE}" 2>&1 &
SERVER_PID=$!
echo "${SERVER_PID}" > "${VC_PID_FILE}"
log_info "Launched MMVCServerSIO.py (PID: ${SERVER_PID}). Waiting for HTTP & Socket.IO readiness..."

# 5. Poll until server responds on /api/hello (up to 180s to allow initial pretrain downloads)
MAX_WAIT=180
ELAPSED=0
while [[ ${ELAPSED} -lt ${MAX_WAIT} ]]; do
    if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
        log_error "Server process (PID: ${SERVER_PID}) exited prematurely. Last 40 lines of ${VC_LOG_FILE}:"
        tail -n 40 "${VC_LOG_FILE}" >&2 || true
        rm -f "${VC_PID_FILE}"
        exit 1
    fi

    if curl -fsS --max-time 2 "http://127.0.0.1:${VC_PORT}/api/hello" >/dev/null 2>&1; then
        log_ok "Server is listening and responsive on http://${VC_HOST}:${VC_PORT} (PID: ${SERVER_PID}, Startup: ${ELAPSED}s)."
        if [[ -d "${DRIVE_PERSIST_DIR}/backups" ]]; then
            cp -f "${VC_LOG_FILE}" "${DRIVE_PERSIST_DIR}/backups/vc_server_latest.log" 2>/dev/null || true
        fi
        exit 0
    fi

    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

log_error "Timed out after ${MAX_WAIT}s waiting for server on port ${VC_PORT}. Last 40 lines of ${VC_LOG_FILE}:"
tail -n 40 "${VC_LOG_FILE}" >&2 || true
exit 1
