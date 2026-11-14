# Tuned Voice Changer (`Zeesat/tuned-voice-changer`)

> **Customized Fork Notice:** This repository ([**Zeesat/tuned-voice-changer**](https://github.com/Zeesat/tuned-voice-changer)) is a customized fork of [**w-okada/voice-changer**](https://github.com/w-okada/voice-changer) (base commit [`d8ef157`](https://github.com/w-okada/voice-changer/commit/d8ef157)).
>
> The original upstream README is preserved in full at [`README_ori.md`](README_ori.md).

---

## 1. Changes Made Compared to Upstream

All customizations focus on reproducible Google Colab GPU execution, Google Drive persistence, private SSH access, and WSL2 orchestration—without altering core RVC inference behavior:

- **Python 3.10+ & Linux Server Stability Fixes (`server/`)**:
  - `server/MMVCServerSIO.py` & `server/restapi/MMVC_Rest.py`: Replaced deprecated `distutils.util.strtobool` with a standard-library implementation; added configurable `--reload` flag (disabled by default in production); enabled foreground execution on Linux; added `os.makedirs(params.model_dir, exist_ok=True)` before scanning weights.
  - `server/mods/log_control.py`: Fixed `uvicorn` access logger suppression.
- **Google Colab GPU Deployment Suite (`deployment/colab/`)**:
  - `setup_runtime.sh`: Provisions `/content/vc_env` (Python 3.10 via `uv` with `--clear`), installs `torch` (`cu121`) and pinned ML dependencies with `--index-strategy unsafe-best-match`, sets `READTHEDOCS=1` for `fairseq` sdist builds, installs `onnxruntime-gpu==1.19.2` for CUDA 12, and exports NVIDIA `LD_LIBRARY_PATH` directories.
  - `prepare_workspace.sh`: Verifies `/content/drive` mount, initializes persistent `/content/drive/MyDrive/VoiceChanger/` (`models/pretrained`, `models/custom`, `checkpoints`, `indexes`, `configuration`, `backups`), auto-migrates legacy Drive `voice-changer/server` weights if present, supports transient `GIT_ASKPASS` for private repo clones, and symlinks Drive storage into `/content/voice-changer/server/`.
  - `start_server.sh`, `stop_server.sh`, `healthcheck.sh`: Clean process lifecycle management on `127.0.0.1:18888` and 7-point healthcheck verification.
  - `requirements-colab.txt` & `config.env.example`: Verified dependency pins and environment configuration template.
- **WSL2 Ubuntu Orchestration Suite (`wsl/`)**:
  - `wsl/vc`: Single-entry CLI (`vc up`, `vc add-model`, `vc status`, `vc logs`, `vc connect`, `vc down`) managing Colab GPU sessions (`T4`, `A100`, `L4`, `G4`, `H100`), Drive mounting, workspace setup, SSH `LocalForward` (`http://localhost:18888`), and model uploads.
  - `wsl/mount_drive.sh`, `wsl/launch_colab.sh`, `wsl/setup_and_run.sh`, `wsl/stop_colab.sh`, and `wsl/README.md`.
- **Repository & Documentation (`docs/`, `.gitignore`, `.gitattributes`)**:
  - Added [`docs/audit-report.md`](docs/audit-report.md), [`docs/architecture.md`](docs/architecture.md), [`docs/deployment.md`](docs/deployment.md) (including recommended UI settings per GPU tier), [`docs/troubleshooting.md`](docs/troubleshooting.md), and preserved [`README_ori.md`](README_ori.md).
  - Enforced LF line endings for shell scripts via `.gitattributes` and excluded runtime artifacts/weights via `.gitignore`.

---

## 2. New Computer Setup Guide (Windows + WSL2 Ubuntu)

Follow these steps to set up a brand-new Windows machine from scratch and run Voice Changer on Google Colab GPU.

### Step 1: Prepare WSL2 Ubuntu (Windows PowerShell)

If WSL2 Ubuntu is not installed yet, open **PowerShell as Administrator** and run:

```powershell
wsl --install -d Ubuntu
```

Reboot if prompted, launch **Ubuntu** from the Start Menu, and create your Linux username/password.

Inside the **Ubuntu (WSL)** terminal, install base system tools:

```bash
sudo apt-get update && sudo apt-get install -y \
  curl git openssh-client python3 ca-certificates
```

### Step 2: Install `uv` and `google-colab-cli` (`colab`)

In **Ubuntu (WSL)**:

```bash
# 1. Install uv
curl -LsSf https://astral.sh/uv/install.sh | sh
source ~/.local/bin/env 2>/dev/null || export PATH="$HOME/.local/bin:$PATH"

# 2. Install google-colab-cli with keyrings-alt for persistent OAuth token storage
uv tool install google-colab-cli --with keyrings-alt==5.0.2

# 3. Ensure ~/.local/bin is in PATH for future shells
grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' ~/.bashrc || \
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# 4. Verify installation
colab version
```

### Step 3: Authenticate Colab CLI & Create an SSH Key

1. **Generate an SSH key** (used by `colab ssh` / `vc connect` to tunnel `localhost:18888` to Colab):

   ```bash
   ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
   ```

2. **Authenticate `colab` with your Google account** (triggers OAuth2 login in your browser or prints an auth URL):

   ```bash
   colab usage
   ```

   Follow the OAuth prompt and verify your Colab compute-unit balance prints cleanly.

### Step 4: Clone the Repo & Install `wsl/` Scripts

In **Ubuntu (WSL)**:

```bash
# 1. Clone this repository (keep a local copy for reference, or clone anywhere you prefer)
mkdir -p ~/src ~/VSC/colab ~/.local/bin
git clone https://github.com/Zeesat/tuned-voice-changer.git ~/src/tuned-voice-changer

# 2. Copy the WSL orchestration scripts into ~/VSC/colab
cp ~/src/tuned-voice-changer/wsl/* ~/VSC/colab/

# 3. Ensure LF line endings, executable permissions, and symlink `vc` to PATH
sed -i 's/\r$//' ~/VSC/colab/*.sh ~/VSC/colab/vc
chmod +x ~/VSC/colab/*.sh ~/VSC/colab/vc
ln -sf ~/VSC/colab/vc ~/.local/bin/vc

# 4. Verify `vc` is ready
vc help
```

### Step 5: First Run & Google Drive Mount

1. Start Voice Changer on a Colab GPU (default `T4` for testing, or `--gpu A100` for production):

   ```bash
   vc up
   # or: vc up --gpu A100
   ```

   *On your first run on a new Colab runtime, `colab drivemount` will print a Google Drive OAuth URL. Open it in your Windows browser, click **Allow**, then return to WSL and press **Enter**.*

2. Once `vc up` completes, open Windows Chrome or Edge at:
   **[http://localhost:18888/front/](http://localhost:18888/front/)**
   *(Always use `http://localhost:18888/front/` so the browser treats it as a Secure Context for microphone capture.)*

3. **Add a custom RVC model** (persisted automatically to Google Drive `/content/drive/MyDrive/VoiceChanger/models/custom/`):

   ```bash
   vc add-model /mnt/d/path/to/model_folder
   # Windows paths also work directly:
   vc add-model "D:\path\to\model_folder"
   ```

4. **Stop when finished** (so you don't burn Colab compute units):

   ```bash
   vc down --stop-session
   ```

---

## 3. Daily `vc` Command Reference

| Command | Purpose |
|---|---|
| `vc up [--gpu T4\|A100\|L4]` | Provision/reuse GPU session, mount Drive, sync repo, setup `/content/vc_env`, start server, open SSH tunnel. |
| `vc add-model <dir_or_pth> [--slot N]` | Upload a local `.pth` + `.index` model to the running server and persist it on Google Drive. |
| `vc status` | Show session state, local SSH tunnel PID, GPU VRAM, Git SHA, and 7-point remote healthcheck. |
| `vc logs [-f] [-n 100]` | View or follow `/content/vc_server.log` from Colab. |
| `vc connect` | Re-establish the background SSH `LocalForward` (`localhost:18888 -> Colab:18888`). |
| `vc down [--stop-session\|--keep-session]` | Stop remote server, close SSH tunnel, and optionally terminate the Colab VM. |

---

## 4. Documentation Index

- [`wsl/README.md`](wsl/README.md) — Detailed WSL orchestration & `vc` CLI guide.
- [`docs/deployment.md`](docs/deployment.md) — Colab deployment details and recommended UI settings (`T4`, `L4`, `G4`, `A100`, `H100`).
- [`docs/architecture.md`](docs/architecture.md) — Three-layer architecture (Source, Persistence, Execution) and SSH tunnel topology.
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — Diagnostics and recovery procedures.
- [`docs/audit-report.md`](docs/audit-report.md) — Phase 1 audit report and dependency compatibility matrix.
- [`README_ori.md`](README_ori.md) — Original upstream `w-okada/voice-changer` README.
