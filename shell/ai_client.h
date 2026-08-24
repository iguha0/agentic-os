/*
 * AI Client — handles local LLM and cloud API calls.
 * Modes: auto, local, cloud, keywords
 */
#ifndef AI_CLIENT_H
#define AI_CLIENT_H

#include <stddef.h>

/* AI execution modes */
typedef enum {
    AI_MODE_AUTO,         /* Try local first, then llama-server, then cloud */
    AI_MODE_LOCAL,        /* Force local llama.cpp (model file in VM) */
    AI_MODE_LOCAL_SERVER, /* llama.cpp server on host at 10.0.2.2:8080 */
    AI_MODE_CLOUD,        /* Force cloud API */
    AI_MODE_KEYWORDS      /* Use simple keyword matching (no AI) */
} ai_mode_t;

/* AI backend type */
typedef enum {
    AI_BACKEND_NONE,
    AI_BACKEND_LOCAL_LLAMA,       /* in-VM llama.cpp loaded from file */
    AI_BACKEND_LOCAL_SERVER,    /* llama.cpp server on host Mac */
    AI_BACKEND_CLOUD_ANTHROPIC,
    AI_BACKEND_CLOUD_OPENAI
} ai_backend_t;

/* Configuration */
typedef struct {
    ai_mode_t mode;
    /* Local model settings */
    char model_path[512];
    int context_size;
    int threads;
    /* Cloud settings */
    char cloud_provider[64];
    char cloud_api_key[256];
    char cloud_model[128];
    char cloud_endpoint[256];
    /* System prompt */
    char system_prompt[1024];
    char local_server_url[256]; /* e.g. http://10.0.2.2:8080 */
} ai_config_t;

/* Response from AI */
typedef struct {
    int success;
    char text[4096];
    char command[1024];  /* Extracted shell command if applicable */
    ai_backend_t backend_used;
} ai_response_t;

/* Initialize AI client with config */
int ai_init(const ai_config_t *config);

/* Shutdown AI client */
void ai_shutdown(void);

/* Send intent to AI and get response */
ai_response_t ai_query(const char *intent);

/* Check if local model is available */
int ai_local_available(void);

/* Check if cloud is available (network + API key) */
int ai_cloud_available(void);

/* Get current mode */
ai_mode_t ai_get_mode(void);

/* Set mode at runtime */
void ai_set_mode(ai_mode_t mode);

/* Extract shell command from AI response (looks for code blocks or $ lines) */
void ai_extract_command(const char *response, char *cmd, size_t cmd_size);

/*
 * Dispatch a [TOOL:name key=val] call from AI response.
 * Returns 1 if a tool was found and executed, 0 otherwise.
 * result is filled with the tool's output.
 */
int tool_dispatch(const char *response, char *result, size_t result_size);

#endif /* AI_CLIENT_H */