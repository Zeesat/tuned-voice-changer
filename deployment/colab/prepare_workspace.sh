#!/usr/bin/env bash
# ==============================================================================
# prepare_workspace.sh — Mount Validation, Persistent Storage Layout & Repo Sync
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/config.env" ]]; then
    # shellcheck disable=SC1091
    source "${SCRIPT_DIR}/config.env"
fi

REPOSITORY_URL="${REPOSITORY_URL:-https://github.com/Zeesat/tuned-voice-changer.git}"
REPOSITORY_REF="${REPOSITORY_REF:-master}"
COLAB_WORKSPACE_DIR="${COLAB_WORKSPACE_DIR:-/content/voice-changer}"
VC_ENV_DIR="${VC_ENV_DIR:-/content/vc_env}"
DRIVE_MOUNT_DIR="${DRIVE_MOUNT_DIR:-/content/drive/MyDrive}"
DRIVE_PERSIST_DIR="${DRIVE_PERSIST_DIR:-${DRIVE_MOUNT_DIR}/VoiceChanger}"

AUTO_PROVISION_SLOT0="${AUTO_PROVISION_SLOT0:-true}"
SLOT0_NAME="${SLOT0_NAME:-Vestia Zeta (RVC v2)}"
SLOT0_GDRIVE_ID="${SLOT0_GDRIVE_ID:-1JqrPD4d8lF2QdSH_S4Q-z8ySBlNn1EOP}"
SLOT0_BACKUP_URL="${SLOT0_BACKUP_URL:-https://huggingface.co/megaaziib/my-rvc-models-collection/resolve/main/zeta.zip}"
SLOT0_SAMPLING_RATE="${SLOT0_SAMPLING_RATE:-48000}"
SLOT0_EMB_CHANNELS="${SLOT0_EMB_CHANNELS:-768}"
SLOT0_EMB_OUTPUT_LAYER="${SLOT0_EMB_OUTPUT_LAYER:-12}"
SLOT0_F0="${SLOT0_F0:-true}"
SLOT0_EMBEDDER="${SLOT0_EMBEDDER:-hubert_base}"

log_info()  { printf "\033[1;34m[prepare_workspace][INFO]\033[0m  %s\n" "$*"; }
log_ok()    { printf "\033[1;32m[prepare_workspace][OK]\033[0m    %s\n" "$*"; }
log_warn()  { printf "\033[1;33m[prepare_workspace][WARN]\033[0m  %s\n" "$*"; }
log_error() { printf "\033[1;31m[prepare_workspace][ERROR]\033[0m %s\n" "$*" >&2; }

# 1. Prevent executing repository from Google Drive
if [[ "${COLAB_WORKSPACE_DIR}" == /content/drive* ]]; then
    log_error "COLAB_WORKSPACE_DIR (${COLAB_WORKSPACE_DIR}) must reside on local Colab SSD (/content), never on Google Drive."
    exit 1
fi

# 2. Verify Google Drive is mounted and writable
log_info "Checking Google Drive mount at ${DRIVE_MOUNT_DIR}..."
if [[ ! -d "${DRIVE_MOUNT_DIR}" ]]; then
    log_error "Google Drive is not mounted at ${DRIVE_MOUNT_DIR}. Mount Google Drive first (e.g., via 'colab drivemount' or notebook drive.mount)."
    exit 1
fi

# 3. Create structured persistent directories on Google Drive
log_info "Creating persistent directory structure under ${DRIVE_PERSIST_DIR}..."
mkdir -p \
    "${DRIVE_PERSIST_DIR}/models/pretrained" \
    "${DRIVE_PERSIST_DIR}/models/custom" \
    "${DRIVE_PERSIST_DIR}/checkpoints" \
    "${DRIVE_PERSIST_DIR}/indexes" \
    "${DRIVE_PERSIST_DIR}/configuration" \
    "${DRIVE_PERSIST_DIR}/backups"
log_ok "Persistent directories verified on Google Drive."

# 4. Migrate legacy Google Drive model folders if present and new structure is empty
for legacy_pretrain in "${DRIVE_MOUNT_DIR}/vc_models/pretrain" "${DRIVE_MOUNT_DIR}/voice-changer/server/pretrain"; do
    if [[ -d "${legacy_pretrain}" ]] && [[ -z "$(ls -A "${DRIVE_PERSIST_DIR}/models/pretrained" 2>/dev/null || true)" ]]; then
        log_info "Migrating existing pretrained weights from ${legacy_pretrain}..."
        cp -rn "${legacy_pretrain}/"* "${DRIVE_PERSIST_DIR}/models/pretrained/" 2>/dev/null || true
        log_ok "Pretrained weights migrated."
    fi
done

for legacy_custom in "${DRIVE_MOUNT_DIR}/vc_models/model_dir" "${DRIVE_MOUNT_DIR}/voice-changer/server/model_dir"; do
    if [[ -d "${legacy_custom}" ]] && [[ -z "$(ls -A "${DRIVE_PERSIST_DIR}/models/custom" 2>/dev/null || true)" ]]; then
        log_info "Migrating existing custom models from ${legacy_custom}..."
        cp -rn "${legacy_custom}/"* "${DRIVE_PERSIST_DIR}/models/custom/" 2>/dev/null || true
        log_ok "Custom models migrated."
    fi
