/*
 * local_llm.h — wrapper for llama.cpp local inference.
 * Used by ai_client.c to call the local model.
 */
#ifndef LOCAL_LLM_H
#define LOCAL_LLM_H

#include <stddef.h>

/* Initialize the local model. Returns 0 on success, -1 on failure. */
int local_llm_init(const char *model_path, int n_ctx, int n_threads);

/* Shutdown and free resources. */
void local_llm_shutdown(void);

/* Check if the model is loaded and ready. */
int local_llm_ready(void);

/*
 * Run inference. prompt is the full prompt text; response is filled
 * with the model's reply. Returns 0 on success, -1 on failure.
 *
 * Max response length is resp_size - 1 (NUL terminated).
 */
int local_llm_infer(const char *prompt, char *response, size_t resp_size, int max_tokens);

/*
 * High-level helper: takes a system prompt and user message separately,
 * formats them with the Gemma 4 chat template, and runs inference.
 */
int local_llm_query(const char *system_prompt, const char *user_message,
                    char *response, size_t resp_size, int max_tokens);

#endif /* LOCAL_LLM_H */
