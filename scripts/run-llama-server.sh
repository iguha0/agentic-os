#!/bin/bash
# Run llama.cpp server on the Mac host so the Agentic OS VM can reach it.
# The VM sees the host as 10.0.2.2 (QEMU user networking default).
set -e

MODEL_FILE="${1:-/Users/indrajitguha/models/gemma-4-E4B-it-Q4_K_M.gguf}"
PORT="${2:-8080}"

LLAMA_DIR="${HOME}/llama.cpp"
LLAMA_SERVER="${LLAMA_DIR}/build-host/bin/llama-server"
LAUNCHD_LABEL="local.llama-server"

if [ ! -f "$MODEL_FILE" ]; then
    echo "ERROR: model not found: $MODEL_FILE"
    echo "Usage: $0 [path/to/model.gguf] [port]"
    exit 1
fi

# Build a native (Apple Silicon) llama-server if it doesn't exist.
if [ ! -x "$LLAMA_SERVER" ]; then
    echo "[run-llama-server] native llama-server not found; building in ${LLAMA_DIR}/build-host ..."
    cd "$LLAMA_DIR"
    cmake -S . -B build-host \
        -DLLAMA_BUILD_SERVER=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DLLAMA_BUILD_TOOLS=OFF \
        -DLLAMA_BUILD_SHARED_LIBS=OFF \
        -DGGML_METAL=OFF \
        -DGGML_CUDA=OFF \
        -DCMAKE_BUILD_TYPE=Release
    cmake --build build-host -j$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
fi

# Sanity-check that the binary is native macOS arm64 (not the cross-compiled one).
if ! file "$LLAMA_SERVER" | grep -qE 'Mach-O.*arm64'; then
    echo "WARNING: $LLAMA_SERVER does not look like a native macOS arm64 binary."
    echo "         It may have been cross-compiled for Linux. Continuing anyway..."
fi

# Clean up any previous instance (including stale launchctl job) so we don't
# fail with "couldn't bind HTTP server socket".
OLD_PID=$(lsof -ti :${PORT} 2>/dev/null || true)
if [ -n "$OLD_PID" ]; then
    echo "[run-llama-server] killing existing process on port ${PORT} (pid ${OLD_PID})"
    kill "$OLD_PID" 2>/dev/null || true
    sleep 1
fi
launchctl remove "$LAUNCHD_LABEL" 2>/dev/null || true

LOG_FILE="${TMPDIR:-/tmp}/llama-server-${PORT}.log"

echo "[run-llama-server] starting llama-server on 0.0.0.0:${PORT} with ${MODEL_FILE}"
echo "[run-llama-server] log file: ${LOG_FILE}"
echo "[run-llama-server] inside the VM, type:  !llama"
echo ""

# Apple M1 with 8 GB RAM: use --no-mmap to avoid overcommit/mmap issues,
# ctx-size 2048 to keep memory usage under ~3 GB, and CPU only.
# On macOS we use launchctl so the server survives terminal closure.
if [ "$(uname -s)" = "Darwin" ]; then
    launchctl submit -l "$LAUNCHD_LABEL" -o "$LOG_FILE" -e "$LOG_FILE" -- \
        "$LLAMA_SERVER" \
            -m "$MODEL_FILE" \
            --host 0.0.0.0 \
            --port "$PORT" \
            --ctx-size 2048 \
            -ngl 0 \
            --no-mmap
    sleep 1
    if launchctl list | awk '{print $3}' | grep -qx "${LAUNCHD_LABEL}"; then
        echo "[run-llama-server] started via launchctl label ${LAUNCHD_LABEL}"
        echo "[run-llama-server] stop later with:  launchctl remove ${LAUNCHD_LABEL}"
    else
        echo "[run-llama-server] launchctl submit did not keep the job; falling back to foreground"
        exec "$LLAMA_SERVER" \
            -m "$MODEL_FILE" \
            --host 0.0.0.0 \
            --port "$PORT" \
            --ctx-size 2048 \
            -ngl 0 \
            --no-mmap
    fi
else
    exec "$LLAMA_SERVER" \
        -m "$MODEL_FILE" \
        --host 0.0.0.0 \
        --port "$PORT" \
        --ctx-size 2048 \
        -ngl 0 \
        --no-mmap
fi
