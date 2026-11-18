#!/usr/bin/env bash
# Phase 8.3 - Python toolchain and a PyTorch sanity check on sm_120.
#
# The check matters: torch wheels below 2.7 (the cu124/cu126 era) ship no
# sm_120 kernels at all, and no amount of configuration fixes that. Anything
# built on such a pin has to be reinstalled against cu128 or newer.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_not_root

section "Build prerequisites"

sudo apt-get update -qq
sudo apt-get install -y -qq \
    build-essential cmake ninja-build pkg-config \
    git curl wget ca-certificates \
    python3 python3-venv python3-pip python3-dev \
    libsndfile1 ffmpeg
ok "Base packages installed."

section "uv"

if have uv; then
    ok "uv already installed ($(uv --version))"
else
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    have uv && ok "uv installed ($(uv --version))" || warn "uv not on PATH; open a new shell."
fi

section "Driver check"

if ! have nvidia-smi; then
    die "nvidia-smi not found. Run ./01-nvidia.sh and reboot first."
fi
nvidia-smi --query-gpu=name,memory.total,driver_version,compute_cap --format=csv | sed 's/^/    /'

compute_cap="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -n1 | tr -d ' ')"
if [[ "$compute_cap" == "12.0" ]]; then
    ok "Compute capability 12.0 (sm_120) as expected."
else
    warn "Compute capability reported as '$compute_cap'; expected 12.0."
fi

section "PyTorch probe"

# Disposable venv: proves the wheel works before any real project depends on it.
probe_dir="$(mktemp -d)"
trap 'rm -rf "$probe_dir"' EXIT

info "Creating a throwaway venv and installing torch from the cu128 index."
# NumPy comes along only to silence torch's "Failed to initialize NumPy"
# warning. It is harmless and unrelated to CUDA, but it prints in red next to
# the result and reads like a failure when the probe has in fact passed.
if have uv; then
    uv venv "$probe_dir/venv" --python 3.12 >/dev/null
    uv pip install --python "$probe_dir/venv/bin/python" torch numpy \
        --index-url https://download.pytorch.org/whl/cu128 >/dev/null
else
    python3 -m venv "$probe_dir/venv"
    "$probe_dir/venv/bin/pip" install -q torch numpy --index-url https://download.pytorch.org/whl/cu128
fi

if "$probe_dir/venv/bin/python" - <<'PY'
import sys
import torch

print(f"    torch        {torch.__version__}")
print(f"    cuda avail   {torch.cuda.is_available()}")
if not torch.cuda.is_available():
    sys.exit(1)
print(f"    device       {torch.cuda.get_device_name(0)}")
print(f"    capability   sm_{''.join(map(str, torch.cuda.get_device_capability(0)))}")

# Actually execute a kernel. is_available() can be True while no kernel image
# exists for this architecture.
x = torch.randn(4096, 4096, device="cuda")
y = x @ x
torch.cuda.synchronize()
print(f"    matmul       {tuple(y.shape)} on {y.device}  OK")
PY
then
    ok "PyTorch runs real kernels on this GPU."
else
    err "PyTorch could not execute on the GPU."
    warn "If the error mentions 'no kernel image is available', the wheel is too old."
    warn "Use the cu128 index or newer - never cu124."
    exit 1
fi

section "Next"
info "./04-llamacpp.sh   build llama.cpp with CUDA"
info "./05-comfyui.sh    image and video generation"
info "./06-voice.sh      transcription and speech"
info "./07-strata.sh     Every Strata model this machine can run"