done

# 5. Retrieve or update the customized Voice Changer repository on local SSD
GIT_ASKPASS_SCRIPT=""
cleanup_askpass() {
    if [[ -n "${GIT_ASKPASS_SCRIPT}" ]] && [[ -f "${GIT_ASKPASS_SCRIPT}" ]]; then
        rm -f "${GIT_ASKPASS_SCRIPT}"
    fi
}
trap cleanup_askpass EXIT

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    GIT_ASKPASS_SCRIPT="/tmp/vc_git_askpass_$$.sh"
    cat > "${GIT_ASKPASS_SCRIPT}" <<'ASKPASS_EOF'
#!/usr/bin/env bash
case "$1" in
    *Username*) echo "x-access-token" ;;
    *Password*) echo "${GITHUB_TOKEN}" ;;
esac
ASKPASS_EOF
    chmod 700 "${GIT_ASKPASS_SCRIPT}"
    export GIT_ASKPASS="${GIT_ASKPASS_SCRIPT}"
    export GIT_TERMINAL_PROMPT=0
fi

if [[ ! -d "${COLAB_WORKSPACE_DIR}/.git" ]]; then
    log_info "Cloning ${REPOSITORY_URL} (ref: ${REPOSITORY_REF}) into ${COLAB_WORKSPACE_DIR}..."
    rm -rf "${COLAB_WORKSPACE_DIR}"
    git clone "${REPOSITORY_URL}" "${COLAB_WORKSPACE_DIR}"
    git -C "${COLAB_WORKSPACE_DIR}" checkout "${REPOSITORY_REF}"
else
    log_info "Updating existing repository at ${COLAB_WORKSPACE_DIR} from ${REPOSITORY_URL} (ref: ${REPOSITORY_REF})..."
    git -C "${COLAB_WORKSPACE_DIR}" remote set-url origin "${REPOSITORY_URL}"
    git -C "${COLAB_WORKSPACE_DIR}" fetch --tags --prune origin
    if git -C "${COLAB_WORKSPACE_DIR}" show-ref --verify --quiet "refs/remotes/origin/${REPOSITORY_REF}"; then
        git -C "${COLAB_WORKSPACE_DIR}" checkout -B "${REPOSITORY_REF}" "origin/${REPOSITORY_REF}"
    else
        git -C "${COLAB_WORKSPACE_DIR}" checkout "${REPOSITORY_REF}"
    fi
fi
cleanup_askpass
unset GIT_ASKPASS GIT_TERMINAL_PROMPT

CURRENT_COMMIT="$(git -C "${COLAB_WORKSPACE_DIR}" rev-parse --short HEAD)"
log_ok "Repository ready at ${COLAB_WORKSPACE_DIR} (commit: ${CURRENT_COMMIT})."

# 6. Link persistent Google Drive storage into /content/voice-changer/server
SERVER_DIR="${COLAB_WORKSPACE_DIR}/server"
if [[ ! -d "${SERVER_DIR}" ]]; then
    log_error "Server directory not found at ${SERVER_DIR}"
    exit 1
fi

log_info "Configuring persistent symlinks in ${SERVER_DIR}..."
rm -rf "${SERVER_DIR}/pretrain" "${SERVER_DIR}/model_dir"
ln -sfn "${DRIVE_PERSIST_DIR}/models/pretrained" "${SERVER_DIR}/pretrain"
ln -sfn "${DRIVE_PERSIST_DIR}/models/custom" "${SERVER_DIR}/model_dir"

# Ensure persistent stored_setting.json exists and is linked
if [[ ! -f "${DRIVE_PERSIST_DIR}/configuration/stored_setting.json" ]]; then
    echo '{"modelSlotIndex": 0}' > "${DRIVE_PERSIST_DIR}/configuration/stored_setting.json"
fi
rm -f "${SERVER_DIR}/stored_setting.json"
ln -sfn "${DRIVE_PERSIST_DIR}/configuration/stored_setting.json" "${SERVER_DIR}/stored_setting.json"

# Keep ephemeral temporary & upload directories on fast local SSD
mkdir -p "${SERVER_DIR}/tmp_dir" "${SERVER_DIR}/upload_dir"
log_ok "Linked pretrain -> ${DRIVE_PERSIST_DIR}/models/pretrained"
log_ok "Linked model_dir -> ${DRIVE_PERSIST_DIR}/models/custom"
log_ok "Linked stored_setting.json -> ${DRIVE_PERSIST_DIR}/configuration/stored_setting.json"

