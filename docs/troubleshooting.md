# Troubleshooting Guide — Tuned Voice Changer

## 1. Dependency & Build Issues on Colab

### `ModuleNotFoundError: No module named 'distutils'`
- **Cause**: Python 3.12+ and `setuptools>=70` removed `distutils`.
- **Resolution**:
  - `server/MMVCServerSIO.py` has been patched to use a standard-library `strtobool()` implementation.
  - `deployment/colab/setup_runtime.sh` provisions a dedicated **Python 3.10** environment at `/content/vc_env` with `setuptools<70.0.0`.

### `fairseq` or `pyworld` fails to build wheel during `pip install`
- **Cause**: Modern pip/uv build isolation pulls `setuptools>=70` and `cython>=3.0` inside temporary build environments.
- **Resolution**: `setup_runtime.sh` pre-installs `setuptools<70.0.0`, `wheel`, `cython<3.0.0`, and `numpy==1.26.4` first, then installs `pyworld==0.3.4` and `fairseq==0.12.2` using `--no-build-isolation`.

---

## 2. Google Drive & Model Persistence Issues

### `Google Drive is not mounted at /content/drive/MyDrive`
- **Cause**: The Colab runtime has not mounted Google Drive FUSE yet, or OAuth authorization is pending.
- **Resolution**:
  - Run `colab drivemount -s <session_id>` from WSL and complete the OAuth browser prompt if requested, or mount via a 1-cell notebook (`from google.colab import drive; drive.mount('/content/drive')`).

### Model loads in UI but inference fails with tensor dimension mismatch (`256` vs `768`)
- **Cause**: RVC v1 models use 256-channel features (`layer 9`), whereas RVC v2 models (`SynthesizerTrnMs768NSFsid`, such as Vestia Zeta RVC v2) require `embChannels: 768`, `embOutputLayer: 12`, and `useFinalProj: false`.
- **Resolution**: Ensure `model_dir/0/params.json` has `"embChannels": 768`, `"embOutputLayer": 12`, `"useFinalProj": false`, and `"modelType": "pyTorchRVCv2"`. Re-run `prepare_workspace.sh` after deleting an invalid `params.json` to regenerate it automatically.

---

## 3. SSH Port Forwarding & Browser Audio Issues

### `http://localhost:18888` refuses connection on Windows
- **Cause**: Either the SSH `LocalForward` tunnel is not active in WSL, or `MMVCServerSIO.py` stopped on the Colab runtime.
- **Resolution**:
  1. Run `vc status` in WSL to check both the remote server process and local port `18888`.
  2. Run `vc connect` to establish the SSH tunnel (`-L 18888:127.0.0.1:18888`).

### Browser microphone permission is blocked
- **Cause**: Accessing the web UI via a non-localhost IP address over plain HTTP disables `navigator.mediaDevices.getUserMedia`.
- **Resolution**: Always open `http://localhost:18888` (not `http://<wsl-ip>:18888`). Browsers treat `localhost` as a Secure Context over HTTP.
