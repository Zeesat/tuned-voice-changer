#!/usr/bin/env bash
# ==============================================================================
# healthcheck.sh — Comprehensive Voice Changer Runtime & Server Health Check
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
VC_HOST="${VC_HOST:-127.0.0.1}"
VC_PORT="${VC_PORT:-18888}"

FAILURES=0

check_pass() { printf "  \033[1;32m[PASS]\033[0m %s\n" "$*"; }
check_fail() { printf "  \033[1;31m[FAIL]\033[0m %s\n" "$*" >&2; FAILURES=$((FAILURES + 1)); }

printf "\033[1;34m=== Tuned Voice Changer Healthcheck (%s:%s) ===\033[0m\n" "${VC_HOST}" "${VC_PORT}"

# 1. CUDA & GPU availability
if [[ -x "${VC_ENV_DIR}/bin/python" ]]; then
    GPU_INFO="$("${VC_ENV_DIR}/bin/python" -c 'import torch; assert torch.cuda.is_available(); print(f"{torch.cuda.get_device_name(0)} (CUDA {torch.version.cuda})")' 2>/dev/null || true)"
    if [[ -n "${GPU_INFO}" ]]; then
        check_pass "CUDA & PyTorch GPU ready: ${GPU_INFO}"
    else
        check_fail "CUDA is not available in ${VC_ENV_DIR}"
    fi
else
    check_fail "Python virtualenv missing at ${VC_ENV_DIR}/bin/python"
fi

# 2. Persistent storage & model directory availability
SERVER_DIR="${COLAB_WORKSPACE_DIR}/server"
if [[ -L "${SERVER_DIR}/model_dir" ]] && [[ -d "${SERVER_DIR}/model_dir" ]] && [[ -d "${DRIVE_PERSIST_DIR}/models/pretrained" ]]; then
    SLOT0_PTH="$(find -L "${SERVER_DIR}/model_dir" -maxdepth 2 -name '*.pth' | head -n 1 || true)"
    check_pass "Persistent model storage linked (${SERVER_DIR}/model_dir -> $(readlink -f "${SERVER_DIR}/model_dir"), sample .pth: ${SLOT0_PTH:-none})"
else
    check_fail "Persistent model directory symlink missing or broken in ${SERVER_DIR}"
fi

# 3. Server process existence
SERVER_PID=""
if [[ -f "${VC_PID_FILE}" ]]; then
    SERVER_PID="$(cat "${VC_PID_FILE}" 2>/dev/null || true)"
fi
if [[ -z "${SERVER_PID}" ]] || ! kill -0 "${SERVER_PID}" 2>/dev/null; then
    SERVER_PID="$(pgrep -f "MMVCServerSIO.py" | head -n 1 || true)"
fi

if [[ -n "${SERVER_PID}" ]] && kill -0 "${SERVER_PID}" 2>/dev/null; then
    check_pass "Server process running (PID: ${SERVER_PID})"
else
    check_fail "Server process (MMVCServerSIO.py) is not running"
fi

# 4. Port binding check
if command -v ss >/dev/null 2>&1 && ss -tln | grep -q ":${VC_PORT} "; then
    check_pass "Port ${VC_PORT}/tcp is bound and listening"
elif command -v fuser >/dev/null 2>&1 && fuser "${VC_PORT}/tcp" >/dev/null 2>&1; then
    check_pass "Port ${VC_PORT}/tcp is bound and listening"
else
    check_fail "Port ${VC_PORT}/tcp is not listening"
fi

# 5. HTTP REST responsiveness (/api/hello and /info)
if curl -fsS --max-time 5 "http://127.0.0.1:${VC_PORT}/api/hello" >/dev/null 2>&1; then
    check_pass "HTTP REST /api/hello responded 200 OK"
else
    check_fail "HTTP REST /api/hello failed to respond"
fi

INFO_SUMMARY="$("${VC_ENV_DIR}/bin/python" - "${VC_PORT}" <<'PYEOF' 2>/dev/null || true
import json, sys, urllib.request
port = sys.argv[1]
with urllib.request.urlopen(f"http://127.0.0.1:{port}/info", timeout=5) as resp:
    data = json.loads(resp.read().decode("utf-8"))
slots = [s for s in data.get("modelSlots", []) if s.get("modelFile")]
slot0 = slots[0]["name"] + " (" + slots[0]["modelFile"] + ")" if slots else "no loaded slots"
print(f"status=OK, active_slots={len(slots)}, primary={slot0}")
PYEOF
)"
if [[ -n "${INFO_SUMMARY}" ]]; then
    check_pass "HTTP REST /info verified (${INFO_SUMMARY})"
else
    check_fail "HTTP REST /info did not return valid Voice Changer JSON state"
fi

# 6. Socket.IO transport endpoint check
SIO_RESP="$(curl -fsS --max-time 5 "http://127.0.0.1:${VC_PORT}/socket.io/?EIO=4&transport=polling" 2>/dev/null || true)"
if [[ "${SIO_RESP}" == *'"sid"'* ]]; then
    check_pass "Socket.IO EIO=4 polling handshake succeeded"
else
    check_fail "Socket.IO EIO=4 polling handshake failed"
fi

if [[ "${FAILURES}" -eq 0 ]]; then
    printf "\033[1;32m=== HEALTHCHECK PASSED (0 failures) ===\033[0m\n"
    exit 0
else
    printf "\033[1;31m=== HEALTHCHECK FAILED (%d failure(s)) ===\033[0m\n" "${FAILURES}" >&2
    exit 1
fi
