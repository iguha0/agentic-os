# Agentic OS Build System
TARGET ?= aarch64-musl
OUTPUT_DIR := build
SHELL_SRCS := shell/shell-ai.c shell/ai_client.c shell/local_llm.c shell/stubs.c
SHELL_BIN := $(OUTPUT_DIR)/agentic-shell

# AI-enabled version (alias)
SHELL_AI_SRCS := $(SHELL_SRCS)
SHELL_AI_BIN := $(OUTPUT_DIR)/agentic-shell-ai
SYSROOT := sysroot

# llama.cpp static libraries (built once via cmake, then linked in)
LLAMA_DIR := $(HOME)/llama.cpp
LLAMA_BUILD := $(LLAMA_DIR)/build
LLAMA_INC := -I $(LLAMA_DIR)/include -I $(LLAMA_DIR)/ggml/include
LLAMA_LIBS := \
    $(LLAMA_BUILD)/src/libllama.a \
    $(LLAMA_BUILD)/common/libllama-common.a \
    $(LLAMA_BUILD)/ggml/src/libggml.a \
    $(LLAMA_BUILD)/ggml/src/libggml-base.a \
    $(LLAMA_BUILD)/ggml/src/libggml-cpu.a \
    $(LLAMA_BUILD)/vendor/cpp-httplib/libcpp-httplib.a

# Cross-compilation settings
ifeq ($(TARGET),aarch64-musl)
    CC := /opt/homebrew/bin/aarch64-linux-musl-gcc
    CXX := /opt/homebrew/bin/aarch64-linux-musl-g++
    CFLAGS := -static -Os -fno-stack-protector -fomit-frame-pointer -fPIC
endif
ifeq ($(TARGET),aarch64)
    CC := aarch64-linux-gnu-gcc
    CXX := aarch64-linux-gnu-g++
    CFLAGS := -static -Os -fno-stack-protector -fomit-frame-pointer -fPIC
endif
ifeq ($(TARGET),native)
    CC := gcc
    CXX := g++
    CFLAGS := -Os -fno-stack-protector -fomit-frame-pointer -fPIC
endif

CFLAGS += -Wall -Wextra -Wno-unused-function -Wno-unused-parameter \
    -std=gnu11 \
    -I $(SYSROOT)/usr/include \
    $(LLAMA_INC) \
    -D_GNU_SOURCE -D_POSIX_C_SOURCE=200112L

CXXFLAGS := $(CFLAGS) -std=gnu++17

LDFLAGS := -static -lpthread -lm -ldl

.PHONY: all clean check install
all: check $(SHELL_BIN)

check:
	@echo "Using compiler: $(CC) / $(CXX)"
	@command -v $(CC) >/dev/null 2>&1 || { echo "ERROR: $(CC) not found"; exit 1; }
	@command -v $(CXX) >/dev/null 2>&1 || { echo "ERROR: $(CXX) not found"; exit 1; }
	@test -f $(LLAMA_BUILD)/src/libllama.a || { echo "ERROR: llama.cpp not built. Run: cd ~/llama.cpp && mkdir -p build && cd build && cmake .. -DCMAKE_C_COMPILER=/opt/homebrew/bin/aarch64-linux-musl-gcc -DCMAKE_CXX_COMPILER=/opt/homebrew/bin/aarch64-linux-musl-g++ -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_UI=OFF && make -j2"; exit 1; }

# Compile C sources to objects first, then link with C++ to pull in stdc++
OBJ_DIR := $(OUTPUT_DIR)/obj
OBJECTS := $(patsubst shell/%.c,$(OBJ_DIR)/%.o,$(SHELL_SRCS))

$(OBJ_DIR)/%.o: shell/%.c | $(OBJ_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(SHELL_BIN): $(OBJECTS) | $(OUTPUT_DIR)
	@echo "Linking $(SHELL_BIN) with llama.cpp..."
	$(CXX) -o $@ $(OBJECTS) $(LLAMA_LIBS) $(LDFLAGS)
	@echo "Build successful: $@"
	@ls -lh $@

$(OUTPUT_DIR) $(OBJ_DIR):
	mkdir -p $@

install: $(SHELL_BIN)
	@echo "Installing to rootfs..."
	@mkdir -p rootfs/bin
	@cp $(SHELL_BIN) rootfs/bin/agentic-shell
	@chmod +x rootfs/bin/agentic-shell
	@cp $(SHELL_BIN) rootfs/bin/agentic-shell-ai
	@chmod +x rootfs/bin/agentic-shell-ai
	@echo "Installed to rootfs/bin/agentic-shell (+ shell-ai)"

clean:
	rm -rf $(OUTPUT_DIR)
