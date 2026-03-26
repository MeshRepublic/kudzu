#!/bin/bash
# EXLA GPU Environment Setup for Kudzu
# Sources NVIDIA library paths for CUDA 12 + RTX 4090 support
# Usage: source exla_env.sh && mix run --no-halt

NVIDIA_LIBS=/home/eel/.local/lib/python3.12/site-packages/nvidia

export LD_LIBRARY_PATH=/home/eel/.local/lib:${NVIDIA_LIBS}/nccl/lib:${NVIDIA_LIBS}/nvshmem/lib:${NVIDIA_LIBS}/cudnn/lib:${NVIDIA_LIBS}/cublas/lib:${LD_LIBRARY_PATH:-}
export XLA_TARGET=cuda12
export XLA_FLAGS="--xla_gpu_cuda_data_dir=/home/eel/.local/cuda"

# Anthropic API key for Brain Tier 4 (Claude API fallback)
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$(grep ANTHROPIC_API_KEY ~/.bashrc | head -1 | cut -d\" -f2)}"

# Kudzu API key for Brain chat authentication
export KUDZU_API_KEY="${KUDZU_API_KEY:-$(grep KUDZU_API_KEY ~/.bashrc | head -1 | cut -d= -f2)}"
