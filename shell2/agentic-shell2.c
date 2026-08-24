/*
 * Agentic OS — shell2
 * ====================
 * A full-featured AI shell with NO llama.cpp dependency.
 * Calls llama-server on-device (127.0.0.1:8080) or host fallback in dev mode.
 *
 * Features:
 *   - Auto-detect llama-server on boot
 *   - Persistent memory (remember/recall)
 *   - Notes, alarms, weather, web search
 *   - Interaction logger (learning foundation)
 *   - User profile (personalization)
 *   - Content certificates (ownership proof)
 *   - File sharing integration
 *   - Tool dispatch from AI responses
 *   - RAG: inject relevant memories into every prompt
 *   - Browser automation (CSS-selector based clicks, form fill, screenshots)
 *   - Workflow runner (multi-step automations)
 *   - Credential storage (secure, encrypted)
 *   - Extensible: create_tool for custom shell scripts
 *
 * Build:
 *   aarch64-linux-gnu-gcc -static -O2 -o agentic-shell2 agentic-shell2.c
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/reboot.h>
#include <netinet/in.h>
#include <arpa/inet.h>

/* ── Config ───────────────────────────────────────────────────────────────── */

#define AGENTIC_DIR     "/usr/share/agentic"
#define MEMORY_FILE     AGENTIC_DIR "/memory.txt"
#define NOTES_FILE      AGENTIC_DIR "/notes.txt"
#define PROFILE_FILE    AGENTIC_DIR "/profile.json"
#define LEARN_DIR       AGENTIC_DIR "/learning"
#define LEARN_FILE      LEARN_DIR "/interactions.jsonl"
#define CERTS_FILE      AGENTIC_DIR "/certs/content.jsonl"
#define CONTEXT_FILE    "/tmp/agentic_context.txt"

/* AI engine: always tries localhost first (on-device llama-server).
   Falls back to host Mac (10.0.2.2) only if local is unreachable.
   Set LLAMA_HOST env var to override at runtime. */
#define LLM_HOST_LOCAL  "127.0.0.1"   /* on-device llama-server */
#define LLM_HOST_HOST   "10.0.2.2"    /* host Mac fallback (QEMU testing only) */
#define LLM_PORT        8080
#define LLM_PATH        "/v1/chat/completions"
#define LLM_TIMEOUT_SEC 300

#define SEARX_HOST      "127.0.0.1"   /* on-device SearXNG metasearch daemon */
#define SEARX_PORT      8888

#define MAX_INPUT       4096
#define MAX_RESPONSE    16384
#define MAX_MEMORY      8192
#define MAX_PROMPT      32768
#define MAX_CONTEXT     20     /* conversation turns to keep */

/* ── Globals ──────────────────────────────────────────────────────────────── */

static int  g_llm_available  = 0;
static char g_llm_host[64]   = LLM_HOST_LOCAL; /* resolved at startup */
static int  g_llm_local      = 0;              /* 1 = on-device, 0 = host fallback */
static char g_username[64]   = "user";
static char g_model[128]     = "qwen2.5";
static int  g_turn           = 0;

/* Conversation history for multi-turn */
typedef struct { char role[16]; char text[MAX_INPUT]; } Turn;
static Turn g_history[MAX_CONTEXT];
static int  g_history_len = 0;

/* ── Utilities ────────────────────────────────────────────────────────────── */

static void ensure_dirs(void) {
    mkdir(AGENTIC_DIR, 0755);
    mkdir(AGENTIC_DIR "/learning", 0755);
    mkdir(AGENTIC_DIR "/certs",    0755);
    mkdir(AGENTIC_DIR "/tools",    0755);
}

static long file_size(const char *path) {
    struct stat st;
    return (stat(path, &st) == 0) ? (long)st.st_size : 0;
}

/* Read first n bytes of a file into buf (null-terminated). Returns bytes read. */
static int file_read(const char *path, char *buf, int maxlen) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) { buf[0] = '\0'; return 0; }
    int n = read(fd, buf, maxlen - 1);
    close(fd);
    if (n < 0) n = 0;
    buf[n] = '\0';
    return n;
}

/* Append text to a file. */
static void file_append(const char *path, const char *text) {
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) { write(fd, text, strlen(text)); close(fd); }
}

/* Overwrite a file with text. */
static void file_write(const char *path, const char *text) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) { write(fd, text, strlen(text)); close(fd); }
}

/* Simple JSON string escape (writes into buf, returns buf). */
static char *json_esc(const char *s, char *buf, int buflen) {
    int i = 0, j = 0;
    while (s[i] && j < buflen - 4) {
        if      (s[i] == '"')  { buf[j++] = '\\'; buf[j++] = '"'; }
        else if (s[i] == '\\') { buf[j++] = '\\'; buf[j++] = '\\'; }
        else if (s[i] == '\n') { buf[j++] = '\\'; buf[j++] = 'n'; }
        else if (s[i] == '\r') { buf[j++] = '\\'; buf[j++] = 'r'; }
        else if (s[i] == '\t') { buf[j++] = '\\'; buf[j++] = 't'; }
        else buf[j++] = s[i];
        i++;
    }
    buf[j] = '\0';
    return buf;
}

/* Extract a JSON string value: find "key":"VALUE" and return VALUE. */
static int json_get_str(const char *json, const char *key, char *out, int outlen) {
    char needle[128];
    snprintf(needle, sizeof(needle), "\"%s\":", key);
    const char *p = strstr(json, needle);
    if (!p) return 0;
    p += strlen(needle);
    while (*p == ' ') p++;
    if (*p != '"') return 0;
    p++;
    int i = 0;
    while (*p && *p != '"' && i < outlen - 1) {
        if (*p == '\\' && *(p+1)) {
            p++;
            if      (*p == 'n') out[i++] = '\n';
            else if (*p == 't') out[i++] = '\t';
            else                out[i++] = *p;
        } else {
            out[i++] = *p;
        }
        p++;
    }
    out[i] = '\0';
    return i;
}

static long timestamp(void) { return (long)time(NULL); }

/* ── Interaction-based RAG ────────────────────────────────────────────────── */
/* Search interactions.jsonl for past Q/A pairs relevant to current query.
   Returns up to 3 relevant past exchanges as context. */
static void interaction_rag(const char *query, char *out, int outlen) {
    out[0] = '\0';
    int used = 0;

    int fd = open(LEARN_FILE, O_RDONLY);
    if (fd < 0) return;

    /* Load last 50KB of interaction log */
    char *buf = malloc(51200);
    if (!buf) { close(fd); return; }
    int n = read(fd, buf, 51200 - 1);
    close(fd);
    if (n <= 0) { free(buf); return; }
    buf[n] = '\0';

    /* Split query into words */
    char qcopy[MAX_INPUT];
    strncpy(qcopy, query, sizeof(qcopy) - 1);
    char *words[32]; int nwords = 0;
    char *tok = strtok(qcopy, " \t\n");
    while (tok && nwords < 32) {
        if (strlen(tok) > 3) words[nwords++] = tok;
        tok = strtok(NULL, " \t\n");
    }
    if (nwords == 0) { free(buf); return; }

    /* Score each line */
    typedef struct { int score; char q[256]; char r[256]; } Match;
    Match matches[8]; int nm = 0;

    char *line = strtok(buf, "\n");
    while (line && nm < 8) {
        char q[256] = {0}, r[256] = {0};
        json_get_str(line, "q", q, sizeof(q));
        json_get_str(line, "r", r, sizeof(r));
        if (!q[0]) { line = strtok(NULL, "\n"); continue; }

        char lower[512]; int i;
        for (i = 0; q[i] && i < 511; i++) lower[i] = q[i] | 0x20;
        lower[i] = '\0';

        int score = 0;
        for (int w = 0; w < nwords; w++) {
            char wl[64]; int j;
            for (j = 0; words[w][j] && j < 63; j++) wl[j] = words[w][j] | 0x20;
            wl[j] = '\0';
            if (strstr(lower, wl)) score++;
        }
        if (score >= 2) {
            matches[nm].score = score;
            strncpy(matches[nm].q, q, 255);
            strncpy(matches[nm].r, r, 255);
            nm++;
        }
        line = strtok(NULL, "\n");
    }
    free(buf);

    /* Sort by score (bubble) */
    for (int i = 0; i < nm - 1; i++)
        for (int j = i+1; j < nm; j++)
            if (matches[j].score > matches[i].score) {
                Match tmp = matches[i]; matches[i] = matches[j]; matches[j] = tmp;
            }

    /* Output top 3 */
    int shown = 0;
    for (int i = 0; i < nm && shown < 3 && used < outlen - 256; i++) {
        int w = snprintf(out + used, outlen - used,
            "Past: Q: %.120s → A: %.120s\n", matches[i].q, matches[i].r);
        used += w; shown++;
    }
}

/* ── Profile loader ───────────────────────────────────────────────────────── */
/* Loads city, language, preferences from profile.json and facts */
static void profile_context(char *out, int outlen) {
    out[0] = '\0';
    int used = 0;

    char pbuf[1024];
    if (file_read(PROFILE_FILE, pbuf, sizeof(pbuf)) > 0) {
        char city[64] = {0}, lang[64] = {0};
        json_get_str(pbuf, "city",     city, sizeof(city));
        json_get_str(pbuf, "language", lang, sizeof(lang));
        if (city[0]) used += snprintf(out+used, outlen-used, "User city: %s\n", city);
        if (lang[0] && strcmp(lang, "en") != 0)
            used += snprintf(out+used, outlen-used, "Preferred language mix: %s\n", lang);
    }

    /* Load extracted facts */
    char fbuf[2048];
    if (file_read(LEARN_DIR "/extracted_facts.txt", fbuf, sizeof(fbuf)) > 0) {
        char *line = strtok(fbuf, "\n");
        while (line && used < outlen - 64) {
            if (strncmp(line, "peak_hour_", 10) != 0) /* skip noise */
                used += snprintf(out+used, outlen-used, "%s\n", line);
            line = strtok(NULL, "\n");
        }
    }
}

/* ── Memory / Notes / Profile ─────────────────────────────────────────────── */

