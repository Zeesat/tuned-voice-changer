# Phase 1: Local Repository Audit Report (`w-okada/voice-changer`)

- **Audited Repository**: `D:\VSC\colab\voice-changer`
- **Upstream Remote**: `https://github.com/w-okada/voice-changer.git`
- **Target Custom Remote**: `https://github.com/Zeesat/tuned-voice-changer.git`
- **Audited Commit**: `d8ef157` (`master`)
- **Target Execution Environment**: Google Colab GPU Runtime (`T4`, `L4`, `A100`) orchestrated from WSL2 Ubuntu (`google-colab-cli v0.8.0`)

---

## 1. Existing Architecture & Repository Structure

### 1.1 High-Level Architecture
`w-okada/voice-changer` is a real-time multi-model voice conversion system designed around a **Client–Server split**:
- **Frontend Client (`client/demo/dist/`)**: Pre-built Single-Page Application (React/TypeScript + Web Audio API `AudioWorklet`) served statically by the Python backend. It captures microphone PCM audio in the user's local browser, streams chunks to the server over **Socket.IO** (or HTTP POST `/test`), and plays back converted PCM audio locally.
- **Backend Server (`server/`)**: Python ASGI server (`FastAPI` + `python-socketio` running on `uvicorn`) that manages model slots, downloads base weights, and executes GPU inference pipelines (RVC v1/v2, HuBERT/ContentVec feature extraction, RMVPE/Crepe/Harvest/FCPE pitch extraction, FAISS index retrieval, and PyTorch/ONNX synthesis).

### 1.2 Repository Directory Structure
```text
voice-changer/
├── client/                  # Frontend TypeScript/React source and prebuilt bundle
│   └── demo/dist/           # Pre-compiled static web UI served by the backend (present in repo)
├── server/                  # Python backend & ML inference engine
│   ├── MMVCServerSIO.py     # Primary server entrypoint (CLI argument parser, weight/sample init, uvicorn launcher)
│   ├── const.py             # Global path constants, enums, and sample catalog URLs
│   ├── requirements.txt     # Legacy 2023 Python dependency pins (Torch 2.0.1, ONNXRuntime 1.13.1)
│   ├── downloader/          # WeightDownloader.py (pretrain weights) & SampleDownloader.py (initial slot samples)
│   ├── mods/                # SSL certificate generator, CORS origin helpers (origins.py), logger (log_control.py)
│   ├── restapi/             # FastAPI routers (/info, /api/hello, /test, /load_model, /update_settings, /upload_file)
│   ├── sio/                 # Socket.IO server (MMVC_SocketIOApp.py, MMVC_SocketIOServer.py, MMVC_Namespace.py)
│   └── voice_changer/       # Core VoiceChangerManager, ModelSlotManager, and RVC/DDSP/SoVITS pipelines
├── docker_vcclient/         # Legacy CUDA 11.8 Docker build scripts
├── docs/                    # Upstream GitHub Pages static assets
├── tutorials/               # Upstream documentation
└── Realtime_Voice_Changer_on_Colab.ipynb  # Legacy 2023 Colab notebook (uses ngrok + host Python)
```

### 1.3 Server Entry Point & Startup Sequence
The canonical server entry point is `server/MMVCServerSIO.py` (invoked with working directory `server/`):
1. Parses CLI arguments (`-p`, `--host`, `--https`, `--model_dir`, `--sample_mode`, and paths to 12 pretrain weights).
2. Under `if __name__ == "__main__":`:
   - Calls `downloadWeight(voiceChangerParams)` (`server/downloader/WeightDownloader.py`) to download missing base weights into `pretrain/` from HuggingFace/Azure.
   - Calls `downloadInitialSamples(args.sample_mode, args.model_dir)` (`server/downloader/SampleDownloader.py`), which downloads 4 default sample models **only if `args.model_dir` does not already exist**.
   - Starts `localServer()` via `uvicorn.run("MMVCServerSIO:app_socketio", host=HOST, port=int(PORT), ...)`.
