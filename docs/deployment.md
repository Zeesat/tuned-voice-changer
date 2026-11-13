# Deployment Guide — Tuned Voice Changer on Google Colab

## 1. Prerequisites

1. **WSL2 Ubuntu** with:
   - `google-colab-cli` (`v0.8.0+`) installed at `~/.local/bin/colab` and authenticated via OAuth (`colab usage`).
   - OpenSSH client (`ssh`) with an Ed25519 key pair (`~/.ssh/id_ed25519`).
2. **Google Drive** with sufficient free space (~2 GB) for pretrained weights and custom RVC models.
3. **Google Colab GPU Runtime** (`T4`, `L4`, or `A100`).

---

## 2. Automated Lifecycle via WSL `vc` CLI

From WSL (`~/VSC/colab`):

```bash
# 1. Provision/reuse Colab GPU session, mount Drive, prepare workspace, install env, start server
vc up

# 2. Check session, GPU, server PID, model slots, and healthcheck status
vc status

# 3. Open persistent SSH port forwarding (http://localhost:18888)
vc connect

# 4. View remote server startup and inference logs
vc logs

# 5. Stop remote Voice Changer server cleanly (pass --stop-session to terminate Colab VM)
vc down
```

---

## 3. Manual Execution on a Colab Runtime

If executing the deployment scripts directly inside a Colab terminal or via `colab exec`:

```bash
# 1. Clone repository onto fast local SSD (never on Google Drive)
git clone https://github.com/Zeesat/tuned-voice-changer.git /content/voice-changer

# 2. Prepare Google Drive persistent directories, symlinks, and Slot 0 model
bash /content/voice-changer/deployment/colab/prepare_workspace.sh

# 3. Provision /content/vc_env (Python 3.10 + PyTorch 2.4.1+cu121 + fairseq + pyworld)
bash /content/voice-changer/deployment/colab/setup_runtime.sh

# 4. Start Voice Changer server on 127.0.0.1:18888 in background daemon mode
bash /content/voice-changer/deployment/colab/start_server.sh --daemon

# 5. Run end-to-end healthcheck
bash /content/voice-changer/deployment/colab/healthcheck.sh
```

---

## 4. Persistent Google Drive Layout

`prepare_workspace.sh` maintains the following structure under `/content/drive/MyDrive/VoiceChanger/`:

```text
/content/drive/MyDrive/VoiceChanger/
├── models/
│   ├── pretrained/      # Symlinked from /content/voice-changer/server/pretrain
│   └── custom/          # Symlinked from /content/voice-changer/server/model_dir
│       └── 0/           # Slot 0: Vestia Zeta (model.pth, model.index, params.json)
├── checkpoints/         # Raw .pth model backups
├── indexes/             # Raw .index backups
├── configuration/       # Persisted stored_setting.json
└── backups/             # Latest server logs and setting snapshots
```

---

## 5. Recommended Voice Changer Settings by GPU (`T4`, `L4`, `G4`, `A100`, `H100`)

| Setting in Web UI | **Tesla T4** (`vc up --gpu T4`) | **NVIDIA L4 / G4** (`vc up --gpu L4`) | **NVIDIA A100 / H100** (`vc up --gpu A100`) | Notes |
|---|---|---|---|---|
| **Compute Units (Approx.)** | `~1.5 – 2.0 CU / hr` | `~4.5 – 5.0 CU / hr` | `~10.0 – 13.0+ CU / hr` | T4 for testing; L4/A100 for production. |
| **F0 Det (Pitch Extractor)** | `rmvpe_onnx` *(or `fcpe`)* | `rmvpe_onnx` or `rmvpe` | `rmvpe` *(PyTorch FP16)* or `crepe_full` | `rmvpe_onnx` uses ONNX Runtime CUDA 12. |
| **CHUNK (Input Chunk)** | **`192` – `256`** | **`128` – `192`** | **`96` – `128`** | Balances real-time latency against SSH TCP jitter. |
| **EXTRA (Context Window)** | **`16384` – `32768`** | **`32768` – `65536`** | **`65536` – `131072`** | Higher `EXTRA` improves pitch stability and smoothness. |
| **TUNE (Pitch Shift)** | `+12` *(Male → Zeta)* / `0` *(Female)* | `+12` *(Male → Zeta)* / `0` *(Female)* | `+12` *(Male → Zeta)* / `0` *(Female)* | Adjust by ±1–2 semitones for natural resonance. |
| **INDEX (Feature Ratio)** | `0.30` – `0.50` | `0.40` – `0.60` | `0.50` – `0.65` | Uses FAISS `model.index` to match target timbre. |
| **S.Thresh (Silence Gate)** | `0.00010` – `0.00050` | `0.00010` – `0.00050` | `0.00010` – `0.00050` | Suppresses idle microphone noise. |

