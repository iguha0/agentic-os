# Agentic OS - AI Model Integration Plan

## Overview
Integrate real AI inference into the agentic shell with:
- **Local**: llama.cpp + Gemma 3 4B IT (Q4_K_M quantized) — ~2.5GB model, runs on mobile/aarch64
- **Cloud**: Claude API (Anthropic), OpenAI API, or any OpenAI-compatible endpoint
- **Hybrid**: Try local first, fallback to cloud, or user-selectable

## Architecture

```
┌─────────────────────────────────────────┐
│         Agentic Shell (C)               │
│  ┌──────────────────────────────────┐  │
│  │   Intent Router                  │  │
│  │   - Keyword match (fast path)    │  │
│  │   - Local LLM (offline)          │  │
│  │   - Cloud API (online)           │  │
│  └──────────────────────────────────┘  │
└─────────────────────────────────────────┘
           │              │              │
           ▼              ▼              ▼
    ┌──────────┐   ┌──────────┐   ┌──────────┐
    │ Keywords │   │ llama.cpp│   │ HTTPS    │
    │ (ls, df) │   │ + Gemma  │   │ Claude   │
    └──────────┘   └──────────┘   └──────────┘
```

## Implementation Steps

### Phase 1: Local Model (llama.cpp)
1. Build llama.cpp for aarch64-musl
2. Download Gemma 3 4B IT Q4_K_M GGUF
3. Bundle model in rootfs or mount from host
4. Add `llama-cli` wrapper calls in shell
5. Add config file for model selection

### Phase 2: Cloud API
1. Add HTTP client (mbedTLS or BearSSL)
2. Add JSON parser (cJSON - already in musl)
3. Implement Claude/OpenAI API calls
4. Add API key configuration
5. Add streaming response support

### Phase 3: Smart Routing
1. Detect network availability
2. Try local model first (privacy + offline)
3. Fallback to cloud for complex queries
4. Allow user to force mode: `!local`, `!cloud`, `!auto`

## Files to Create

- `shell/ai_client.c` - AI client library (local + cloud)
- `shell/ai_client.h` - Header
- `shell/local_llm.c` - llama.cpp wrapper
- `shell/cloud_api.c` - HTTPS API client
- `shell/config.h` - Configuration
- `models/` - Model files directory
- `config/agentic.conf` - Runtime config

## Configuration

```ini
# /etc/agentic.conf
[ai]
mode = auto  # auto, local, cloud, keywords

[local]
model_path = /usr/share/agentic/models/gemma-3-4b-it-q4.gguf
context_size = 2048
threads = 2

[cloud]
provider = anthropic  # anthropic, openai, custom
api_key = ${ANTHROPIC_API_KEY}
model = claude-3-5-haiku-20241022
endpoint = https://api.anthropic.com

[system]
prompt = You are an agentic shell. Convert user intent to shell commands. Output ONLY the command, no explanation.
```

## Model Choice: Gemma 3 4B IT

- **Size**: ~2.5GB Q4_K_M, ~4GB Q5_K_M
- **Context**: 8K tokens
- **License**: Apache 2.0 (open source)
- **Performance**: Runs on Pixel 8, iPhone 15, Raspberry Pi 5
- **Quantized**: GGUF format for llama.cpp
- **Download**: https://huggingface.co/google/gemma-3-4b-it-qat-q4_0-unquantized

Alternative: Gemma 3 2B (1.5GB) for even smaller devices.

## Next Steps

1. Build llama.cpp for aarch64-linux-musl
2. Download Gemma model
3. Integrate with shell
4. Add cloud API support
5. Test in QEMU

Let me start implementing!