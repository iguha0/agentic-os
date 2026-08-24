/*
 * local_llm.c — llama.cpp wrapper for agentic shell.
 * Links against libllama + libggml statically.
 *
 * Flow per call:
 *   1. Tokenize the prompt
 *   2. Build a batch of all prompt tokens
 *   3. llama_decode the batch (prefill)
 *   4. Sample token by token (greedy), decoding one at a time
 *   5. Stop on EOS or max_tokens
 *   6. Detokenize the response
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "local_llm.h"
#include "llama.h"

static struct llama_model   *g_model = NULL;
static struct llama_context *g_ctx   = NULL;
static struct llama_vocab   *g_vocab = NULL;
static int g_n_ctx = 2048;
static int g_ready = 0;

int local_llm_init(const char *model_path, int n_ctx, int n_threads) {
    if (!model_path) return -1;
    if (g_ready) return 0;

    fprintf(stderr, "[local_llm] loading %s (ctx=%d, threads=%d)\n",
            model_path, n_ctx, n_threads);

    /* llama.cpp requires this once per process before any model calls. */
    llama_backend_init();

    /* Default model params. mlock=0 (we're in a constrained container),
     * use mmap for the 5GB file. */
    struct llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = 0;  /* CPU only */

    g_model = llama_model_load_from_file(model_path, model_params);
    if (!g_model) {
        fprintf(stderr, "[local_llm] failed to load model: %s\n", model_path);
        llama_backend_free();
        return -1;
    }

    g_vocab = llama_model_get_vocab(g_model);
    if (!g_vocab) {
        fprintf(stderr, "[local_llm] failed to get vocab\n");
        llama_model_free(g_model);
        g_model = NULL;
        llama_backend_free();
        return -1;
    }

    g_n_ctx = n_ctx;
    struct llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx       = (uint32_t)n_ctx;
    ctx_params.n_threads   = n_threads > 0 ? n_threads : 2;
    ctx_params.n_threads_batch = ctx_params.n_threads;

    g_ctx = llama_new_context_with_model(g_model, ctx_params);
    if (!g_ctx) {
        fprintf(stderr, "[local_llm] failed to create context\n");
        llama_model_free(g_model);
        g_model = NULL;
        llama_backend_free();
        return -1;
    }

    g_ready = 1;
    fprintf(stderr, "[local_llm] ready (vocab=%d)\n", llama_vocab_n_tokens(g_vocab));
    return 0;
}

void local_llm_shutdown(void) {
    if (!g_ready) return;
    if (g_ctx)   llama_free(g_ctx);
    if (g_model) llama_model_free(g_model);
    g_ctx = NULL;
    g_model = NULL;
    g_vocab = NULL;
    g_ready = 0;
    llama_backend_free();
}

int local_llm_ready(void) {
    return g_ready;
}

/*
 * Format a Gemma-style chat prompt. Gemma 4 E4B-it uses:
 *   <start_of_turn>user
 *   {user message}<end_of_turn>
 *   <start_of_turn>model
 *   {model response}<end_of_turn>
 *
 * llama_decode's "system" role is non-standard in the C API; we
 * inline the system prompt into the user turn.
 */
static int build_gemma_prompt(char *out, size_t out_size,
                              const char *system_prompt,
                              const char *user_message) {
    int n;
    if (system_prompt && strlen(system_prompt) > 0) {
        n = snprintf(out, out_size,
            "<start_of_turn>user\n"
            "System instructions: %s\n\n"
            "User: %s<end_of_turn>\n"
            "<start_of_turn>model\n",
            system_prompt, user_message);
    } else {
        n = snprintf(out, out_size,
            "<start_of_turn>user\n"
            "%s<end_of_turn>\n"
            "<start_of_turn>model\n",
            user_message);
    }
    return (n > 0 && (size_t)n < out_size) ? 0 : -1;
}

