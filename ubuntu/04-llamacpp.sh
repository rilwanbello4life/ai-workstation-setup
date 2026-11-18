#!/usr/bin/env bash
# Phase 8.4 - Build llama.cpp with CUDA support.
#
# This is the engine underneath most of the stack. Building it locally against
# sm_120 gives the best performance and makes GGUF files in ~/ai/gguf usable from
# the command line and from Pi.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_not_root

REPO="${APPS}/llama.cpp"

section "CUDA toolkit"

# nvcc is needed to compile the CUDA backend. Ubuntu's own nvidia-cuda-toolkit
# package is CUDA 12.0, which predates sm_120 - it must come from NVIDIA's repo.
if have nvcc; then
    ok "nvcc present: $(nvcc --version | tail -n2 | head -n1 | sed 's/^ *//')"
else
    warn "nvcc not found. Installing the CUDA toolkit from NVIDIA's repository."
    add_nvidia_repo
    sudo apt-get install -y cuda-toolkit || die "CUDA toolkit install failed."

    for p in /usr/local/cuda/bin /usr/local/cuda-13*/bin /usr/local/cuda-12*/bin; do
        [[ -d "$p" ]] && export PATH="$p:$PATH"
    done

    have nvcc || die "nvcc still not on PATH. Add /usr/local/cuda/bin to PATH and re-run."
    ok "nvcc installed."
fi

cuda_major="$(nvcc --version | grep -oP 'release \K[0-9]+' | head -n1)"
if [[ -n "$cuda_major" && "$cuda_major" -lt 12 ]]; then
    die "CUDA $cuda_major is too old for sm_120. Need 12.8 or newer."
fi

section "Source"

mkdir -p "$APPS"
if [[ -d "$REPO/.git" ]]; then
    info "Updating existing checkout."
    git -C "$REPO" pull --ff-only
else
    git clone https://github.com/ggml-org/llama.cpp.git "$REPO"
fi
ok "Source at $REPO"

section "Build"

# CMAKE_CUDA_ARCHITECTURES=120 targets Blackwell only, which keeps compile time
# down. Add more architectures (e.g. "86;120") only if you move the binaries to
# a different machine.
cmake -S "$REPO" -B "$REPO/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
    -DLLAMA_CURL=ON

cmake --build "$REPO/build" --config Release -j"$(nproc)"
ok "Build complete."

section "Install helpers"

mkdir -p "$HOME/.local/bin"
for tool in llama-server llama-cli llama-bench llama-quantize; do
    src="$REPO/build/bin/$tool"
    if [[ -x "$src" ]]; then
        ln -sf "$src" "$HOME/.local/bin/$tool"
        info "linked $tool"
    fi
done

launcher="$APPS/start-llama-server.sh"
cat > "$launcher" <<EOF
#!/usr/bin/env bash
# Serve a GGUF on an OpenAI-compatible endpoint.
#
#   ./start-llama-server.sh mymodel.gguf [extra llama-server args...]
#
# Port 8081 keeps clear of Strata (8080), LM Studio (1234) and ComfyUI (8188).
set -euo pipefail

MODEL="\${1:?usage: \$0 <model.gguf> [args...]}"
shift || true

[[ -f "\$MODEL" ]] || MODEL="$AI_ROOT/gguf/\$MODEL"
[[ -f "\$MODEL" ]] || { echo "Model not found: \$MODEL" >&2; exit 1; }

exec "$REPO/build/bin/llama-server" \\
    --model "\$MODEL" \\
    --host 127.0.0.1 --port 8081 \\
    --n-gpu-layers 999 \\
    --ctx-size 8192 \\
    --flash-attn \\
    "\$@"
EOF
chmod +x "$launcher"
ok "Wrote $launcher"

section "Verify"

if "$REPO/build/bin/llama-cli" --version 2>&1 | head -n5 | sed 's/^/    /'; then
    ok "llama.cpp responds."
fi

cat <<EOF

  Models go in $AI_ROOT/gguf/.

  Serve one with:
      $launcher my-model.gguf

  Then point Pi, Cursor or any OpenAI client at:
      http://127.0.0.1:8081/v1

  Sizing rule on 16 GB VRAM: at Q4_K_M a dense model needs roughly
  parameters x 0.6 GB, so stay at or below 14B to keep it fully resident.

  Next: ./05-comfyui.sh
EOF