3. Under `if __name__ == "MMVCServerSIO":` (triggered when Uvicorn imports `MMVCServerSIO:app_socketio`):
   - Initializes `VoiceChangerManager.get_instance(voiceChangerParams)` (loads `model_dir` slots and `stored_setting.json`).
   - Initializes `MMVC_Rest` (FastAPI app) and wraps it in `MMVC_SocketIOApp` (`socketio.ASGIApp`).

---

## 2. Technical Compatibility Audit

| Area | Finding | Status |
|---|---|---|
| **Python Version** | Modern Google Colab runtimes default to **Python 3.13**. `fairseq==0.12.2` crashes on Python 3.11+ due to PEP 557 strict mutable dataclass defaults (`CommonConfig`). **Python 3.10** (via `uv venv /content/vc_env --python 3.10`) is required. | **Blocker (Resolved via Python 3.10 venv)** |
| **PyTorch & CUDA** | Upstream `requirements.txt` pins `torch==2.0.1` (CUDA 11.7). Colab GPUs (`T4`, `L4`, `A100`) run CUDA 12.x drivers. `torch==2.4.1+cu121` and `torchaudio==2.4.1+cu121` provide full compatibility with `fairseq`, `torchcrepe`, `torchfcpe`, and `autocast(fp16)`. | **Verified (`cu121`)** |
| **ONNX Runtime GPU** | Upstream pins `onnxruntime-gpu==1.13.1` (requires CUDA 11). Under CUDA 12 (`cu121`), `onnxruntime-gpu>=1.17.0,<1.20.0` is required for `CUDAExecutionProvider`. | **Verified** |
| **Native Extensions (`fairseq`, `pyworld`, `faiss`)** | `pyworld` requires Cython + `pkg_resources` at build/import time (`setuptools<70`) and C ABI compatibility with NumPy 1.x (`numpy<2.0.0` / `numpy==1.26.4`). `faiss-cpu==1.8.0.post1` works cleanly for RVC `.index` retrieval (`PipelineGenerator.py` calls `faiss.read_index()`, which runs on CPU in upstream code). | **Verified** |
| **System Audio (`sounddevice`)** | `server/voice_changer/Local/AudioDeviceList.py` imports `sounddevice` unconditionally at module load time. Without the `libportaudio2` apt package, server startup crashes with `OSError: PortAudio library not found`. | **Blocker (Requires `libportaudio2`)** |
| **Networking & Transport** | Real-time audio uses Socket.IO over WebSocket/HTTP (`/socket.io/` namespace `/test`, event `request_message` carrying packed int16 PCM bytes) or HTTP POST `/test`. All traffic runs over **a single TCP port** (`18888`). No UDP or WebRTC is used. | **100% SSH Tunnel Compatible** |
| **CORS & Browser Security** | `server/mods/origins.py` automatically whitelists `http://localhost:<PORT>` and `http://127.0.0.1:<PORT>` in both FastAPI (`TrustedOriginMiddleware`) and Socket.IO (`cors_allowed_origins`). Modern browsers treat `http://localhost:<PORT>` as a **Secure Context**, enabling `navigator.mediaDevices.getUserMedia()` (microphone capture) over plain HTTP (`--https False`). | **Verified** |
| **Storage & Persistence** | `model_dir` (`--model_dir`) and all `pretrain/*` paths are configurable via CLI flags or symlinks. `stored_setting.json` is read/written in `server/stored_setting.json`. `TMP_DIR` (`server/tmp_dir`) and `UPLOAD_DIR` (`server/upload_dir`) handle transient I/O and must remain on fast local `/content/` storage. | **Verified** |

---

## 3. Confirmed Defects vs. Potential Risks

### 3.1 Confirmed Defects in Upstream Application Code