int local_llm_infer(const char *prompt, char *response, size_t resp_size, int max_tokens) {
    if (!g_ready || !g_vocab || !g_ctx) return -1;
    if (!prompt || !response || resp_size == 0) return -1;

    response[0] = '\0';

    /* Tokenize the prompt. */
    int n_tokens_max = g_n_ctx - 1;  /* leave room for at least 1 generated token */
    int n_tokens = llama_tokenize(g_vocab, prompt, strlen(prompt),
                                  NULL, 0, /*add_special*/ 1,
                                  /*parse_special*/ 1);
    if (n_tokens < 0) {
        fprintf(stderr, "[local_llm] tokenize size probe failed: %d\n", n_tokens);
        return -1;
    }
    if (n_tokens > n_tokens_max) {
        fprintf(stderr, "[local_llm] prompt too long: %d tokens (max %d)\n",
                n_tokens, n_tokens_max);
        return -1;
    }

    /* Allocate token array and do the real tokenize. */
    llama_token *tokens = (llama_token *)malloc((size_t)n_tokens * sizeof(llama_token));
    if (!tokens) return -1;

    n_tokens = llama_tokenize(g_vocab, prompt, strlen(prompt),
                              tokens, n_tokens,
                              /*add_special*/ 1,
                              /*parse_special*/ 1);
    if (n_tokens < 0) {
        fprintf(stderr, "[local_llm] tokenize failed: %d\n", n_tokens);
        free(tokens);
        return -1;
    }

    /* Build batch: single sequence, all prompt tokens at once. */
    llama_batch batch = llama_batch_init((int32_t)n_tokens, 0, 1);
    for (int i = 0; i < n_tokens; i++) {
        batch.token[i]    = tokens[i];
        batch.pos[i]      = i;
        batch.n_seq_id[i] = 1;
        batch.seq_id[i][0] = 0;
        batch.logits[i]   = 0;  /* logits only for last token in prefill */
    }
    /* Request logits only for the last token — we sample next from there. */
    if (n_tokens > 0) {
        batch.logits[n_tokens - 1] = 1;
    }

    /* Prefill. */
    if (llama_decode(g_ctx, batch) != 0) {
        fprintf(stderr, "[local_llm] decode (prefill) failed\n");
        llama_batch_free(batch);
        free(tokens);
        return -1;
    }
    llama_batch_free(batch);

    /* Set up a greedy sampler. */
    struct llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    struct llama_sampler *smpl = llama_sampler_chain_init(sparams);
    llama_sampler_chain_add(smpl, llama_sampler_init_greedy());

    /* Token-by-token generation. */
    int n_cur = n_tokens;
    int n_gen = max_tokens > 0 ? max_tokens : 64;
    int n_resp = 0;
    char *resp_buf = (char *)malloc(resp_size);
    if (!resp_buf) {
        llama_sampler_free(smpl);
        free(tokens);
        return -1;
    }
    resp_buf[0] = '\0';

    llama_token new_token_id;
    for (int i = 0; i < n_gen; i++) {
        /* Sample next token from the last logits. */
        new_token_id = llama_sampler_sample(smpl, g_ctx, -1);

        /* Check for end-of-generation. */
        if (llama_vocab_is_eog(g_vocab, new_token_id)) {
            break;
        }

        /* Convert to text and append. */
        char piece[256];
        int n_piece = llama_token_to_piece(g_vocab, new_token_id,
                                           piece, sizeof(piece), 0, /*special*/ 0);
        if (n_piece < 0) {
            fprintf(stderr, "[local_llm] token_to_piece failed: %d\n", n_piece);
            break;
        }
        if (n_resp + n_piece + 1 < resp_size) {
            memcpy(resp_buf + n_resp, piece, (size_t)n_piece);
            n_resp += n_piece;
            resp_buf[n_resp] = '\0';
        } else {
            break;  /* response buffer full */
        }

        /* Prepare batch with just this token for next decode. */
        llama_batch next = llama_batch_init(1, 0, 1);
        next.token[0]    = new_token_id;
        next.pos[0]      = n_cur;
        next.n_seq_id[0] = 1;
        next.seq_id[0][0] = 0;
        next.logits[0]   = 1;  /* need logits for next sample */

        if (llama_decode(g_ctx, next) != 0) {
            fprintf(stderr, "[local_llm] decode (gen step %d) failed\n", i);
            llama_batch_free(next);
            break;
        }
        llama_batch_free(next);
        n_cur++;
    }

    llama_sampler_free(smpl);
    free(tokens);

    /* Copy result. */
    strncpy(response, resp_buf, resp_size - 1);
    response[resp_size - 1] = '\0';
    free(resp_buf);

    return 0;
}

/*
 * Helper exposed for ai_client: format + infer in one call.
 * Takes raw user message and the system prompt.
 */
int local_llm_query(const char *system_prompt, const char *user_message,
                    char *response, size_t resp_size, int max_tokens) {
    if (!g_ready) return -1;

    char *prompt = (char *)malloc(64 * 1024);
    if (!prompt) return -1;

    if (build_gemma_prompt(prompt, 64 * 1024, system_prompt, user_message) != 0) {
        free(prompt);
        return -1;
    }

    int rc = local_llm_infer(prompt, response, resp_size, max_tokens);
    free(prompt);
    return rc;
}
