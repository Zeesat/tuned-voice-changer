#!/usr/bin/env bash
SESSION_NAME="${1:-voice}"

echo "Stopping Colab session '$SESSION_NAME' to save compute units..."
colab stop -s "$SESSION_NAME"
echo "✓ Session '$SESSION_NAME' stopped."
colab usage