/* memory.txt format: KEY=VALUE\n */
static void memory_set(const char *key, const char *value) {
    /* Read existing, remove old entry for this key, append new */
    char buf[MAX_MEMORY];
    file_read(MEMORY_FILE, buf, sizeof(buf));

    char newbuf[MAX_MEMORY + 256];
    int  out = 0;
    char *line = strtok(buf, "\n");
    int   keylen = strlen(key);
    while (line) {
        if (strncmp(line, key, keylen) != 0 || line[keylen] != '=') {
            int n = strlen(line);
            if (out + n + 2 < (int)sizeof(newbuf)) {
                memcpy(newbuf + out, line, n);
                out += n;
                newbuf[out++] = '\n';
            }
        }
        line = strtok(NULL, "\n");
    }
    /* Append new */
    int n = snprintf(newbuf + out, sizeof(newbuf) - out, "%s=%s\n", key, value);
    out += n;
    newbuf[out] = '\0';
    file_write(MEMORY_FILE, newbuf);
    printf("[memory] saved: %s = %s\n", key, value);
}

static int memory_get(const char *key, char *out, int outlen) {
    char buf[MAX_MEMORY];
    file_read(MEMORY_FILE, buf, sizeof(buf));
    int keylen = strlen(key);
    char *line = strtok(buf, "\n");
    while (line) {
        if (strncmp(line, key, keylen) == 0 && line[keylen] == '=') {
            strncpy(out, line + keylen + 1, outlen - 1);
            out[outlen - 1] = '\0';
            return 1;
        }
        line = strtok(NULL, "\n");
    }
    return 0;
}

/* Load relevant memories for RAG: return lines containing any word from query */
static void memory_rag(const char *query, char *out, int outlen) {
    char buf[MAX_MEMORY];
    file_read(MEMORY_FILE, buf, sizeof(buf));
    out[0] = '\0';
    int used = 0;

    /* Split query into words */
    char qcopy[MAX_INPUT];
    strncpy(qcopy, query, sizeof(qcopy) - 1);
    char *words[32]; int nwords = 0;
    char *tok = strtok(qcopy, " \t\n");
    while (tok && nwords < 32) { words[nwords++] = tok; tok = strtok(NULL, " \t\n"); }

    char bcopy[MAX_MEMORY];
    strncpy(bcopy, buf, sizeof(bcopy) - 1);
    char *line = strtok(bcopy, "\n");
    while (line && used < outlen - 128) {
        char lower[512];
        int i;
        for (i = 0; line[i] && i < 511; i++) lower[i] = line[i] | 0x20;
        lower[i] = '\0';
        for (int w = 0; w < nwords; w++) {
            if (strlen(words[w]) > 2 && strstr(lower, words[w])) {
                int n = snprintf(out + used, outlen - used, "- %s\n", line);
                used += n;
                break;
            }
        }
        line = strtok(NULL, "\n");
    }
}

static void note_add(const char *text) {
    char entry[MAX_INPUT + 64];
    snprintf(entry, sizeof(entry), "[%ld] %s\n", timestamp(), text);
    file_append(NOTES_FILE, entry);
    printf("[notes] saved.\n");
}

static void notes_list(void) {
    char buf[MAX_MEMORY];
    int n = file_read(NOTES_FILE, buf, sizeof(buf));
    if (n == 0) { printf("(no notes)\n"); return; }
    printf("--- Notes ---\n%s\n", buf);
}

/* Load or create profile */
static void profile_load(void) {
    char buf[1024];
    if (file_read(PROFILE_FILE, buf, sizeof(buf)) > 0) {
        json_get_str(buf, "name", g_username, sizeof(g_username));
    }
}

static void profile_set_name(const char *name) {
    strncpy(g_username, name, sizeof(g_username) - 1);
    char json[512];
    snprintf(json, sizeof(json), "{\"name\":\"%s\",\"updated\":%ld}\n", name, timestamp());
    file_write(PROFILE_FILE, json);
    printf("Nice to meet you, %s.\n", name);
}

/* ── Interaction Logger (Learning Foundation) ─────────────────────────────── */

static void log_interaction(const char *query, const char *response, int accepted) {
    char qe[MAX_INPUT * 2], re[MAX_RESPONSE * 2];
    char entry[MAX_INPUT + MAX_RESPONSE + 256];
    snprintf(entry, sizeof(entry),
        "{\"ts\":%ld,\"q\":\"%s\",\"r\":\"%s\",\"ok\":%d}\n",
        timestamp(),
        json_esc(query,    qe, sizeof(qe)),
        json_esc(response, re, sizeof(re)),
        accepted);
    file_append(LEARN_FILE, entry);
}

/* ── Content Certificates ─────────────────────────────────────────────────── */

/* Simple content fingerprint: sha256 via sha256sum subprocess */
static int cert_create(const char *filepath, char *cid_out, int cid_len) {
    char cmd[MAX_INPUT + 32];
    snprintf(cmd, sizeof(cmd), "sha256sum '%s' 2>/dev/null", filepath);
    FILE *f = popen(cmd, "r");
    if (!f) return 0;
    char result[128] = {0};
    fgets(result, sizeof(result), f);
    pclose(f);
    if (strlen(result) < 64) return 0;
    strncpy(cid_out, result, 64);
    cid_out[64] = '\0';

    /* Write certificate record */
    char node_id[32] = "unknown";
    char idbuf[64];
    file_read(AGENTIC_DIR "/identity/node.id", idbuf, sizeof(idbuf));
    if (strlen(idbuf) > 0) {
        strncpy(node_id, idbuf, sizeof(node_id) - 1);
        /* strip newline */
        node_id[strcspn(node_id, "\n")] = '\0';
    }

    char cert[512];
    char fesc[MAX_INPUT];
    snprintf(cert, sizeof(cert),
        "{\"cid\":\"%s\",\"file\":\"%s\",\"creator\":\"%s\",\"created\":%ld}\n",
        cid_out,
        json_esc(filepath, fesc, sizeof(fesc)),
        node_id,
        timestamp());
    file_append(CERTS_FILE, cert);

    snprintf(cid_out, cid_len, "sha256:%s", result);
    cid_out[strcspn(cid_out, " \n")] = '\0';
    return 1;
}

/* ── HTTP Client for llama-server ─────────────────────────────────────────── */

static int http_post(const char *host, int port, const char *path,
                     const char *body, char *resp_buf, int resp_len) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return -1;

    struct timeval tv = { .tv_sec = LLM_TIMEOUT_SEC, .tv_usec = 0 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr = {0};
    addr.sin_family      = AF_INET;
    addr.sin_port        = htons(port);
    addr.sin_addr.s_addr = inet_addr(host);

    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(sock);
        return -1;
    }

    int body_len = strlen(body);
    char req[MAX_PROMPT + 512];
    int req_len = snprintf(req, sizeof(req),
        "POST %s HTTP/1.1\r\n"
        "Host: %s:%d\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n"
        "\r\n"
        "%s",
        path, host, port, body_len, body);

    if (write(sock, req, req_len) < 0) { close(sock); return -1; }

    /* Read full response */
    int total = 0;
    char chunk[4096];
    int n;
    while ((n = read(sock, chunk, sizeof(chunk))) > 0 && total < resp_len - 1) {
        int copy = (n < resp_len - 1 - total) ? n : resp_len - 1 - total;
        memcpy(resp_buf + total, chunk, copy);
        total += copy;
    }
    resp_buf[total] = '\0';
    close(sock);
    return total;
}

/* Minimal raw-socket HTTP GET (plaintext, local services only — no TLS).
   Used for the on-device SearXNG metasearch daemon on 127.0.0.1:8888. */
static int http_get(const char *host, int port, const char *path,
                    char *resp_buf, int resp_len) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return -1;

    /* Generous read timeout: a SearXNG metasearch query fans out to several
       engines (Google/Bing/Brave) over QEMU NAT and the first query is slow. */
    struct timeval tv = { .tv_sec = 25, .tv_usec = 0 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr = {0};
    addr.sin_family      = AF_INET;
    addr.sin_port        = htons(port);
    addr.sin_addr.s_addr = inet_addr(host);

    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(sock);
        return -1;
    }

    char req[1024];
    int req_len = snprintf(req, sizeof(req),
        "GET %s HTTP/1.1\r\n"
        "Host: %s:%d\r\n"
        "User-Agent: AgenticOS/1.0\r\n"
        "Accept: application/json\r\n"
        "Connection: close\r\n"
        "\r\n",
        path, host, port);
    if (write(sock, req, req_len) < 0) { close(sock); return -1; }

    int total = 0, n;
    char chunk[4096];
    while ((n = read(sock, chunk, sizeof(chunk))) > 0 && total < resp_len - 1) {
        int copy = (n < resp_len - 1 - total) ? n : resp_len - 1 - total;
        memcpy(resp_buf + total, chunk, copy);
        total += copy;
    }
    resp_buf[total] = '\0';
    close(sock);
    return total;
}

/* Probe one host:port, return 1 if llama-server responds */
static int llm_probe(const char *host) {
    char resp[512];
    char req[256];
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return 0;
    struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    struct sockaddr_in addr = {0};
    addr.sin_family      = AF_INET;
    addr.sin_port        = htons(LLM_PORT);
    addr.sin_addr.s_addr = inet_addr(host);
    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(sock); return 0;
    }
    snprintf(req, sizeof(req),
        "GET /health HTTP/1.1\r\nHost: %s:%d\r\nConnection: close\r\n\r\n",
        host, LLM_PORT);
    write(sock, req, strlen(req));
    int n = read(sock, resp, sizeof(resp) - 1);
    close(sock);
    if (n <= 0) return 0;
    resp[n] = '\0';
    return (strstr(resp, "200") || strstr(resp, "ok") || strstr(resp, "OK")) ? 1 : 0;
}