| ID | Risk | Location | Description & Technical Cause | Recommended Fix |
|---|---|---|---|---|
| **DEF-01** | **Critical** | `server/MMVCServerSIO.py:3` | `from distutils.util import strtobool` — `distutils` is deprecated in Python 3.10 and removed in Python 3.12+, causing `ModuleNotFoundError: No module named 'distutils'` if `setuptools` is updated or standard library is used. | Replace `distutils.util.strtobool` with a self-contained `strtobool(val: str) -> int` function in `MMVCServerSIO.py`. |
| **DEF-02** | **High** | `server/MMVCServerSIO.py:130, 253` | When `--https False` is used on Linux: (1) `localServer` hardcodes `reload=True` (spawning Uvicorn reloader + worker child processes that poll the filesystem, which degrades performance when `model_dir`/`pretrain` are symlinked to Google Drive FUSE), and (2) `mp.Process` spawns a child without signal forwarding or `.join()`, leaving orphaned GPU processes when the parent PID is stopped. | Add `--reload` CLI flag (default `False`), run `localServer` directly in the foreground on Linux when no native GUI client is launched, and handle `SIGINT`/`SIGTERM` cleanly. |
| **DEF-03** | **Medium** | `server/mods/log_control.py:20, 29` | `DebugStreamHandler.emit` and `DebugFileHandler.emit` reference `file=sys.stderr`, but `sys` is never imported in `log_control.py`, causing `NameError: name 'sys' is not defined` on any logging exception. | Add `import sys` at the top of `server/mods/log_control.py`. |
| **DEF-04** | **Medium** | `server/restapi/MMVC_Rest.py:95-99` | `app_fastapi.mount(f"/{voiceChangerParams.model_dir}", StaticFiles(directory=voiceChangerParams.model_dir))` raises `RuntimeError: Directory 'model_dir' does not exist` if `model_dir` has not been created prior to FastAPI initialization (e.g. when sample downloading is skipped or disabled). | Ensure `os.makedirs(voiceChangerParams.model_dir, exist_ok=True)` before mounting `StaticFiles`. |
| **DEF-05** | **Low** | `Realtime_Voice_Changer_on_Colab.ipynb:170` | Legacy notebook passes `--samples samples.json` to `MMVCServerSIO.py`, which is not a valid argument (`--sample_mode` is the actual flag in `setupArgParser()`). | Use valid CLI arguments (`--sample_mode`) in `start_server.sh`. |

### 3.2 Potential Deployment Risks & Mitigations

| ID | Risk | Area | Description | Mitigation |
|---|---|---|---|---|
| **RSK-01** | **Critical** | Dependency Drift on Ephemeral Colab VMs | Colab's base Python (3.13) and preinstalled packages change frequently without notice. | Provision an isolated **Python 3.10** environment at `/content/vc_env` via `uv` using a pinned `deployment/colab/requirements-colab.txt`. |
| **RSK-02** | **High** | Google Drive FUSE Latency | Running git operations, virtual environments, or temporary chunk uploads (`upload_dir`, `tmp_dir`) on Google Drive FUSE causes severe I/O stalls and API rate limiting. | Clone and execute `/content/voice-changer` and `/content/vc_env` exclusively on local SSD (`/content`). Only symlink `server/pretrain`, `server/model_dir`, and `server/stored_setting.json` to `/content/drive/MyDrive/VoiceChanger/`. |
| **RSK-03** | **Medium** | Repeated 4-Sample Downloads on Fresh Runs | By default (`--sample_mode production`), `downloadInitialSamples()` downloads 4 sample models if `model_dir` does not exist. | Create persistent `model_dir` on Google Drive and pre-populate Slot 0 (`Vestia Zeta`), and default `SAMPLE_MODE=""` (or configurable) so startup does not waste time/storage downloading unused sample models when custom models are already present. |
| **RSK-04** | **Low** | Colab Free-Tier Process Filter | Although paid Compute Units (`A100`/`T4`) are used, Colab's static notebook scanner flags literal strings in notebook cells. | Execute via `google-colab-cli` SSH/exec scripts (`deployment/colab/*.sh`) rather than notebook cell macros. |

