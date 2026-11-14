#!/usr/bin/env bash
set -e

SESSION_NAME="${1:-voice}"
GPU_TYPE="${2:-A100}"

echo "=================================================="
echo "🚀 Google Colab A100 Launcher (WSL -> Colab)"
echo "   Session : $SESSION_NAME"
echo "   GPU     : $GPU_TYPE"
echo "=================================================="

# 1. Create session if it doesn't already exist
if colab sessions 2>/dev/null | grep -q "$SESSION_NAME"; then
    echo "> [1/4] Found existing active session: $SESSION_NAME"
else
    echo "> [1/4] Provisioning new Colab session ($GPU_TYPE)..."
    colab new -s "$SESSION_NAME" --gpu "$GPU_TYPE"
    echo "> ✓ Session '$SESSION_NAME' created successfully!"
fi

# 2. Mount Google Drive
echo "> [2/4] Mounting Google Drive on Colab VM..."
colab drivemount -s "$SESSION_NAME" || true
echo "> ✓ Google Drive mount ready at /content/drive"

# 3. Upload setup_and_run.sh to the VM
echo "> [3/4] Uploading setup_and_run.sh to VM..."
colab upload "$HOME/VSC/colab/setup_and_run.sh" -s "$SESSION_NAME" /content/setup_and_run.sh || true

# 4. Connect via SSH with port forwarding
echo "=================================================="
echo "🔗 [4/4] Connecting to Colab VM via SSH..."
echo "   Local port 8000 is automatically forwarded:"
echo "   👉 Once the server starts, open: http://localhost:8000"
echo ""
echo "   💡 To start the Voice Changer, simply run:"
echo "      bash /content/setup_and_run.sh"
echo "=================================================="
ssh colab-a100