/* Try on-device first, fall back to host Mac for QEMU testing */
static int llm_check(void) {
    /* Check environment override */
    const char *env_host = getenv("LLAMA_HOST");
    if (env_host && env_host[0]) {
        strncpy(g_llm_host, env_host, sizeof(g_llm_host)-1);
        return llm_probe(g_llm_host);
    }
    /* 1. Try on-device (self-sufficient mode) */
    if (llm_probe(LLM_HOST_LOCAL)) {
        strncpy(g_llm_host, LLM_HOST_LOCAL, sizeof(g_llm_host)-1);
        g_llm_local = 1;
        return 1;
    }
    /* 2. Fall back to host Mac (QEMU dev mode only) */
    if (llm_probe(LLM_HOST_HOST)) {
        strncpy(g_llm_host, LLM_HOST_HOST, sizeof(g_llm_host)-1);
        g_llm_local = 0;
        return 1;
    }
    return 0;
}

/* ── Build LLM prompt ─────────────────────────────────────────────────────── */

static void build_prompt(const char *query, char *prompt_out, int prompt_len) {
    /* 1. Load relevant key=value memories */
    char memories[2048] = {0};
    memory_rag(query, memories, sizeof(memories));

    /* 2. Load relevant past interactions (interaction RAG) */
    char past_interactions[2048] = {0};
    interaction_rag(query, past_interactions, sizeof(past_interactions));

    /* 3. Load user profile context */
    char prof_ctx[1024] = {0};
    profile_context(prof_ctx, sizeof(prof_ctx));

    /* 4. Load recent notes (last 400 chars) */
    char notes_snippet[512] = {0};
    char notes_buf[MAX_MEMORY];
    int nlen = file_read(NOTES_FILE, notes_buf, sizeof(notes_buf));
    if (nlen > 0) {
        int start = nlen > 400 ? nlen - 400 : 0;
        strncpy(notes_snippet, notes_buf + start, sizeof(notes_snippet) - 1);
    }

    /* 5. Build system prompt */
    char sysprompt[MAX_PROMPT / 2];
    int sp = snprintf(sysprompt, sizeof(sysprompt),
        "You are Agentic OS — an intelligent operating system shell. "
        "The user's name is %s. You help them accomplish real tasks on the user's device "
        "by running commands and tools. Be concise and direct.\n\n"
        "Output ONLY ONE of these (never mix in the same response):\n"
        "- A shell command on its own line: CMD:<exact command>\n"
        "- A tool call on its own line: TOOL:<name> key1=val1 key2=val2\n"
        "- Plain text answer or status for the user.\n\n"
        "Available tools (use exactly this format):\n"
        "TOOL:remember key=<name> value=<fact>\n"
        "TOOL:recall key=<name>\n"
        "TOOL:note text=<text>\n"
        "TOOL:notes\n"
        "TOOL:weather city=<city>\n"
        "TOOL:search query=<query>           # web search via on-device SearXNG (Google/Bing/Brave)\n"
        "TOOL:web_read url=<url>             # fetch a result page and read its text\n"
        "TOOL:open_app name=<app-name>\n"
        "TOOL:certify file=<path>\n"
        "TOOL:whoami\n"
        "TOOL:create_tool name=<name> desc=<desc> script=<full sh script here>\n"
        "TOOL:browser_open url=<url>          # open a page or web app for reading\n"
        "TOOL:browser_click selector=<css>    # click an element (CSS selector)\n"
        "TOOL:browser_type selector=<css> text=<text>  # fill an input field\n"
        "  text can also be credential=<name> to pull from secure storage\n"
        "TOOL:browser_wait selector=<css> [timeout=10]  # wait for element\n"
        "TOOL:browser_find <text>             # find elements containing text (returns selectors)\n"
        "TOOL:browser_keyinfo selector=<css>  # get label/placeholder for an input\n"
        "TOOL:browser_screenshot [path]       # capture page as PNG\n"
        "TOOL:browser_eval <javascript>       # run JS in page, get result\n"
        "TOOL:browser_scroll <direction>      # scroll page (up/down/left/right)\n"
        "TOOL:browser_ctl cmd=...             # direct CDP access for advanced use\n"
        "TOOL:workflow_run name=<name>        # run a saved multi-step workflow\n"
        "TOOL:workflow_list [scope]           # list workflows (all/private/public/team)\n"
        "TOOL:workflow_create name=<name> json=<json-steps>  # save a new workflow\n"
        "TOOL:credential_save name=<name> value=<value>  # store a credential\n"
        "TOOL:credential_get name=<name>      # retrieve a credential value\n"
        "TOOL:credential_list                # list stored credential names\n\n"
        "After you output CMD: or TOOL: lines I will execute them and give you back an "
        "OBSERVATION with the result (stdout, status, any error). Use the observation to "
        "decide the next action or to report to the user. You can chain multiple steps "
        "for web flows (open a site, then post, then confirm). Keep actions safe and "
        "ask for confirmation on anything destructive or that posts publicly.\n\n"
        "The create_tool lets you invent new tools on the fly (script= is the full body).\n\n"
        "Credential handling: when a workflow step has credential=<name>, the system resolves it\n"
        "from secure storage before executing. Never output credential values — reference them\n"
        "by name only. The user controls what gets stored.\n\n",
        g_username);

    if (prof_ctx[0])
        sp += snprintf(sysprompt + sp, sizeof(sysprompt) - sp,
            "User profile:\n%s\n", prof_ctx);

    if (memories[0])
        sp += snprintf(sysprompt + sp, sizeof(sysprompt) - sp,
            "Stored memories:\n%s\n", memories);

    if (past_interactions[0])
        sp += snprintf(sysprompt + sp, sizeof(sysprompt) - sp,
            "Relevant past conversations:\n%s\n", past_interactions);

    if (notes_snippet[0])
        sp += snprintf(sysprompt + sp, sizeof(sysprompt) - sp,
            "Recent notes:\n%s\n\n", notes_snippet);

    /* 4. Build conversation history as JSON messages array */
    char history_json[MAX_PROMPT / 2];
    int hj = 0;
    char esc[MAX_INPUT * 2];

    hj += snprintf(history_json + hj, sizeof(history_json) - hj,
        "{\"role\":\"system\",\"content\":\"%s\"}",
        json_esc(sysprompt, esc, sizeof(esc)));

    for (int i = 0; i < g_history_len; i++) {
        hj += snprintf(history_json + hj, sizeof(history_json) - hj,
            ",{\"role\":\"%s\",\"content\":\"%s\"}",
            g_history[i].role,
            json_esc(g_history[i].text, esc, sizeof(esc)));
    }

    hj += snprintf(history_json + hj, sizeof(history_json) - hj,
        ",{\"role\":\"user\",\"content\":\"%s\"}",
        json_esc(query, esc, sizeof(esc)));

    /* 5. Assemble full JSON request body */
    snprintf(prompt_out, prompt_len,
        "{\"model\":\"%s\","
        "\"messages\":[%s],"
        "\"temperature\":0.7,"
        "\"max_tokens\":128,"
        "\"stream\":false}",
        g_model, history_json);
}

/* ── Call LLM ─────────────────────────────────────────────────────────────── */

static int llm_query(const char *query, char *out, int outlen) {
    if (!g_llm_available) {
        snprintf(out, outlen,
            "AI engine offline. To start on-device:\n"
            "  llama-server -m /usr/share/agentic/models/Qwen*.gguf "
            "--host 127.0.0.1 --port 8080 -ngl 0");
        return 0;
    }

    char prompt[MAX_PROMPT];
    build_prompt(query, prompt, sizeof(prompt));

    char *raw = malloc(MAX_RESPONSE);
    if (!raw) { snprintf(out, outlen, "out of memory"); return 0; }

    printf("  [thinking...]\r");
    fflush(stdout);

    int n = http_post(g_llm_host, LLM_PORT, LLM_PATH, prompt, raw, MAX_RESPONSE);
    if (n <= 0) {
        free(raw);
        g_llm_available = 0;
        snprintf(out, outlen, "LLM connection lost. Check llama-server.");
        return 0;
    }

    /* Find HTTP body (after \r\n\r\n) */
    char *body = strstr(raw, "\r\n\r\n");
    if (!body) body = raw;
    else body += 4;

    /* Extract content from: {"choices":[{"message":{"content":"..."}}]} */
    int got = json_get_str(body, "content", out, outlen);
    free(raw);

    if (got == 0) {
        snprintf(out, outlen, "Could not parse LLM response.");
        return 0;
    }

    /* Update conversation history */
    if (g_history_len < MAX_CONTEXT - 1) {
        strncpy(g_history[g_history_len].role, "user", 15);
        strncpy(g_history[g_history_len].text, query, MAX_INPUT - 1);
        g_history_len++;
        strncpy(g_history[g_history_len].role, "assistant", 15);
        strncpy(g_history[g_history_len].text, out, MAX_INPUT - 1);
        g_history_len++;
    } else {
        /* Shift history (drop oldest turn pair) */
        memmove(g_history, g_history + 2, (MAX_CONTEXT - 2) * sizeof(Turn));
        g_history_len = MAX_CONTEXT - 2;
        strncpy(g_history[g_history_len].role, "user", 15);
        strncpy(g_history[g_history_len].text, query, MAX_INPUT - 1);
        g_history_len++;
        strncpy(g_history[g_history_len].role, "assistant", 15);
        strncpy(g_history[g_history_len].text, out, MAX_INPUT - 1);
        g_history_len++;
    }

    return 1;
}

/* Escape a string for safe use inside single-quoted shell arguments.
   Handles embedded single quotes by breaking: 'foo'\''bar'. */
static void shell_escape(const char *in, char *out, size_t outlen) {
    size_t j = 0;
    for (size_t i = 0; in[i] && j + 4 < outlen; i++) {
        if (in[i] == '\'') {
            if (j + 4 >= outlen) break;
            out[j++] = '\''; out[j++] = '\\'; out[j++] = '\''; out[j++] = '\'';
        } else {
            if (j + 1 >= outlen) break;
            out[j++] = in[i];
        }
    }
    out[j] = '\0';
}

/* ── Tool Dispatch ────────────────────────────────────────────────────────── */

/* Run a shell command and capture its combined stdout+stderr + exit status.
   Returns the exit status. Fills outbuf with up to outlen bytes of output. */
