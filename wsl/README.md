# Tuned Voice Changer — WSL Orchestration Guide (`~/VSC/colab`)

Compact operational reference for running **RVC Voice Changer** ([`Zeesat/tuned-voice-changer`](https://github.com/Zeesat/tuned-voice-changer)) on Google Colab GPU runtimes from WSL Ubuntu.

---

## 1. Quick Start (Daily Workflow)

```bash
# 1. Start everything (T4 GPU by default for testing; mounts Drive, sets up env, starts server & SSH tunnel)
vc up

# --- OR for End-User Production on A100 GPU ---
vc up --gpu A100
```

Once `vc up` finishes, open your Windows browser at:
👉 **[http://localhost:18888/front/](http://localhost:18888/front/)**

*(Always use `http://localhost:18888/front/` so Chrome/Edge treats the page as a Secure Context and enables microphone input.)*

```bash
# 2. When finished, stop the server, close the SSH tunnel, and terminate the Colab GPU VM:
vc down --stop-session
```

---

## 2. `vc` CLI Command Reference

`vc` is installed at `~/VSC/colab/vc` and symlinked to `~/.local/bin/vc`.

| Command | Description |
|---|---|
| `vc up` | Provision/reuse a `T4` GPU session (`vc`), mount Google Drive, pull latest repo into `/content/voice-changer`, build/verify `/content/vc_env`, start `MMVCServerSIO.py`, run healthchecks, and start the background SSH tunnel (`localhost:18888`). |
| `vc up --gpu A100` | Same as `vc up`, but provisions an **A100** GPU runtime for production use (`L4`, `G4`, `H100` also supported). |
| `vc add-model <path>` | Upload a local RVC model folder or `.pth` (plus `.index`) to the running server and persist it to Google Drive. |
| `vc status` | Display Colab session status, local SSH tunnel PID, GPU VRAM usage, Git commit SHA, and 7-point remote healthcheck. |
| `vc logs` | Print the last 60 lines of `/content/vc_server.log` (`vc logs -n 100` for more lines, `vc logs -f` to follow live). |
| `vc connect` | Start or re-establish the background SSH `LocalForward` tunnel (`127.0.0.1:18888 -> Colab:18888`). Use `vc connect --foreground` to run interactively. |
| `vc down` | Stop remote `MMVCServerSIO.py`, close the local SSH tunnel, and prompt whether to terminate the Colab GPU session. |
| `vc down --keep-session` | Stop the Voice Changer server and SSH tunnel, but keep the Colab GPU VM alive (preserves `/content/vc_env` for fast restarts). |
| `vc down --stop-session` | Stop the server, close the tunnel, and **immediately terminate** the Colab GPU session so zero compute units are consumed. |

---

## 3. Adding RVC Models (Persisted on Google Drive)

Because `/content/voice-changer/server/model_dir` is symlinked to `/content/drive/MyDrive/VoiceChanger/models/custom`, any model added via either method below is automatically saved to Google Drive for future sessions:

- **Option A — `vc add-model` (fastest from WSL)**:
  ```bash
  # While vc up / vc connect is running:
  vc add-model /mnt/d/VSC/colab/zetaTest
  # Or pass a Windows path or explicit slot:
  vc add-model "D:\VSC\colab\zetaTest" --slot 1
  ```
- **Option B — Web UI**: Open [http://localhost:18888/front/](http://localhost:18888/front/), click **Edit** on an empty slot, choose **RVC**, select your `.pth` and `.index` files, and click **Upload**.

---

## 4. Google Drive Mounting & OAuth Helper

If `vc up` needs initial Google Drive OAuth approval (or if you want to provision a session and mount Drive manually first):

```bash
cd ~/VSC/colab
./mount_drive.sh          # Provisions/reuses session 'vc' with T4 GPU and mounts /content/drive
./mount_drive.sh A100     # Provisions/reuses session 'vc' with A100 GPU and mounts /content/drive
```
1. If Google prints an OAuth authorization URL, open it in your Windows browser and click **Allow**.
2. Return to the WSL terminal and press **`Enter`**.

---

## 5. Direct Colab CLI & SSH Commands

All underlying `colab` CLI commands remain available if you need low-level runtime inspection:

```bash
colab usage                     # Check remaining Colab compute units
colab sessions                  # List active Colab GPU sessions
colab stop -s vc                # Force-terminate Colab session 'vc'
ssh colab-vc                    # Open an interactive root shell on the Colab VM (multiplexed over ControlMaster)
```

---

## 5. Architecture & File Locations

| Layer | Path | Purpose |
|---|---|---|
| **WSL Orchestration** | `~/VSC/colab/` (`vc`, `mount_drive.sh`, `~/.ssh/config`) | Lifecycle CLI and persistent `systemd-run --user` SSH `ControlMaster` tunnel (`vc-ssh-tunnel.service`). |
| **Windows Source Dev** | `D:\VSC\colab\voice-changer\` (`/mnt/d/VSC/colab/voice-changer`) | Git working tree pushing to `https://github.com/Zeesat/tuned-voice-changer.git`. |
| **Colab Execution (SSD)** | `/content/voice-changer` & `/content/vc_env` | Disposable local SSD clone and Python 3.10 + CUDA 12.1 (`torch 2.4.1+cu121`, `onnxruntime-gpu 1.19.2`) virtualenv. |
| **Google Drive Persistence** | `/content/drive/MyDrive/VoiceChanger/` | Permanent storage for `models/pretrained/`, `models/custom/` (Slot `0`: **Vestia Zeta RVC v2**), and `configuration/stored_setting.json`. |

---

## 6. Recommended Voice Changer Settings by GPU (`T4`, `L4`, `A100`, `H100`)

Because audio travels between your Windows browser and the remote Colab GPU over an SSH `LocalForward` TCP tunnel (`~30–120 ms` network round-trip depending on region), **`CHUNK` size** must be balanced against network jitter while **`EXTRA`** controls context quality.

### 6.1 GPU Hardware & Compute Unit Comparison

| GPU (`--gpu`) | Architecture | VRAM | Relative Speed | Approx. Colab Compute Units | Best Use Case |
|---|---|---|---|---|---|
| **`T4`** | Turing (SM 7.5) | 15 GB | 1.0x (Baseline) | **~1.5 – 2.0 CU / hr** | Development, testing, and casual real-time voice conversion. |
| **`L4`** | Ada Lovelace (SM 8.9) | 22.5 GB | ~2.2x | **~4.5 – 5.0 CU / hr** | Best price-to-performance for long streaming/recording sessions. |
| **`G4`** | Blackwell / Ada | 16–24 GB | ~2.0x | **~4.0 – 5.0 CU / hr** | Low-latency real-time streaming when L4 is unavailable. |
| **`A100`** | Ampere (SM 8.0) | 40 / 80 GB | ~4.5x | **~10.0 – 13.0 CU / hr** | End-user production, maximum `EXTRA` context window, ultra-low GPU inference time (`<25 ms`). |
| **`H100`** | Hopper (SM 9.0) | 80 GB | ~7.0x | **~18.0+ CU / hr** | Overkill for single-stream RVC; only use if A100/L4 are out of capacity. |

---

### 6.2 Optimal Web UI Settings per GPU (`http://localhost:18888/front/`)

| Setting in Web UI | **Tesla T4** (`vc up --gpu T4`) | **NVIDIA L4 / G4** (`vc up --gpu L4`) | **NVIDIA A100 / H100** (`vc up --gpu A100`) | Why It Matters |
|---|---|---|---|---|
| **GPU Device** | `Tesla T4 (0)` | `NVIDIA L4 (0)` | `NVIDIA A100-SXM4 (0)` | Must be set to `0` (not `cpu`). |
| **F0 Det (Pitch Extractor)** | `rmvpe_onnx` *(or `fcpe`)* | `rmvpe_onnx` or `rmvpe` | `rmvpe` *(PyTorch FP16)* or `crepe_full` | `rmvpe_onnx` is fastest on T4; A100 easily runs full PyTorch `rmvpe` or `crepe_full` with zero lag. |
| **CHUNK (Input Chunk)** | **`192` – `256`** *(~160–210 ms)* | **`128` – `192`** *(~110–160 ms)* | **`96` – `128`** *(~80–110 ms)* | Over SSH, chunks `<96` cause packet overhead/crackling; `128–192` gives smooth real-time playback. |
| **EXTRA (Context Window)** | **`16384` – `32768`** | **`32768` – `65536`** | **`65536` – `131072`** | Larger `EXTRA` gives smoother pitch transitions and eliminates syllabic chopping, at the cost of GPU compute. |
| **TUNE (Pitch Shift)** | `+12` *(Male → Zeta)* / `0` *(Female → Zeta)* | `+12` *(Male → Zeta)* / `0` *(Female → Zeta)* | `+12` *(Male → Zeta)* / `0` *(Female → Zeta)* | Vestia Zeta is a higher-pitched female voice (`48kHz`); male speakers typically need `+10` to `+12` semitones. |
| **INDEX (Feature Ratio)** | `0.30` – `0.50` | `0.40` – `0.60` | `0.50` – `0.65` | Uses `model.index` (`FAISS`) to match Zeta's timbre. Keep `<=0.65` to avoid metallic artifacts. |
| **S.Thresh (Silence Gate)** | `0.00010` – `0.00050` | `0.00010` – `0.00050` | `0.00010` – `0.00050` | Prevents background mic hiss from being converted into breath noise during pauses. |
| **Protocol (Server Setting)** | `sio` *(Socket.IO)* | `sio` *(Socket.IO)* | `sio` *(Socket.IO)* | Multiplexes binary PCM frames over the existing SSH connection with minimal framing overhead. |

> **Tip for Audio Crackling / Stuttering over SSH**:
> If your internet connection to the Colab region has occasional ping spikes, increase **`CHUNK`** by one step (e.g., `128` → `192` or `256`) before lowering **`EXTRA`**. Network jitter affects `CHUNK` frequency much more than GPU `EXTRA` compute time.

---

## 7. Quick Troubleshooting

- **`http://localhost:18888/front/` does not load in Windows browser**:
  Run `vc status`. If the tunnel shows `[INACTIVE]`, run `vc connect`. If the server process is stopped, run `vc up`.
- **`Already-active SSH session (HTTP 429)`**:
  Colab allows only one active WebSocket SSH bridge per session. Always use `vc status` / `vc logs` / `ssh colab-vc` (which share the OpenSSH `ControlMaster` socket `~/.ssh/cm-root@colab-vc:22`) rather than calling bare `colab ssh -s vc` while the tunnel is active.
- **Resetting a stuck SSH tunnel**:
  ```bash
  systemctl --user stop vc-ssh-tunnel
  rm -f ~/.ssh/cm-root@colab-vc:22
  vc connect
  ```
