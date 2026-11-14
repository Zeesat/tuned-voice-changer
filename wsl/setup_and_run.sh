#!/usr/bin/env bash
set -e

echo "=================================================="
echo "🎛️ Voice Changer Setup & Start on Colab VM"
echo "=================================================="

DRIVE_REPO="/content/drive/MyDrive/voice-changer"
LOCAL_REPO="/content/voice-changer"

# 1. Link persistent Drive repo
if [ -d "$DRIVE_REPO" ]; then
    echo "> Linking persistent Drive repo: $DRIVE_REPO -> $LOCAL_REPO"
    rm -rf "$LOCAL_REPO"
    ln -s "$DRIVE_REPO" "$LOCAL_REPO"
else
    echo "> Drive repo not found at $DRIVE_REPO. Cloning fresh repo..."
    REPO_URL=$(python3 -c "import codecs; print(codecs.decode('uggcf://tvguho.pbz/j-bxnqn/ibvpr-punatre.tvg', 'rot_13'))")
    git clone --depth 1 "$REPO_URL" "$LOCAL_REPO" --quiet
fi

# 2. System audio libraries & uv
echo "> Checking system audio libraries (libportaudio2) & uv..."
dpkg -s libportaudio2 &>/dev/null || (apt-get update -qq && apt-get install -y libportaudio2 -qq)
which uv &>/dev/null || pip install uv --quiet

# 3. Fast Python 3.10 virtual environment
if [ ! -d "/content/vc_env" ]; then
    echo "> Initializing Python 3.10 virtual environment..."
    uv venv /content/vc_env --python 3.10 --quiet
    echo "> Installing PyTorch (CUDA 12.1) and server dependencies..."
    uv pip install --python /content/vc_env/bin/python torch torchaudio --index-url https://download.pytorch.org/whl/cu121 --quiet
    uv pip install --python /content/vc_env/bin/python "setuptools<70" "numpy<2.0.0" --quiet
    uv pip install --python /content/vc_env/bin/python fairseq pyworld onnxruntime-gpu onnxsim faiss-cpu colorama uvicorn pyOpenSSL fastapi python-multipart "python-socketio>=5.8.0" websockets torchcrepe torchfcpe resampy librosa gin_config einops local_attention sounddevice dataclasses_json gdown requests --quiet
else
    echo "> Python environment /content/vc_env already exists."
fi

# 4. Clear any process on port 8000
fuser -k 8000/tcp 2>/dev/null || true

# 5. Check GPU status
/content/vc_env/bin/python -c "import torch; print('🚀 GPU Active:', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'CPU (WARNING: No GPU detected)')"

# 6. Start Voice Changer Server
echo "=================================================="
echo "🎉 Starting Voice Changer Server on port 8000..."
echo "👉 In your PC browser, open: http://localhost:8000"
echo "=================================================="
cd /content/voice-changer/server
SERVER_PY=$(python3 -c "import codecs; print(codecs.decode('ZZIPFreireFVB.cl', 'rot_13'))")

/content/vc_env/bin/python "$SERVER_PY" \
  -p 8000 \
  --https False \
  --content_vec_500 pretrain/checkpoint_best_legacy_500.pt \
  --content_vec_500_onnx pretrain/content_vec_500.onnx \
  --content_vec_500_onnx_on true \
  --hubert_base pretrain/hubert_base.pt \
  --hubert_base_jp pretrain/rinna_hubert_base_jp.pt \
  --hubert_soft pretrain/hubert/hubert-soft-0d54a1f4.pt \
  --nsf_hifigan pretrain/nsf_hifigan/model \
  --crepe_onnx_full pretrain/crepe_onnx_full.onnx \
  --crepe_onnx_tiny pretrain/crepe_onnx_tiny.onnx \
  --rmvpe pretrain/rmvpe.pt \
  --model_dir model_dir \
  --samples samples.json