static int run_shell_capture(const char *cmd, char *outbuf, size_t outlen) {
    if (!outbuf || outlen == 0) {
        int st = system(cmd);
        return WEXITSTATUS(st);
    }

    char fullcmd[8192];
    snprintf(fullcmd, sizeof(fullcmd), "%s 2>&1", cmd);

    FILE *p = popen(fullcmd, "r");
    if (!p) {
        snprintf(outbuf, outlen, "[failed to run command]");
        return 127;
    }

    size_t n = 0;
    char chunk[512];
    while (n + 1 < outlen && fgets(chunk, sizeof(chunk), p)) {
        size_t cl = strlen(chunk);
        if (n + cl >= outlen) cl = outlen - n - 1;
        memcpy(outbuf + n, chunk, cl);
        n += cl;
    }
    outbuf[n] = '\0';

    int status = pclose(p);
    return WEXITSTATUS(status);
}

/* Back-compat simple version (no capture) */
static int run_shell(const char *cmd) {
    int status = system(cmd);
    return WEXITSTATUS(status);
}

/* Weather via wttr.in (text format) */
static void tool_weather(const char *city, char *result, size_t reslen) {
    char cmd[512];
    char city_url[128];
    int i, j;
    for (i = j = 0; city[i] && j < 127; i++) {
        city_url[j++] = (city[i] == ' ') ? '+' : city[i];
    }
    city_url[j] = '\0';
    snprintf(cmd, sizeof(cmd),
        "wget -q -O - 'https://wttr.in/%s?format=3' 2>/dev/null || echo 'weather unavailable'",
        city_url);
    char out[1024] = {0};
    run_shell_capture(cmd, out, sizeof(out));
    if (result && reslen > 0) {
        snprintf(result, reslen, "weather: %s", out);
    } else {
        printf("%s\n", out);
    }
}

/* Percent-encode a string for safe use in a URL query component. */
static void url_encode(const char *in, char *out, size_t outlen) {
    static const char *hex = "0123456789ABCDEF";
    size_t j = 0;
    for (size_t i = 0; in[i] && j + 4 < outlen; i++) {
        unsigned char c = (unsigned char)in[i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~') {
            out[j++] = (char)c;
        } else {
            out[j++] = '%';
            out[j++] = hex[c >> 4];
            out[j++] = hex[c & 0xF];
        }
    }
    out[j] = '\0';
}

/* Extract the JSON string value for `key` at/after `from`. Tolerates whitespace
   after the colon (Python json.dumps emits `"key": "value"`). Unescapes the
   common escapes and skips \uXXXX. Returns a pointer just past the value's
   closing quote, or NULL if `key` is absent or its value is not a string. */
static const char *json_str_after(const char *from, const char *key,
                                  char *out, size_t outlen) {
    char needle[64];
    snprintf(needle, sizeof(needle), "\"%s\"", key);
    const char *p = strstr(from, needle);
    if (!p) { if (out && outlen) out[0] = '\0'; return NULL; }
    p += strlen(needle);
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    if (*p != ':') { if (out && outlen) out[0] = '\0'; return NULL; }
    p++;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    if (*p != '"') { if (out && outlen) out[0] = '\0'; return NULL; }  /* not a string (e.g. null) */
    p++;
    size_t i = 0;
    while (*p && i + 1 < outlen) {
        if (*p == '\\') {
            char e = *(p + 1);
            if      (e == 'n' || e == 't' || e == 'r') out[i++] = ' ';
            else if (e == '"')  out[i++] = '"';
            else if (e == '\\') out[i++] = '\\';
            else if (e == '/')  out[i++] = '/';
            else if (e == 'u')  { p += 6; continue; }   /* skip \uXXXX */
            else out[i++] = e;
            p += 2;
        } else if (*p == '"') {
            break;
        } else {
            out[i++] = *p++;
        }
    }
    out[i] = '\0';
    return (*p == '"') ? p + 1 : p;
}

/* Web search via the on-device SearXNG JSON API (Google/Bing/Brave aggregated),
   with a DuckDuckGo HTML scrape as a fallback when SearXNG is not running. */
static void tool_search(const char *query, char *result, size_t reslen) {
    char qenc[512];
    url_encode(query, qenc, sizeof(qenc));

    char path[640];
    snprintf(path, sizeof(path), "/search?q=%s&format=json", qenc);

    char formatted[2048] = {0};
    int ok = 0;

    char *resp = malloc(MAX_RESPONSE);
    if (resp) {
        int n = http_get(SEARX_HOST, SEARX_PORT, path, resp, MAX_RESPONSE);
        if (n > 0) {
            char *body = strstr(resp, "\r\n\r\n");
            body = body ? body + 4 : resp;
            const char *scan = strstr(body, "\"results\":");
            if (!scan) scan = body;
            int count = 0, flen = 0;
            char title[256], url[512], content[512];
            while (count < 5) {
                const char *turl = strstr(scan, "\"url\"");
                if (!turl) break;
                json_str_after(turl, "url",     url,     sizeof(url));
                json_str_after(turl, "title",   title,   sizeof(title));
                json_str_after(turl, "content", content, sizeof(content));
                scan = turl + 5;             /* past this "url" key */
                if (!url[0]) continue;
                count++;
                flen += snprintf(formatted + flen, sizeof(formatted) - flen,
                    "%d. %s\n   %s\n   %s\n", count,
                    title[0] ? title : "(no title)", url, content);
                if ((size_t)flen >= sizeof(formatted) - 8) break;
            }
            if (count > 0) ok = 1;
        }
        free(resp);
    }

    if (!ok) {
        /* SearXNG unreachable — fall back to a direct DuckDuckGo HTML scrape. */
        char cmd[768];
        snprintf(cmd, sizeof(cmd),
            "wget -q -O - --timeout=6 'https://html.duckduckgo.com/html/?q=%s' 2>/dev/null "
            "| grep -o 'result__a[^>]*>[^<]*' | sed 's/.*>//' | head -5 || true",
            qenc);
        char out[1536] = {0};
        run_shell_capture(cmd, out, sizeof(out));
        if (out[0])
            snprintf(formatted, sizeof(formatted),
                "(on-device SearXNG offline; DuckDuckGo fallback)\n%s", out);
        else
            snprintf(formatted, sizeof(formatted),
                "search unavailable: SearXNG not reachable on %s:%d and no network "
                "fallback. Is searxng running? See /tmp/searxng.log",
                SEARX_HOST, SEARX_PORT);
    }

    if (result && reslen > 0)
        snprintf(result, reslen, "search results:\n%s", formatted);
    else
        printf("%s\n", formatted);
}

/* Strip HTML tags and <script>/<style> blocks to readable text. */
static void html_to_text(const char *html, char *out, size_t outlen) {
    size_t j = 0;
    int in_tag = 0, in_skip = 0;
    const char *p = html;
    while (*p && j + 1 < outlen) {
        if (in_skip) {
            if (*p == '<' && (strncasecmp(p, "</script", 8) == 0 ||
                              strncasecmp(p, "</style", 7) == 0)) {
                in_skip = 0;            /* fall through to tag handling */
            } else { p++; continue; }
        }
        if (*p == '<') {
            if (strncasecmp(p, "<script", 7) == 0 || strncasecmp(p, "<style", 6) == 0)
                in_skip = 1;
            if (j > 0 && out[j-1] != ' ') out[j++] = ' ';  /* tags separate words */
            in_tag = 1; p++; continue;
        }
        if (*p == '>') { in_tag = 0; p++; continue; }
        if (in_tag)    { p++; continue; }
        if (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t') {
            if (j > 0 && out[j-1] != ' ') out[j++] = ' ';
            p++; continue;
        }
        out[j++] = *p++;
    }
    while (j > 0 && out[j-1] == ' ') j--;
    out[j] = '\0';
}

/* Fetch a web page (TLS via wget), strip to text, truncate for the model. */
static void tool_web_read(const char *url, char *result, size_t reslen) {
    char fullurl[1024];
    if (strncmp(url, "http", 4) == 0)
        snprintf(fullurl, sizeof(fullurl), "%s", url);
    else
        snprintf(fullurl, sizeof(fullurl), "https://%s", url);

    char cmd[1200];
    snprintf(cmd, sizeof(cmd),
        "wget -q -O - --timeout=8 --tries=1 -U 'AgenticOS/1.0' '%s' 2>/dev/null "
        "| head -c 200000 || true",
        fullurl);

    char *raw = malloc(262144);
    if (!raw) { if (result) snprintf(result, reslen, "out of memory"); return; }
    raw[0] = '\0';
    run_shell_capture(cmd, raw, 262144);

    char *text = malloc(8192);
    if (!text) { free(raw); if (result) snprintf(result, reslen, "out of memory"); return; }
    html_to_text(raw, text, 8192);
    free(raw);

    if (strlen(text) > 3000) text[3000] = '\0';   /* keep model context small */

    if (result && reslen > 0) {
        if (text[0]) snprintf(result, reslen, "page text from %s:\n%s", fullurl, text);
        else snprintf(result, reslen, "could not read %s (empty or unreachable)", fullurl);
    } else {
        printf("%s\n", text[0] ? text : "(could not read page)");
    }
    free(text);
}

/* Share a file via agentic-shared */
static void tool_share(const char *file, const char *mode, const char *recipients) {
    char cmd[MAX_INPUT + 256];
    if (strcmp(mode, "public") == 0) {
        snprintf(cmd, sizeof(cmd), "/usr/local/bin/agentic-shared share '%s' public", file);
    } else {
        snprintf(cmd, sizeof(cmd),
            "/usr/local/bin/agentic-shared share '%s' selective '%s'", file, recipients);
    }
    run_shell(cmd);
}

/* Create content certificate */
static void tool_certify(const char *filepath) {
    char cid[256];
    if (cert_create(filepath, cid, sizeof(cid))) {
        printf("Content certified.\nCID: %s\n", cid);
        printf("Certificate saved to: %s\n", CERTS_FILE);
    } else {
        printf("Could not certify: %s\n", filepath);
    }
}

/* Parse and dispatch a TOOL: line from AI response.
   Returns 1 if a tool was dispatched. Fills result with useful output for the LLM. */