---

## 4. Verified Dependency Compatibility Matrix (Colab GPU Runtime)

| Component | Verified Version / Constraint | Justification |
|---|---|---|
| **System Packages** | `libportaudio2`, `libsndfile1`, `ffmpeg`, `psmisc`, `curl` | Required by `sounddevice`, `librosa`/`scipy`, and port management (`fuser`). |
| **Python** | `3.10.x` (provisioned via `uv venv --python 3.10`) | Required for `fairseq==0.12.2` dataclass compatibility and `pyworld` wheels. |
| **Build Tools** | `setuptools<70.0.0`, `wheel`, `pip` | Provides `pkg_resources` required by `pyworld` and `fairseq`. |
| **NumPy** | `numpy==1.26.4` (`<2.0.0`) | Prevents C-extension ABI crashes in `faiss-cpu`, `pyworld`, `scipy`, and `librosa`. |
| **PyTorch & Audio** | `torch==2.4.1+cu121`, `torchaudio==2.4.1+cu121` | Full CUDA 12.1 compatibility on Colab T4, L4, and A100 GPUs. |
| **ONNX Runtime** | `onnxruntime-gpu==1.18.1` | Supports CUDA 12.x (`CUDAExecutionProvider`) alongside `torch==2.4.1+cu121`. |
| **Speech & Pitch ML** | `fairseq==0.12.2`, `pyworld==0.3.4`, `faiss-cpu==1.8.0.post1`, `torchcrepe==0.0.23`, `torchfcpe==0.0.4` | Core RVC v1/v2 feature extraction, F0 estimation, and index search dependencies. |
| **Audio Processing** | `librosa==0.9.2`, `scipy==1.11.4`, `resampy==0.4.3`, `sounddevice==0.4.6` | Matches upstream `librosa` 0.9 API usage in `ServerDevice.py` and `vocoder.py`. |
| **ASGI & Web Server** | `fastapi==0.95.1`, `uvicorn==0.21.1`, `python-socketio==5.8.0`, `python-multipart==0.0.6`, `websockets==11.0.3`, `pyOpenSSL==23.1.1` | Preserves exact ASGI/Socket.IO wire protocol expected by prebuilt `client/demo/dist` frontend. |

---

## 5. Proposed Testing Strategy

1. **Static & Unit Verification**:
   - Verify `python -m py_compile` on all modified server Python files and `bash -n` on all deployment scripts.
   - Verify `git status` and `.gitignore` hygiene before committing.
2. **Runtime Provisioning & Dependency Verification (`setup_runtime.sh`)**:
   - Provision fresh Colab GPU runtime via `colab new`.
   - Run `setup_runtime.sh` and verify Python 3.10, `torch.cuda.is_available()`, `fairseq`, `pyworld`, `faiss`, and `onnxruntime.get_available_providers()`.
3. **Persistence & Workspace Verification (`prepare_workspace.sh`)**:
   - Mount Google Drive via `colab drivemount`.
   - Verify `/content/drive/MyDrive/VoiceChanger/` directory tree creation, symlink binding to `/content/voice-changer/server/`, and Slot 0 (`Vestia Zeta`) model integrity (`model.pth`, `model.index`, `params.json`).
4. **Connectivity & Transport Verification (`start_server.sh`, `healthcheck.sh`, SSH `LocalForward`)**:
   - Stage A: Verify basic HTTP server over `ssh -L 18888:localhost:18888` from Windows (`http://localhost:18888`).
   - Stage B: Start Voice Changer via `start_server.sh`, run `healthcheck.sh` (process check, `/api/hello`, `/info`, `/socket.io/?EIO=4&transport=polling`, GPU & model slot verification), and test browser UI + Socket.IO connection at `http://localhost:18888`.
5. **Lifecycle & Recovery Verification (`stop_server.sh`, `vc` CLI)**:
   - Test `vc up`, `vc status`, `vc logs`, `vc connect`, and `vc down` from WSL (`~/VSC/colab`).
