#!/usr/bin/env bash
# ==============================================================================
# stop_server.sh — Gracefully Stop Voice Changer Server & Clean Temporary State
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/config.env"
fi

COLAB_WORKSPACE_DIR="${COLAB_WORKSPACE_DIR:-/content/voice-changer}"
VC_PID_FILE="${VC_PID_FILE:-/content/vc_server.pid}"
VC_PORT="${VC_PORT:-18888}"

log_info()  { printf "\033[1;34m[stop_server][INFO]\033[0m  %s\n" "$*"; }
log_ok()    { printf "\033[1;32m[stop_server][OK]\033[0m    %s\n" "$*"; }
log_warn()  { printf "\033[1;33m[stop_server][WARN]\033[0m  %s\n" "$*"; }

STOPPED_ANY=0

# 1. Stop via tracked PID file if present
if [[ -f "${VC_PID_FILE}" ]]; then
    TARGET_PID="$(cat "${VC_PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${TARGET_PID}" ]] && kill -0 "${TARGET_PID}" 2>/dev/null; then
        log_info "Sending SIGTERM to Voice Changer PID ${TARGET_PID}..."
        kill -TERM "${TARGET_PID}" 2>/dev/null || true
        for _ in {1..15}; do
            if ! kill -0 "${TARGET_PID}" 2>/dev/null; then
                break
            fi
            sleep 1
        done
        if kill -0 "${TARGET_PID}" 2>/dev/null; then
            log_warn "PID ${TARGET_PID} did not exit after 15s; sending SIGKILL..."
            kill -KILL "${TARGET_PID}" 2>/dev/null || true
        fi
        STOPPED_ANY=1
    fi
    rm -f "${VC_PID_FILE}"
fi

# 2. Check for any remaining MMVCServerSIO.py processes or processes bound to VC_PORT
PIDS_BY_NAME="$(pgrep -f "MMVCServerSIO.py" 2>/dev/null || true)"
if [[ -n "${PIDS_BY_NAME}" ]]; then
    log_info "Stopping remaining MMVCServerSIO.py processes (${PIDS_BY_NAME//$'\n'/ })..."
    for pid in ${PIDS_BY_NAME}; do
        kill -TERM "${pid}" 2>/dev/null || true
    done
    sleep 2
    for pid in ${PIDS_BY_NAME}; do
        if kill -0 "${pid}" 2>/dev/null; then
            kill -KILL "${pid}" 2>/dev/null || true
        fi
    done
    STOPPED_ANY=1
fi

if command -v fuser >/dev/null 2>&1 && fuser "${VC_PORT}/tcp" >/dev/null 2>&1; then
    log_warn "Cleaning up residual listener on port ${VC_PORT}/tcp..."
    fuser -k -TERM "${VC_PORT}/tcp" >/dev/null 2>&1 || true
    sleep 1
    if fuser "${VC_PORT}/tcp" >/dev/null 2>&1; then
        fuser -k -KILL "${VC_PORT}/tcp" >/dev/null 2>&1 || true
    fi
    STOPPED_ANY=1
fi

# 3. Clean ephemeral upload/tmp directories on local SSD
if [[ -d "${COLAB_WORKSPACE_DIR}/server/tmp_dir" ]]; then
    rm -rf "${COLAB_WORKSPACE_DIR}/server/tmp_dir/"* 2>/dev/null || true
fi
if [[ -d "${COLAB_WORKSPACE_DIR}/server/upload_dir" ]]; then
    rm -rf "${COLAB_WORKSPACE_DIR}/server/upload_dir/"* 2>/dev/null || true
fi

if [[ "${STOPPED_ANY}" -eq 1 ]]; then
    log_ok "Voice Changer server stopped cleanly and port ${VC_PORT} released."
else
    log_ok "Voice Changer server was not running (port ${VC_PORT} is free)."
fi