static int dispatch_tool(const char *line, char *result, size_t reslen) {
    if (strncmp(line, "TOOL:", 5) != 0) return 0;
    const char *spec = line + 5;
    if (result) result[0] = '\0';

    char out[2048] = {0};
    char fullcmd[2048];

    /* Helper: extract param value from "key=value" in spec */
    #define PARAM(key, buf, buflen) do { \
        const char *_p = strstr(spec, key "="); \
        if (_p) { \
            _p += strlen(key) + 1; \
            int _i = 0; \
            while (_p[_i] && _p[_i] != ' ' && _p[_i] != '\n' && _i < buflen-1) \
                buf[_i++] = _p[_i]; \
            buf[_i] = '\0'; \
        } else buf[0] = '\0'; \
    } while(0)

    if (strncmp(spec, "remember", 8) == 0) {
        char key[128], value[512];
        PARAM("key",   key,   sizeof(key));
        PARAM("value", value, sizeof(value));
        if (key[0]) memory_set(key, value);
        if (result) snprintf(result, reslen, "remembered %s", key);
        return 1;
    }
    if (strncmp(spec, "recall", 6) == 0) {
        char key[128], value[512];
        PARAM("key", key, sizeof(key));
        if (key[0] && memory_get(key, value, sizeof(value))) {
            if (result) snprintf(result, reslen, "%s = %s", key, value);
            else printf("[memory] %s = %s\n", key, value);
        } else {
            if (result) snprintf(result, reslen, "Nothing stored for '%s'", key);
            else printf("[memory] not found: %s\n", key);
        }
        return 1;
    }
    if (strncmp(spec, "note", 4) == 0 && spec[4] == ' ') {
        PARAM("text", (char[MAX_INPUT]){0}, MAX_INPUT);
        const char *p = strstr(spec, "text=");
        if (p) note_add(p + 5);
        if (result) snprintf(result, reslen, "note saved");
        return 1;
    }
    if (strncmp(spec, "notes", 5) == 0) {
        /* notes_list prints; for agent we could capture but for now just run */
        notes_list();
        if (result) snprintf(result, reslen, "notes listed above");
        return 1;
    }
    if (strncmp(spec, "weather", 7) == 0) {
        char city[128];
        PARAM("city", city, sizeof(city));
        for (int i = 0; city[i]; i++) if (city[i] == '_') city[i] = ' ';
        char wres[1024] = {0};
        tool_weather(city[0] ? city : "auto", wres, sizeof(wres));
        if (result) strncpy(result, wres, reslen-1);
        return 1;
    }
    if (strncmp(spec, "search", 6) == 0) {
        const char *p = strstr(spec, "query=");
        char sres[2200] = {0};
        if (p) tool_search(p + 6, sres, sizeof(sres));
        if (result) strncpy(result, sres, reslen-1);
        return 1;
    }
    if (strncmp(spec, "web_read", 8) == 0) {
        char url[1024];
        PARAM("url", url, sizeof(url));
        char rres[3300] = {0};
        if (url[0]) tool_web_read(url, rres, sizeof(rres));
        else snprintf(rres, sizeof(rres), "web_read: url= required");
        if (result) strncpy(result, rres, reslen-1);
        return 1;
    }
    if (strncmp(spec, "share", 5) == 0) {
        char file[512], mode[32], recipients[256];
        PARAM("file",       file,       sizeof(file));
        PARAM("mode",       mode,       sizeof(mode));
        PARAM("recipients", recipients, sizeof(recipients));
        if (file[0]) tool_share(file, mode[0] ? mode : "public", recipients);
        if (result) snprintf(result, reslen, "share requested for %s", file);
        return 1;
    }
    if (strncmp(spec, "certify", 7) == 0) {
        char file[512];
        PARAM("file", file, sizeof(file));
        if (file[0]) tool_certify(file);
        if (result) snprintf(result, reslen, "certify attempted for %s (see output)", file);
        return 1;
    }
    if (strncmp(spec, "whoami", 6) == 0) {
        char out[256] = {0};
        run_shell_capture("cat " AGENTIC_DIR "/identity/node.id 2>/dev/null || echo unknown", out, sizeof(out));
        if (result) snprintf(result, reslen, "Node: %s User: %s", out, g_username);
        else { printf("Node: %s\nUser: %s\n", out, g_username); }
        return 1;
    }
    /* Zero-shot tool creation */
    if (strncmp(spec, "create_tool", 11) == 0) {
        char name[64], desc[256];
        PARAM("name", name, sizeof(name));
        PARAM("desc", desc, sizeof(desc));

        if (!name[0]) { if (result) snprintf(result, reslen, "create_tool: name required"); return 1; }

        const char *script_start = strstr(spec, "script=");
        if (!script_start) { if (result) snprintf(result, reslen, "create_tool: script= required"); return 1; }
        script_start += 7;

        char tool_path[256];
        snprintf(tool_path, sizeof(tool_path), AGENTIC_DIR "/tools/%s.sh", name);

        FILE *f = fopen(tool_path, "w");
        if (!f) { if (result) snprintf(result, reslen, "could not write %s", tool_path); return 1; }
        fprintf(f, "#!/bin/sh\n# %s — %s\n# Created by Agentic OS zero-shot tool builder\n\n",
                name, desc[0] ? desc : "custom tool");
        fputs(script_start, f);
        fputs("\n", f);
        fclose(f);
        chmod(tool_path, 0755);

        char idx_path[256];
        snprintf(idx_path, sizeof(idx_path), AGENTIC_DIR "/tools/index.txt");
        FILE *idx = fopen(idx_path, "a");
        if (idx) {
            fprintf(idx, "%s|%s|%s\n", name, tool_path, desc[0] ? desc : "custom tool");
            fclose(idx);
        }

        if (result) snprintf(result, reslen, "created tool %s at %s", name, tool_path);
        return 1;
    }
    /* Open a web app shortcut */
    if (strncmp(spec, "open_app", 8) == 0) {
        char name[128];
        PARAM("name", name, sizeof(name));
        if (name[0]) {
            char name_esc[256];
            shell_escape(name, name_esc, sizeof(name_esc));
            char cmd[256];
            snprintf(cmd, sizeof(cmd), "/usr/local/bin/shortcuts.sh open '%s'", name_esc);
            char out[512] = {0};
            run_shell_capture(cmd, out, sizeof(out));
            if (result) snprintf(result, reslen, "opened app %s: %s", name_esc, out);
        }
        return 1;
    }
    /* New: browser_open for direct control / reading - prefer real graphical Chromium */
    if (strncmp(spec, "browser_open", 12) == 0) {
        char url[512];
        PARAM("url", url, sizeof(url));
        if (url[0]) {
            char url_esc[1024];
            shell_escape(url, url_esc, sizeof(url_esc));
            char cmd[1024];
            char out[1024] = {0};
            if (access("/usr/local/bin/browser-ctl", X_OK) == 0) {
                if (strncmp(url, "http", 4) != 0) snprintf(cmd, sizeof(cmd), "/usr/local/bin/browser-ctl navigate 'https://%s'", url_esc);
                else snprintf(cmd, sizeof(cmd), "/usr/local/bin/browser-ctl navigate '%s'", url_esc);
            } else {
                if (strncmp(url, "http", 4) != 0) snprintf(cmd, sizeof(cmd), "/usr/local/bin/agbrowser 'https://%s' 2>&1 || echo 'browser launch done'", url_esc);
                else snprintf(cmd, sizeof(cmd), "/usr/local/bin/agbrowser '%s' 2>&1 || echo 'browser launch done'", url_esc);
            }
            run_shell_capture(cmd, out, sizeof(out));
            if (result) snprintf(result, reslen, "browser opened %s | %s", url_esc, out);
        }
        return 1;
    }
    /* New: web_post for agentic posting (opens + provides text; full auto-post is platform-dependent) */
    if (strncmp(spec, "web_post", 8) == 0) {
        char platform[64], text[1024];
        PARAM("platform", platform, sizeof(platform));
        PARAM("text", text, sizeof(text));
        if (!platform[0]) strncpy(platform, "twitter", sizeof(platform)-1);
        if (text[0]) {
            char cmd[512];
            snprintf(cmd, sizeof(cmd), "/usr/local/bin/shortcuts.sh open '%s'", platform);
            run_shell(cmd);
            /* Also save as a note and print the exact text the agent wanted */
            char notebuf[1200];
            snprintf(notebuf, sizeof(notebuf), "DRAFT for %s: %s", platform, text);
            note_add(notebuf);
            if (result) snprintf(result, reslen, "opened %s compose. Draft saved to notes. Text: %s (complete the post in the browser or use platform API later)", platform, text);
        } else {
            if (result) snprintf(result, reslen, "web_post: text= required");
        }
        return 1;
    }

    /* Workflow runner: execute multi-step browser automations */
    if (strncmp(spec, "workflow_run", 12) == 0) {
        char name[128];
        PARAM("name", name, sizeof(name));
        if (!name[0]) { if (result) snprintf(result, reslen, "workflow_run: name= required"); return 1; }
        char name_esc[256];
        shell_escape(name, name_esc, sizeof(name_esc));
        char cmd[512];
        snprintf(cmd, sizeof(cmd), "/usr/local/bin/workflows.sh run '%s'", name_esc);
        int st = run_shell_capture(cmd, out, sizeof(out));
        if (result) snprintf(result, reslen, "workflow %s -> %d\n%.500s", name_esc, st, out);
        return 1;
    }
    if (strncmp(spec, "workflow_list", 12) == 0) {
        char scope[64] = "all";
        PARAM("scope", scope, sizeof(scope));
        char scope_esc[128];
        shell_escape(scope, scope_esc, sizeof(scope_esc));
        char cmd[256];
        snprintf(cmd, sizeof(cmd), "/usr/local/bin/workflows.sh list '%s'", scope_esc);
        run_shell_capture(cmd, out, sizeof(out));
        if (result) snprintf(result, reslen, "%s", out);
        return 1;
    }
    if (strncmp(spec, "workflow_create", 15) == 0) {
        char name[128], scope[64] = "private";
        char json[4096] = {0};
        PARAM("name", name, sizeof(name));
        PARAM("scope", scope, sizeof(scope));
        const char *js = strstr(spec, "json=");
        if (js) {
            js += 5;
            int i = 0;
            while (js[i] && js[i] != '\n' && i < sizeof(json)-1)
                json[i++] = js[i];
            json[i] = '\0';
        }
        if (!name[0] || !json[0]) { if (result) snprintf(result, reslen, "workflow_create: name= and json= required"); return 1; }
        char name_esc[256], scope_esc[128], json_esc[4096];
        shell_escape(name, name_esc, sizeof(name_esc));
        shell_escape(scope, scope_esc, sizeof(scope_esc));
        shell_escape(json, json_esc, sizeof(json_esc));
        char cmd[12288];
        snprintf(cmd, sizeof(cmd), "echo '%s' | /usr/local/bin/workflows.sh create '%s' '%s'", json_esc, name_esc, scope_esc);
        int st = run_shell_capture(cmd, out, sizeof(out));
        if (result) snprintf(result, reslen, "workflow_create %s -> %d: %.500s", name_esc, st, out);
        return 1;
    }

    /* New browser automation tools — element-based, not coordinate-based */
    if (strncmp(spec, "browser_click", 13) == 0) {
        char selector[256];
        PARAM("selector", selector, sizeof(selector));
        if (!selector[0]) { if (result) snprintf(result, reslen, "browser_click: selector= required"); return 1; }
        char sel_esc[512];
        shell_escape(selector, sel_esc, sizeof(sel_esc));
        snprintf(fullcmd, sizeof(fullcmd), "/usr/local/bin/browser-ctl click '%s'", sel_esc);
        int st = run_shell_capture(fullcmd, out, sizeof(out));
        if (result) snprintf(result, reslen, "browser_click %s -> %d : %.500s", sel_esc, st, out);
        return 1;
    }
    if (strncmp(spec, "browser_type", 12) == 0) {
        char selector[256], text[1024];
        PARAM("selector", selector, sizeof(selector));
        PARAM("text", text, sizeof(text));
        PARAM("value", text, sizeof(text));  /* alias */
        if (!selector[0] || !text[0]) { if (result) snprintf(result, reslen, "browser_type: selector= and text= required"); return 1; }
        char sel_esc[512], txt_esc[2048];
        shell_escape(selector, sel_esc, sizeof(sel_esc));
        shell_escape(text, txt_esc, sizeof(txt_esc));
        /* Check if text references a credential */
        if (strncmp(text, "credential:", 11) == 0) {
            char cred_name[128];
            snprintf(cred_name, sizeof(cred_name), "/usr/local/bin/credentials.sh get '%s'", text + 11);
            char cred_val[1024] = {0};
            run_shell_capture(cred_name, cred_val, sizeof(cred_val));
            if (cred_val[0]) snprintf(fullcmd, sizeof(fullcmd), "/usr/local/bin/browser-ctl type '%s' '%s'", sel_esc, cred_val);
            else snprintf(fullcmd, sizeof(fullcmd), "/usr/local/bin/browser-ctl type '%s' '%s'", sel_esc, txt_esc);
        } else {
            snprintf(fullcmd, sizeof(fullcmd), "/usr/local/bin/browser-ctl type '%s' '%s'", sel_esc, txt_esc);
        }
        int st = run_shell_capture(fullcmd, out, sizeof(out));
        if (result) snprintf(result, reslen, "browser_type %s -> %d : %.500s", sel_esc, st, out);
        return 1;
    }
    if (strncmp(spec, "browser_wait", 12) == 0) {
        char selector[256], timeout_str[16] = "10";
        PARAM("selector", selector, sizeof(selector));
        PARAM("timeout", timeout_str, sizeof(timeout_str));
        if (!selector[0]) { if (result) snprintf(result, reslen, "browser_wait: selector= required"); return 1; }
        char sel_esc[512], to_esc[32];
        shell_escape(selector, sel_esc, sizeof(sel_esc));
        shell_escape(timeout_str, to_esc, sizeof(to_esc));
        snprintf(fullcmd, sizeof(fullcmd), "/usr/local/bin/browser-ctl wait '%s' '%s'", sel_esc, to_esc);
        int st = run_shell_capture(fullcmd, out, sizeof(out));
        if (result) snprintf(result, reslen, "browser_wait %s -> %d : %.500s", sel_esc, st, out);
        return 1;
    }
    if (strncmp(spec, "browser_find", 12) == 0) {
        char search_text[512];
        PARAM("text", search_text, sizeof(search_text));
        if (!search_text[0]) { if (result) snprintf(result, reslen, "browser_find: text= required"); return 1; }
        char txt_esc[1024];
        shell_escape(search_text, txt_esc, sizeof(txt_esc));
        snprintf(fullcmd, sizeof(fullcmd), "/usr/local/bin/browser-ctl find '%s'", txt_esc);
        int st = run_shell_capture(fullcmd, out, sizeof(out));
        if (result) snprintf(result, reslen, "browser_find '%s' -> %d\n%.500s", txt_esc, st, out);
        return 1;
    }
    if (strncmp(spec, "browser_keyinfo", 15) == 0) {
        char selector[256];
        PARAM("selector", selector, sizeof(selector));
        if (!selector[0]) { if (result) snprintf(result, reslen, "browser_keyinfo: selector= required"); return 1; }
        char sel_esc[512];
        shell_escape(selector, sel_esc, sizeof(sel_esc));
        snprintf(fullcmd, sizeof(fullcmd), "/usr/local/bin/browser-ctl keyinfo '%s'", sel_esc);
        int st = run_shell_capture(fullcmd, out, sizeof(out));
        if (result) snprintf(result, reslen, "browser_keyinfo %s -> %d : %.500s", sel_esc, st, out);
        return 1;
    }
    if (strncmp(spec, "browser_screenshot", 18) == 0) {
        char path[256] = "";
        PARAM("path", path, sizeof(path));
        char path_esc[512];
        shell_escape(path, path_esc, sizeof(path_esc));
        if (path[0]) snprintf(fullcmd, sizeof(fullcmd), "/usr/local/bin/browser-ctl screenshot '%s'", path_esc);
        else snprintf(fullcmd, sizeof(fullcmd), "/usr/local/bin/browser-ctl screenshot");
        int st = run_shell_capture(fullcmd, out, sizeof(out));
        if (result) snprintf(result, reslen, "browser_screenshot -> %d : %.500s", st, out);
        return 1;
    }
    if (strncmp(spec, "browser_eval", 12) == 0) {
        char js[2048];
        PARAM("js", js, sizeof(js));
        if (!js[0]) { if (result) snprintf(result, reslen, "browser_eval: js= required"); return 1; }
        char js_esc[4096];
        shell_escape(js, js_esc, sizeof(js_esc));
        snprintf(fullcmd, sizeof(fullcmd), "/usr/local/bin/browser-ctl eval '%s'", js_esc);
        int st = run_shell_capture(fullcmd, out, sizeof(out));
        if (result) snprintf(result, reslen, "browser_eval -> %d\n%.500s", st, out);
        return 1;
    }
    if (strncmp(spec, "browser_scroll", 14) == 0) {
        char direction[32] = "down";
        PARAM("direction", direction, sizeof(direction));
        char dir_esc[64];
        shell_escape(direction, dir_esc, sizeof(dir_esc));
        snprintf(fullcmd, sizeof(fullcmd), "/usr/local/bin/browser-ctl scroll '%s'", dir_esc);
        int st = run_shell_capture(fullcmd, out, sizeof(out));
        if (result) snprintf(result, reslen, "browser_scroll %s -> %d", dir_esc, st);
        return 1;
    }

    /* Credential management tools */
    if (strncmp(spec, "credential_save", 15) == 0) {
        char name[128], value[1024];
        PARAM("name", name, sizeof(name));
        PARAM("value", value, sizeof(value));
        if (!name[0] || !value[0]) { if (result) snprintf(result, reslen, "credential_save: name= and value= required"); return 1; }
        char name_esc[256], val_esc[2048];
        shell_escape(name, name_esc, sizeof(name_esc));
        shell_escape(value, val_esc, sizeof(val_esc));
        char cmd[3072];
        snprintf(cmd, sizeof(cmd), "/usr/local/bin/credentials.sh set '%s' '%s'", name_esc, val_esc);
        int st = run_shell_capture(cmd, out, sizeof(out));
        if (result) snprintf(result, reslen, "%s", out);
        return 1;
    }
    if (strncmp(spec, "credential_get", 14) == 0) {
        char name[128];
        PARAM("name", name, sizeof(name));
        if (!name[0]) { if (result) snprintf(result, reslen, "credential_get: name= required"); return 1; }
        char name_esc[256];
        shell_escape(name, name_esc, sizeof(name_esc));
        char cmd[256];
        snprintf(cmd, sizeof(cmd), "/usr/local/bin/credentials.sh get '%s'", name_esc);
        char val[1024] = {0};
        int st = run_shell_capture(cmd, val, sizeof(val));
        if (st == 0 && val[0]) {
            /* Return only a masked reference — never expose the actual value to the agent */
            if (result) snprintf(result, reslen, "credential '%s': [REDACTED %zu chars]", name_esc, strlen(val));
        } else {
            if (result) snprintf(result, reslen, "credential '%s': not found", name_esc);
        }
        return 1;
    }
    if (strncmp(spec, "credential_list", 15) == 0) {
        run_shell_capture("/usr/local/bin/credentials.sh list", out, sizeof(out));
        if (result) snprintf(result, reslen, "%s", out);
        return 1;
    }
    if (strncmp(spec, "browser_ctl", 11) == 0) {
        char cmd[64], url[512], text[1024], xstr[32], ystr[32];
        PARAM("cmd", cmd, sizeof(cmd));
        PARAM("url", url, sizeof(url));
        PARAM("text", text, sizeof(text));
        PARAM("x", xstr, sizeof(xstr));
        PARAM("y", ystr, sizeof(ystr));

        if (!cmd[0]) {
            if (result) snprintf(result, reslen, "browser_ctl: cmd=navigate|type|click|get_content|bring-to-front required");
            return 1;
        }

        char fullcmd[2048];
        if (strcmp(cmd, "navigate") == 0 || strcmp(cmd, "go") == 0) {
            if (!url[0]) { if (result) snprintf(result, reslen, "browser_ctl navigate: url= required"); return 1; }
            char url_esc[1024];
            shell_escape(url, url_esc, sizeof(url_esc));
            snprintf(fullcmd, sizeof(fullcmd), "/usr/local/bin/browser-ctl navigate '%s'", url_esc);
        } else if (strcmp(cmd, "type") == 0 || strcmp(cmd, "insert") == 0) {
            if (!text[0]) { if (result) snprintf(result, reslen, "browser_ctl type: text= required"); return 1; }
            char text_esc[2048];
            shell_escape(text, text_esc, sizeof(text_esc));
            snprintf(fullcmd, sizeof(fullcmd), "/usr/local/bin/browser-ctl type '%s'", text_esc);
        } else if (strcmp(cmd, "click") == 0) {
            if (xstr[0] && ystr[0])
                snprintf(fullcmd, sizeof(fullcmd), "/usr/local/bin/browser-ctl click %s %s", xstr, ystr);
            else
                snprintf(fullcmd, sizeof(fullcmd), "/usr/local/bin/browser-ctl click");
        } else if (strcmp(cmd, "get_content") == 0 || strcmp(cmd, "content") == 0) {
            snprintf(fullcmd, sizeof(fullcmd), "/usr/local/bin/browser-ctl get_content");
        } else if (strcmp(cmd, "bring-to-front") == 0 || strcmp(cmd, "front") == 0) {
            snprintf(fullcmd, sizeof(fullcmd), "/usr/local/bin/browser-ctl bring-to-front");
        } else {
            if (result) snprintf(result, reslen, "browser_ctl: unknown cmd %s", cmd);
            return 1;
        }

        char out[2048] = {0};
        int st = run_shell_capture(fullcmd, out, sizeof(out));
        if (result) snprintf(result, reslen, "browser-ctl %s -> %d : %s", cmd, st, out);
        return 1;
    }

    #undef PARAM
    if (result) snprintf(result, reslen, "[unknown tool in dispatch]");
    return 0;
}