# 7. Optionally provision Slot 0 custom model if missing
SLOT0_DIR="${DRIVE_PERSIST_DIR}/models/custom/0"
if [[ "${AUTO_PROVISION_SLOT0}" == "true" ]]; then
    mkdir -p "${SLOT0_DIR}"
    PTH_FILE="$(find "${SLOT0_DIR}" -maxdepth 1 -name '*.pth' | head -n 1 || true)"
    if [[ -z "${PTH_FILE}" ]]; then
        log_info "Slot 0 model not found in ${SLOT0_DIR}. Provisioning default Slot 0 model (${SLOT0_NAME})..."
        TMP_ZIP="/content/slot0_model.zip"
        rm -f "${TMP_ZIP}"
        DOWNLOAD_OK=0
        if [[ -x "${VC_ENV_DIR}/bin/gdown" ]] && [[ -n "${SLOT0_GDRIVE_ID}" ]]; then
            if "${VC_ENV_DIR}/bin/gdown" --fuzzy "${SLOT0_GDRIVE_ID}" -O "${TMP_ZIP}"; then
                DOWNLOAD_OK=1
            fi
        fi
        if [[ "${DOWNLOAD_OK}" -eq 0 ]] && [[ -n "${SLOT0_BACKUP_URL}" ]]; then
            log_warn "Falling back to backup model URL: ${SLOT0_BACKUP_URL}"
            curl -L --fail -o "${TMP_ZIP}" "${SLOT0_BACKUP_URL}" && DOWNLOAD_OK=1
        fi
        if [[ "${DOWNLOAD_OK}" -eq 1 ]] && [[ -f "${TMP_ZIP}" ]]; then
            TMP_EXTRACT="/content/slot0_extract"
            rm -rf "${TMP_EXTRACT}"
            mkdir -p "${TMP_EXTRACT}"
            unzip -q -o "${TMP_ZIP}" -d "${TMP_EXTRACT}"
            FOUND_PTH="$(find "${TMP_EXTRACT}" -name '*.pth' | head -n 1 || true)"
            FOUND_IDX="$(find "${TMP_EXTRACT}" -name '*.index' | head -n 1 || true)"
            if [[ -n "${FOUND_PTH}" ]]; then
                cp -f "${FOUND_PTH}" "${SLOT0_DIR}/"
                cp -f "${FOUND_PTH}" "${DRIVE_PERSIST_DIR}/checkpoints/" 2>/dev/null || true
            fi
            if [[ -n "${FOUND_IDX}" ]]; then
                cp -f "${FOUND_IDX}" "${SLOT0_DIR}/"
                cp -f "${FOUND_IDX}" "${DRIVE_PERSIST_DIR}/indexes/" 2>/dev/null || true
            fi
            rm -rf "${TMP_ZIP}" "${TMP_EXTRACT}"
        else
            log_warn "Could not download Slot 0 archive automatically. You can upload models via Web UI or Drive."
        fi
    fi

    # Generate params.json for Slot 0 if a .pth file exists and params.json is missing
    PTH_FILE="$(find "${SLOT0_DIR}" -maxdepth 1 -name '*.pth' -printf '%f\n' | head -n 1 || true)"
    IDX_FILE="$(find "${SLOT0_DIR}" -maxdepth 1 -name '*.index' -printf '%f\n' | head -n 1 || true)"
    if [[ -n "${PTH_FILE}" ]] && [[ ! -f "${SLOT0_DIR}/params.json" ]]; then
        log_info "Generating ${SLOT0_DIR}/params.json for ${PTH_FILE}..."
        cat > "${SLOT0_DIR}/params.json" <<EOF
{
    "slotIndex": 0,
    "voiceChangerType": "RVC",
    "name": "${SLOT0_NAME}",
    "description": "RVC v2 persisted on Google Drive",
    "credit": "",
    "termsOfUseUrl": "",
    "iconFile": "",
    "speakers": {
        "0": "target"
    },
    "modelFile": "${PTH_FILE}",
    "indexFile": "${IDX_FILE}",
    "defaultTune": 0,
    "defaultIndexRatio": 0,
    "defaultProtect": 0.5,
    "isONNX": false,
    "modelType": "pyTorchRVCv2",
    "samplingRate": ${SLOT0_SAMPLING_RATE},
    "f0": ${SLOT0_F0},
    "embChannels": ${SLOT0_EMB_CHANNELS},
    "embOutputLayer": ${SLOT0_EMB_OUTPUT_LAYER},
    "useFinalProj": false,
    "deprecated": false,
    "embedder": "${SLOT0_EMBEDDER}",
    "sampleId": ""
}
EOF
        log_ok "Slot 0 params.json generated."
    elif [[ -n "${PTH_FILE}" ]]; then
        if grep -q '"modelType": "pyTorchRVCv2"' "${SLOT0_DIR}/params.json" 2>/dev/null && grep -q '"embChannels": 256' "${SLOT0_DIR}/params.json" 2>/dev/null; then
            sed -i 's/"embChannels": 256/"embChannels": 768/' "${SLOT0_DIR}/params.json"
            log_info "Updated Slot 0 params.json embChannels to 768 for pyTorchRVCv2."
        fi
        log_ok "Slot 0 model verified: ${PTH_FILE} (index: ${IDX_FILE:-none})"
    fi
fi

log_ok "Workspace preparation complete."