/* Process AI response: dispatch tools, execute commands, print text.
   Collects observations into obs_out if provided (for auto feedback to LLM). */
static void process_response(const char *resp, char *obs_out, size_t obs_len) {
    char buf[MAX_RESPONSE];
    strncpy(buf, resp, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';

    char *line = strtok(buf, "\n");
    int action_count = 0;
    char combined_obs[2048] = {0};

    while (line) {
        /* Skip leading spaces */
        while (*line == ' ') line++;

        if (strncmp(line, "CMD:", 4) == 0) {
            const char *cmd = line + 4;
            while (*cmd == ' ') cmd++;
            printf("\n[running: %s]\n", cmd);
            char out[1024] = {0};
            int st = run_shell_capture(cmd, out, sizeof(out));
            printf("[exit %d]\n%s\n", st, out);
            if (obs_len > 0) {
                char tmp[1200];
                snprintf(tmp, sizeof(tmp), "CMD '%s' -> exit %d: %s\n", cmd, st, out);
                strncat(combined_obs, tmp, sizeof(combined_obs) - strlen(combined_obs) - 1);
            }
            action_count++;
        } else if (strncmp(line, "TOOL:", 5) == 0) {
            char tool_res[1024] = {0};
            int did = dispatch_tool(line, tool_res, sizeof(tool_res));
            if (did && tool_res[0]) {
                printf("[tool result] %s\n", tool_res);
                if (obs_len > 0) {
                    char tmp[1200];
                    snprintf(tmp, sizeof(tmp), "TOOL result: %s\n", tool_res);
                    strncat(combined_obs, tmp, sizeof(combined_obs) - strlen(combined_obs) - 1);
                }
            } else if (did) {
                /* dispatch may have printed already */
            }
            action_count++;
        } else {
            printf("%s\n", line);
        }
        line = strtok(NULL, "\n");
    }

    if (obs_out && obs_len > 0 && action_count > 0 && combined_obs[0]) {
        strncpy(obs_out, combined_obs, obs_len - 1);
        obs_out[obs_len-1] = '\0';
    }
}

/* ── Built-in commands (no LLM needed) ────────────────────────────────────── */

static int handle_builtin(const char *input) {
    /* Direct tool commands */
    if (strncmp(input, "remember ", 9) == 0) {
        const char *rest = input + 9;
        const char *eq = strchr(rest, '=');
        if (eq) {
            char key[128]; int klen = eq - rest < 127 ? eq - rest : 127;
            strncpy(key, rest, klen); key[klen] = '\0';
            memory_set(key, eq + 1);
        } else {
            printf("Usage: remember <key>=<value>\n");
        }
        return 1;
    }
    if (strncmp(input, "recall ", 7) == 0) {
        char val[512];
        if (memory_get(input + 7, val, sizeof(val)))
            printf("%s = %s\n", input + 7, val);
        else
            printf("not found: %s\n", input + 7);
        return 1;
    }
    if (strncmp(input, "note ", 5) == 0) { note_add(input + 5); return 1; }
    if (strcmp(input, "notes")    == 0)  { notes_list();         return 1; }
    if (strcmp(input, "memory")   == 0)  {
        char buf[MAX_MEMORY];
        int n = file_read(MEMORY_FILE, buf, sizeof(buf));
        printf(n > 0 ? "--- Memory ---\n%s\n" : "(no memories)\n", buf);
        return 1;
    }
    if (strncmp(input, "weather ", 8) == 0) { tool_weather(input + 8, NULL, 0); return 1; }
    if (strncmp(input, "search ",  7) == 0) { tool_search(input + 7, NULL, 0);  return 1; }
    if (strncmp(input, "read ",    5) == 0) { tool_web_read(input + 5, NULL, 0); return 1; }
    if (strncmp(input, "certify ", 8) == 0) {
        char cid[256];
        cert_create(input + 8, cid, sizeof(cid));
        printf("CID: %s\n", cid);
        return 1;
    }
    if (strncmp(input, "my name is ", 11) == 0) {
        profile_set_name(input + 11);
        return 1;
    }
    if (strncmp(input, "$ ", 2) == 0) {
        run_shell(input + 2); return 1;
    }
    if (strcmp(input, "clear history") == 0) {
        g_history_len = 0;
        printf("Conversation history cleared.\n");
        return 1;
    }
    if (strncmp(input, "certify ", 8) == 0) {
        char cmd[MAX_INPUT + 64];
        snprintf(cmd, sizeof(cmd), "/usr/local/bin/certify.sh '%s'", input + 8);
        run_shell(cmd); return 1;
    }
    if (strncmp(input, "nostr post ", 11) == 0) {
        char cmd[MAX_INPUT + 64];
        snprintf(cmd, sizeof(cmd), "/usr/local/bin/nostr-publish.sh post '%s'", input + 11);
        run_shell(cmd); return 1;
    }
    if (strncmp(input, "nostr publish ", 14) == 0) {
        char cmd[MAX_INPUT + 64];
        snprintf(cmd, sizeof(cmd), "/usr/local/bin/nostr-publish.sh publish '%s'", input + 14);
        run_shell(cmd); return 1;
    }
    if (strcmp(input, "nostr status") == 0) {
        run_shell("/usr/local/bin/nostr-publish.sh status"); return 1;
    }
    if (strcmp(input, "nostr flush") == 0) {
        run_shell("python3 /usr/local/bin/nostr-ws.py flush 2>/dev/null || "
                  "/usr/local/bin/nostr-publish.sh queue");
        return 1;
    }
    if (strcmp(input, "nostr ws status") == 0) {
        run_shell("python3 /usr/local/bin/nostr-ws.py status 2>/dev/null || "
                  "echo 'python3 not available; using HTTP fallback'");
        return 1;
    }
    /* Lightning payments */
    if (strncmp(input, "lightning ", 10) == 0) {
        char cmd[MAX_INPUT + 64];
        snprintf(cmd, sizeof(cmd), "/usr/local/bin/lnurl-pay.sh %s", input + 10);
        run_shell(cmd); return 1;
    }
    if (strcmp(input, "lightning") == 0) {
        run_shell("/usr/local/bin/lnurl-pay.sh status"); return 1;
    }
    if (strcmp(input, "learn") == 0 || strcmp(input, "!learn") == 0) {
        printf("Running learning pass...\n");
        run_shell("/usr/local/bin/learn-profile.sh"); return 1;
    }
    if (strcmp(input, "profile") == 0) {
        char buf[1024];
        int n = file_read(PROFILE_FILE, buf, sizeof(buf));
        printf(n > 0 ? "Profile:\n%s\n" : "(no profile yet)\n", buf);
        char fbuf[2048];
        n = file_read(LEARN_DIR "/extracted_facts.txt", fbuf, sizeof(fbuf));
        if (n > 0) printf("Learned facts:\n%s\n", fbuf);
        return 1;
    }
    if (strcmp(input, "status") == 0 || strcmp(input, "!status") == 0) {
        printf("LLM:     %s (%s:%d) [%s]\n",
            g_llm_available ? "ONLINE" : "OFFLINE",
            g_llm_host, LLM_PORT,
            g_llm_local ? "on-device" : "host fallback");
        printf("User:    %s\n", g_username);
        printf("Memory:  %ld bytes\n", file_size(MEMORY_FILE));
        printf("Notes:   %ld bytes\n", file_size(NOTES_FILE));
        printf("Log:     %ld bytes\n", file_size(LEARN_FILE));
        printf("History: %d turns\n", g_history_len / 2);
        return 1;
    }
    if (strcmp(input, "!reconnect") == 0) {
        printf("Checking llama-server at %s:%d...\n", g_llm_host, LLM_PORT);
        g_llm_available = llm_check();
        printf("LLM: %s\n", g_llm_available ? "ONLINE" : "OFFLINE");
        return 1;
    }
    /* Custom tools: run a user-created tool */
    if (strncmp(input, "tool ", 5) == 0) {
        const char *tname = input + 5;
        char cmd[512];
        snprintf(cmd, sizeof(cmd), AGENTIC_DIR "/tools/%s.sh", tname);
        if (access(cmd, X_OK) == 0) {
            run_shell(cmd);
        } else {
            printf("[tools] not found: %s\n", tname);
            printf("[tools] list tools with: tools\n");
        }
        return 1;
    }
    /* List all custom tools */
    if (strcmp(input, "tools") == 0) {
        char idx_path[] = AGENTIC_DIR "/tools/index.txt";
        char buf[4096];
        int n = file_read(idx_path, buf, sizeof(buf));
        if (n <= 0) {
            printf("(no custom tools yet — ask the AI to create one)\n");
        } else {
            printf("Custom tools:\n");
            /* Parse name|path|desc lines */
            char *line = strtok(buf, "\n");
            while (line) {
                char *p1 = strchr(line, '|');
                char *p2 = p1 ? strchr(p1 + 1, '|') : NULL;
                if (p1 && p2) {
                    *p1 = '\0'; *p2 = '\0';
                    printf("  %-20s  %s\n", line, p2 + 1);
                }
                line = strtok(NULL, "\n");
            }
        }
        return 1;
    }
    /* Web app shortcuts: "open <appname>" */
    if (strncmp(input, "open ", 5) == 0) {
        char cmd[256];
        snprintf(cmd, sizeof(cmd), "/usr/local/bin/shortcuts.sh open '%s'", input + 5);
        run_shell(cmd);
        return 1;
    }
    if (strcmp(input, "apps") == 0) {
        run_shell("/usr/local/bin/shortcuts.sh list");
        return 1;
    }
    /* Direct browser launch - prefer real Chromium (via ctl) in graphical mode */
    if (strcmp(input, "browser") == 0) {
        if (access("/usr/local/bin/browser-ctl", X_OK) == 0) {
            run_shell("/usr/local/bin/browser-ctl bring-to-front"); return 1;
        }
        run_shell("/usr/local/bin/agbrowser"); return 1;
    }
    if (strncmp(input, "browser ", 8) == 0) {
        const char *url = input + 8;
        char full[1024];
        if (access("/usr/local/bin/browser-ctl", X_OK) == 0) {
            if (strncmp(url, "http", 4) != 0)
                snprintf(full, sizeof(full), "/usr/local/bin/browser-ctl navigate 'https://%s'", url);
            else
                snprintf(full, sizeof(full), "/usr/local/bin/browser-ctl navigate '%s'", url);
            run_shell(full); return 1;
        }
        char cmd[MAX_INPUT + 32];
        if (strncmp(url, "http", 4) != 0) {
            snprintf(cmd, sizeof(cmd), "/usr/local/bin/agbrowser 'https://%s'", url);
        } else {
            snprintf(cmd, sizeof(cmd), "/usr/local/bin/agbrowser '%s'", url);
        }
        run_shell(cmd); return 1;
    }
    if (strncmp(input, "browse ", 7) == 0) {
        const char *url = input + 7;
        char full[1024];
        if (access("/usr/local/bin/browser-ctl", X_OK) == 0) {
            if (strncmp(url, "http", 4) != 0)
                snprintf(full, sizeof(full), "/usr/local/bin/browser-ctl navigate 'https://%s'", url);
            else
                snprintf(full, sizeof(full), "/usr/local/bin/browser-ctl navigate '%s'", url);
            run_shell(full); return 1;
        }
        char cmd[MAX_INPUT + 32];
        if (strncmp(url, "http", 4) != 0)
            snprintf(cmd, sizeof(cmd), "/usr/local/bin/agbrowser 'https://%s'", url);
        else
            snprintf(cmd, sizeof(cmd), "/usr/local/bin/agbrowser '%s'", url);
        run_shell(cmd); return 1;
    }
    if (strcmp(input, "help") == 0 || strcmp(input, "!help") == 0) {
        printf(
            "\nAgentic OS — just type what you want\n\n"
            "Direct commands:\n"
            "  remember <key>=<value>   save to memory\n"
            "  recall <key>             retrieve from memory\n"
            "  memory                   show all memory\n"
            "  note <text>              save a note\n"
            "  notes                    list all notes\n"
            "  weather <city>           get weather\n"
            "  search <query>           web search\n"
            "  certify <file>           create content certificate\n"
            "  my name is <name>        set your name\n"
            "  open <app>               open a web app (youtube, gmail, ...)\n"
            "  browser [url]            launch browser (graphical Chromium if available)\n"
            "  browse <url>             browse a URL directly\n"
            "  apps                     list all web app shortcuts\n"
            "  tools                    list custom AI-created tools\n"
            "  tool <name>              run a custom tool\n"
            "  $ <cmd>                  run shell command directly\n"
            "  clear history            reset conversation\n"
            "  status                   show system status\n"
            "  !reconnect               retry llama-server connection\n"
            "  exit / quit              exit\n\n"
            "Agentic web actions (AI can use these for flows like posting):\n"
            "  TOOL:browser_open url=...              open any URL\n"
            "  TOOL:browser_click selector=<css>      click an element\n"
            "  TOOL:browser_type selector=<css> text=<text>  fill a field\n"
            "    text=credential:<name> pulls from secure storage\n"
            "  TOOL:browser_wait selector=<css>       wait for element\n"
            "  TOOL:browser_find <text>               find elements by text\n"
            "  TOOL:browser_keyinfo selector=<css>    inspect an input field\n"
            "  TOOL:browser_screenshot [path]         capture page as PNG\n"
            "  TOOL:browser_eval <javascript>         run JS in page\n"
            "  TOOL:browser_scroll <direction>        scroll the page\n"
            "  TOOL:workflow_run name=<name>          run a saved workflow\n"
            "  TOOL:workflow_list [scope]             list workflows\n"
            "  TOOL:workflow_create name=<name> json=<steps-json>  create workflow\n"
            "  TOOL:credential_save name=<n> value=<v>  store a credential\n"
            "  TOOL:credential_get name=<n>           retrieve (redacted)\n"
            "  TOOL:credential_list                   list stored credentials\n\n"
            "Or just type naturally — the AI handles the rest.\n\n"
        );
        return 1;
    }
    if (strcmp(input, "shutdown") == 0 || strcmp(input, "poweroff") == 0) {
        printf("Shutting down...\n");
        sync();
        reboot(0x4321fedc);
        return 1;
    }
    if (strcmp(input, "reboot") == 0) {
        printf("Rebooting...\n");
        sync();
        reboot(0x01234567);
        return 1;
    }
    return 0;
}

/* ── Main Loop ────────────────────────────────────────────────────────────── */

int main(void) {
    ensure_dirs();
    profile_load();

    /* Probe llama-server — try on-device first, host Mac second */
    printf("Checking AI engine...\n");
    g_llm_available = llm_check();
    if (g_llm_available) {
        if (g_llm_local)
            printf("[AI] On-device llama-server ready at 127.0.0.1:%d\n", LLM_PORT);
        else
            printf("[AI] Host llama-server at %s:%d (dev mode)\n", g_llm_host, LLM_PORT);
    } else {
        printf("[AI] No llama-server found.\n");
        printf("     On-device: start llama-server inside this OS\n");
        printf("     Or on Mac: llama-server -m <model.gguf> --host 0.0.0.0 --port 8080\n");
        printf("     Then type '!reconnect'\n\n");
    }

    printf("\nHello%s%s. Type 'help' or just talk.\n\n",
        strlen(g_username) > 0 && strcmp(g_username, "user") != 0 ? ", " : "",
        strcmp(g_username, "user") != 0 ? g_username : "");

    char input[MAX_INPUT];
    char response[MAX_RESPONSE];

    while (1) {
        printf("> ");
        fflush(stdout);

        if (!fgets(input, sizeof(input), stdin)) {
            printf("\n");
            break;
        }

        /* Strip newline */
        int len = strlen(input);
        while (len > 0 && (input[len-1] == '\n' || input[len-1] == '\r'))
            input[--len] = '\0';
        if (len == 0) continue;

        if (strcmp(input, "exit") == 0 || strcmp(input, "quit") == 0) {
            printf("bye.\n");
            break;
        }

        /* Try built-in first */
        if (handle_builtin(input)) continue;

        /* Call LLM */
        g_turn++;
        int ok = llm_query(input, response, sizeof(response));

        if (ok) {
            printf("\n");
            char observation[2048] = {0};
            process_response(response, observation, sizeof(observation));
            printf("\n");
            log_interaction(input, response, 1);

            /* Auto-observation feedback for chaining agentic actions (browser flows etc.)
               Feed the results back to the LLM so it can continue or summarize without user input.
               Bounded to avoid runaway loops. */
            int chain_steps = 0;
            const int MAX_CHAINS = 3;
            while (observation[0] && chain_steps < MAX_CHAINS) {
                chain_steps++;
                printf("[continuing from action results...]\n");
                /* Append observation as context for next LLM turn */
                if (g_history_len < MAX_CONTEXT - 1) {
                    strncpy(g_history[g_history_len].role, "user", 15);
                    snprintf(g_history[g_history_len].text, MAX_INPUT-1,
                             "Observation after your previous CMD/TOOL actions:\n%s\nWhat should we do next or tell the user?", observation);
                    g_history_len++;
                }
                char next_resp[MAX_RESPONSE] = {0};
                /* Use a synthetic follow-up "query" so build_prompt includes the new history */
                int ok2 = llm_query("Continue the task using the observation above.", next_resp, sizeof(next_resp));
                observation[0] = '\0'; /* reset */
                if (ok2) {
                    process_response(next_resp, observation, sizeof(observation));
                    log_interaction("(auto-continue)", next_resp, 1);
                } else {
                    printf("%s\n", next_resp);
                    break;
                }
            }
            if (chain_steps >= MAX_CHAINS) {
                printf("[action chain limit reached — type anything to continue]\n");
            }
        } else {
            printf("\n%s\n\n", response);
            log_interaction(input, response, 0);
        }
    }

    return 0;
}
