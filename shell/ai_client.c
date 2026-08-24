/*
 * AI Client — routes queries to local LLM or cloud API.
 * Cloud calls use busybox wget (available in initramfs).
 * Tool calls are parsed from AI output and dispatched.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <time.h>
#include "ai_client.h"
#include "local_llm.h"

#define MEMORY_FILE "/usr/share/agentic/memory.txt"
#define CONTEXT_FILE "/tmp/agentic_context.txt"
#define MAX_MEMORY   4096
#define MAX_CONTEXT  8192

static ai_config_t g_config;
static int g_initialized = 0;

/* ── System prompt ────────────────────────────────────────────────────────── */
static const char *SYSTEM_PROMPT =
    "You are the AI shell of PryzentOS — a phone OS where you are the only interface.\n"
    "The user talks to you in plain English. You respond with ONE of:\n"
    "\n"
    "1. A shell command (single line, no explanation) — for system tasks:\n"
    "   ls -la /  |  df -h  |  free -h  |  ip addr  |  ps aux  |  uptime\n"
    "\n"
    "2. A TOOL CALL for phone-like actions (exact format required):\n"
    "   [TOOL:remember key=<key> value=<value>]   — save something to memory\n"
    "   [TOOL:recall key=<key>]                   — retrieve from memory\n"
    "   [TOOL:alarm time=<HH:MM> msg=<message>]   — set an alarm\n"
    "   [TOOL:note text=<text>]                   — save a note\n"
    "   [TOOL:notes_list]                         — show all notes\n"
    "   [TOOL:weather city=<city>]                — get weather\n"
    "   [TOOL:web_search query=<query>]           — search the web\n"
    "\n"
    "3. A plain text reply — for conversation, questions, explanations.\n"
    "\n"
    "Rules:\n"
    "- Never explain shell commands, just output them\n"
    "- Never use sudo or destructive commands (rm -rf etc.)\n"
    "- For tool calls, output ONLY the [TOOL:...] line\n"
    "- Keep replies concise\n";

/* ── Memory store ─────────────────────────────────────────────────────────── */
static void memory_set(const char *key, const char *value) {
    /* Read existing memory */
    char buf[MAX_MEMORY] = {0};
    FILE *f = fopen(MEMORY_FILE, "r");
    if (f) {
        fread(buf, 1, sizeof(buf)-1, f);
        fclose(f);
    }

    /* Build new content: skip existing key line, append updated */
    char newbuf[MAX_MEMORY*2] = {0};
    char *line = strtok(buf, "\n");
    char prefix[256];
    snprintf(prefix, sizeof(prefix), "%s=", key);
    while (line) {
        if (strncmp(line, prefix, strlen(prefix)) != 0 && line[0] != '\0')
            snprintf(newbuf + strlen(newbuf), sizeof(newbuf)-strlen(newbuf), "%s\n", line);
        line = strtok(NULL, "\n");
    }
    snprintf(newbuf + strlen(newbuf), sizeof(newbuf)-strlen(newbuf), "%s=%s\n", key, value);

    f = fopen(MEMORY_FILE, "w");
    if (f) { fputs(newbuf, f); fclose(f); }
}

static int memory_get(const char *key, char *out, size_t out_size) {
    FILE *f = fopen(MEMORY_FILE, "r");
    if (!f) return 0;
    char line[512];
    char prefix[256];
    snprintf(prefix, sizeof(prefix), "%s=", key);
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, prefix, strlen(prefix)) == 0) {
            fclose(f);
            char *val = line + strlen(prefix);
            /* strip newline */
            size_t vlen = strlen(val);
            if (vlen > 0 && val[vlen-1] == '\n') val[vlen-1] = '\0';
            strncpy(out, val, out_size-1);
            out[out_size-1] = '\0';
            return 1;
        }
    }
    fclose(f);
    return 0;
}

/* ── Context window ───────────────────────────────────────────────────────── */
static void context_append(const char *role, const char *text) {
    FILE *f = fopen(CONTEXT_FILE, "a");
    if (!f) return;
    fprintf(f, "[%s]: %s\n", role, text);
    fclose(f);
}

static void context_read(char *out, size_t out_size) {
    out[0] = '\0';
    FILE *f = fopen(CONTEXT_FILE, "r");
    if (!f) return;
    /* Read last MAX_CONTEXT bytes */
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    long offset = sz > (long)(out_size-1) ? sz - (long)(out_size-1) : 0;
    fseek(f, offset, SEEK_SET);
    fread(out, 1, out_size-1, f);
    out[out_size-1] = '\0';
    fclose(f);
}

/* ── Notes ────────────────────────────────────────────────────────────────── */
static void note_save(const char *text) {
    FILE *f = fopen("/usr/share/agentic/notes.txt", "a");
    if (!f) return;
    time_t t = time(NULL);
    char ts[32];
    struct tm *tm = localtime(&t);
    strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M", tm);
    fprintf(f, "[%s] %s\n", ts, text);
    fclose(f);
}

/* ── Tool dispatch ────────────────────────────────────────────────────────── */
/*
 * Parses [TOOL:name key=val key2=val2] from AI response.
 * Returns 1 if a tool was found and executed, fills result.
 */
static int parse_param(const char *tool_str, const char *key, char *out, size_t out_size) {
    char search[64];
    snprintf(search, sizeof(search), "%s=", key);
    const char *p = strstr(tool_str, search);
    if (!p) return 0;
    p += strlen(search);
    size_t i = 0;
    while (*p && *p != ']' && *p != ' ' && i < out_size-1) {
        /* Handle quoted values */
        if (*p == '"' || *p == '\'') {
            char q = *p++;
            while (*p && *p != q && i < out_size-1)
                out[i++] = *p++;
            if (*p) p++; /* skip closing quote */
        } else {
            out[i++] = *p++;
        }
    }
    out[i] = '\0';
    return i > 0;
}

int tool_dispatch(const char *response, char *result, size_t result_size) {
    const char *tool_start = strstr(response, "[TOOL:");
    if (!tool_start) return 0;

    char tool_name[64] = {0};
    const char *p = tool_start + 6; /* skip "[TOOL:" */
    size_t i = 0;
    while (*p && *p != ' ' && *p != ']' && i < sizeof(tool_name)-1)
        tool_name[i++] = *p++;
    tool_name[i] = '\0';

    char key[256]={0}, value[512]={0}, msg[512]={0}, city[128]={0}, query[512]={0};

    /* ── remember ── */
    if (strcmp(tool_name, "remember") == 0) {
        parse_param(tool_start, "key", key, sizeof(key));
        parse_param(tool_start, "value", value, sizeof(value));
        if (key[0] && value[0]) {
            memory_set(key, value);
            snprintf(result, result_size, "Remembered: %s = %s", key, value);
        } else {
            snprintf(result, result_size, "Error: need key= and value=");
        }
        return 1;
    }

    /* ── recall ── */
    if (strcmp(tool_name, "recall") == 0) {
        parse_param(tool_start, "key", key, sizeof(key));
        if (memory_get(key, value, sizeof(value)))
            snprintf(result, result_size, "%s = %s", key, value);
        else
            snprintf(result, result_size, "Nothing stored for '%s'", key);
        return 1;
    }

    /* ── note ── */
    if (strcmp(tool_name, "note") == 0) {
        parse_param(tool_start, "text", value, sizeof(value));
        if (value[0]) {
            note_save(value);
            snprintf(result, result_size, "Note saved.");
        } else {
            snprintf(result, result_size, "Error: need text=");
        }
        return 1;
    }

    /* ── notes_list ── */
    if (strcmp(tool_name, "notes_list") == 0) {
        FILE *f = fopen("/usr/share/agentic/notes.txt", "r");
        if (!f) { snprintf(result, result_size, "No notes yet."); return 1; }
        result[0] = '\0';
        char line[256];
        while (fgets(line, sizeof(line), f) && strlen(result) < result_size-256)
            strncat(result, line, result_size - strlen(result) - 1);
        fclose(f);
        if (!result[0]) snprintf(result, result_size, "No notes yet.");
        return 1;
    }

    /* ── alarm ── */
    if (strcmp(tool_name, "alarm") == 0) {
        char time_str[32] = {0};
        parse_param(tool_start, "time", time_str, sizeof(time_str));
        parse_param(tool_start, "msg", msg, sizeof(msg));
        /* Schedule via at/cron or just echo for now */
        snprintf(result, result_size,
            "Alarm set for %s: %s\n(Note: requires cron/at daemon for actual execution)",
            time_str, msg);
        /* Save to a simple alarms file */
        FILE *f = fopen("/usr/share/agentic/alarms.txt", "a");
        if (f) { fprintf(f, "%s|%s\n", time_str, msg); fclose(f); }
        return 1;
    }

    /* ── weather ── */
    if (strcmp(tool_name, "weather") == 0) {
        parse_param(tool_start, "city", city, sizeof(city));
        /* Use wttr.in via wget — works if network is up */
        char cmd[512];
        snprintf(cmd, sizeof(cmd),
            "wget -q -O - 'wttr.in/%s?format=3' 2>/dev/null || echo 'No network'", city);
        FILE *pipe = popen(cmd, "r");
        if (pipe) {
            result[0] = '\0';
            fread(result, 1, result_size-1, pipe);
            pclose(pipe);
        } else {
            snprintf(result, result_size, "Weather fetch failed");
        }
        return 1;
    }

    /* ── web_search ── */
    if (strcmp(tool_name, "web_search") == 0) {
        parse_param(tool_start, "query", query, sizeof(query));
        char cmd[512];
        snprintf(cmd, sizeof(cmd),
            "wget -q -O - 'https://api.duckduckgo.com/?q=%s&format=json&no_html=1&skip_disambig=1' 2>/dev/null | "
            "grep -o '\"AbstractText\":\"[^\"]*\"' | head -1 | sed 's/\"AbstractText\":\"//;s/\"$//'",
            query);
        FILE *pipe = popen(cmd, "r");
        if (pipe) {
            result[0] = '\0';
            fread(result, 1, result_size-1, pipe);
            pclose(pipe);
            if (!result[0]) snprintf(result, result_size, "No results found (or no network).");
        } else {
            snprintf(result, result_size, "Search failed");
        }
        return 1;
    }

    snprintf(result, result_size, "[unknown tool: %s]", tool_name);
    return 1;
}

/* ── Forward declarations for helpers used in ai_init ───────────────────────── */
static int llama_server_available(void);
static int call_local_server(const char *prompt, char *response, size_t resp_size);

/* ── Init ─────────────────────────────────────────────────────────────────── */
int ai_init(const ai_config_t *config) {
    if (!config) return -1;
    memcpy(&g_config, config, sizeof(ai_config_t));
    g_initialized = 1;

    /* Set system prompt if not overridden */
    if (strlen(g_config.system_prompt) == 0)
        strncpy(g_config.system_prompt, SYSTEM_PROMPT, sizeof(g_config.system_prompt)-1);

    /* Default llama-server URL: QEMU host IP */
    if (strlen(g_config.local_server_url) == 0)
        strncpy(g_config.local_server_url, "http://10.0.2.2:8080",
                sizeof(g_config.local_server_url)-1);

    printf("[ai] initialized in mode: ");
    switch (g_config.mode) {
        case AI_MODE_AUTO:         printf("auto\n"); break;
        case AI_MODE_LOCAL:        printf("local\n"); break;
        case AI_MODE_LOCAL_SERVER: printf("llama-server\n"); break;
        case AI_MODE_CLOUD:        printf("cloud\n"); break;
        case AI_MODE_KEYWORDS:     printf("keywords\n"); break;
    }

    /* Check llama-server reachability first; in AUTO mode we prefer it over
       loading a multi-gigabyte local model inside the small VM. */
    int server_reachable = 0;
    if (g_config.mode == AI_MODE_LOCAL_SERVER || g_config.mode == AI_MODE_AUTO) {
        server_reachable = llama_server_available();
        if (server_reachable)
            printf("[ai] llama-server: reachable at %s\n", g_config.local_server_url);
        else
            printf("[ai] llama-server: not reachable at %s\n"
                   "[ai]   → on your Mac run: llama-server -m /path/to/model.gguf --host 0.0.0.0 --port 8080\n"
                   "[ai]   → then type !llama inside the shell\n",
                   g_config.local_server_url);
    }

    if (g_config.mode == AI_MODE_LOCAL ||
        (g_config.mode == AI_MODE_AUTO && !server_reachable)) {
        if (ai_local_available()) {
            printf("[ai] loading local model: %s\n", g_config.model_path);
            if (local_llm_init(g_config.model_path,
                               g_config.context_size > 0 ? g_config.context_size : 2048,
                               g_config.threads > 0 ? g_config.threads : 2) != 0) {
                printf("[ai] WARNING: failed to load local model\n");
            }
        } else {
            printf("[ai] WARNING: local model not found at %s\n", g_config.model_path);
        }
    } else if (g_config.mode == AI_MODE_AUTO && server_reachable) {
        printf("[ai] local model found but AUTO mode prefers llama-server; skipping in-VM load\n");
    }

    if (g_config.mode == AI_MODE_CLOUD || g_config.mode == AI_MODE_AUTO) {
        /* Check env for API key */
        const char *env_key = getenv("ANTHROPIC_API_KEY");
        if (env_key && strlen(env_key) > 0)
            strncpy(g_config.cloud_api_key, env_key, sizeof(g_config.cloud_api_key)-1);

        if (ai_cloud_available())
            printf("[ai] cloud: %s/%s\n", g_config.cloud_provider, g_config.cloud_model);
        else
            printf("[ai] cloud: no API key (set ANTHROPIC_API_KEY or write to /usr/share/agentic/api_key)\n");
    }

    return 0;
}

void ai_shutdown(void) { g_initialized = 0; }

int ai_local_available(void) {
    if (strlen(g_config.model_path) == 0) return 0;
    struct stat st;
    return (stat(g_config.model_path, &st) == 0);
}

int ai_cloud_available(void) {
    return strlen(g_config.cloud_api_key) > 0;
}

ai_mode_t ai_get_mode(void) { return g_config.mode; }
void ai_set_mode(ai_mode_t mode) { g_config.mode = mode; }

/* ── Forward declarations for helpers used in ai_init ───────────────────────── */
static int llama_server_available(void);
static int call_local_server(const char *prompt, char *response, size_t resp_size);

/* ── Local llama.cpp call ─────────────────────────────────────────────────── */
static int call_local_llama(const char *prompt, char *response, size_t resp_size) {
    if (!ai_local_available() || !local_llm_ready()) {
        snprintf(response, resp_size, "[local LLM not ready]");
        return -1;
    }
    return local_llm_query(g_config.system_prompt, prompt, response, resp_size, 256);
}

/* ── Local llama-server via wget ─────────────────────────────────────────── */
/*
 * Calls llama.cpp server running on the host Mac at 10.0.2.2:8080.
 * Uses the OpenAI-compatible /v1/chat/completions endpoint.
 * Start on host: llama-server -m /path/to/model.gguf --host 0.0.0.0 --port 8080
 */
static int llama_server_available(void) {
    if (strlen(g_config.local_server_url) == 0) return 0;
    char cmd[256];
    snprintf(cmd, sizeof(cmd),
        "wget -q --timeout=2 -O /dev/null '%s/health' 2>/dev/null",
        g_config.local_server_url);
    return system(cmd) == 0;
}

static int call_local_server(const char *prompt, char *response, size_t resp_size) {
    if (strlen(g_config.local_server_url) == 0) return -1;

    /* Escape prompt */
    char escaped[8192] = {0};
    size_t j = 0;
    for (size_t i = 0; prompt[i] && j < sizeof(escaped)-3; i++) {
        if      (prompt[i] == '"')  { escaped[j++]='\\'; escaped[j++]='"'; }
        else if (prompt[i] == '\n') { escaped[j++]='\\'; escaped[j++]='n'; }
        else if (prompt[i] == '\\') { escaped[j++]='\\'; escaped[j++]='\\'; }
        else escaped[j++] = prompt[i];
    }
    escaped[j] = '\0';

    FILE *f = fopen("/tmp/llama_req.json", "w");
    if (!f) return -1;
    fprintf(f,
        "{\"model\":\"local\",\"max_tokens\":512,"
        "\"messages\":["
        "{\"role\":\"system\",\"content\":\"You are the AI shell of PryzentOS. Reply concisely. For shell tasks output only the command. For tool calls output only [TOOL:name key=val].\"},"
        "{\"role\":\"user\",\"content\":\"%s\"}"
        "]}",
        escaped);
    fclose(f);

    char cmd[512];
    snprintf(cmd, sizeof(cmd),
        "wget -q -O /tmp/llama_resp.json "
        "--header='Content-Type: application/json' "
        "--post-file=/tmp/llama_req.json "
        "'%s/v1/chat/completions' 2>/dev/null",
        g_config.local_server_url);

    if (system(cmd) != 0) {
        snprintf(response, resp_size, "[llama-server not reachable at %s]", g_config.local_server_url);
        return -1;
    }

    f = fopen("/tmp/llama_resp.json", "r");
    if (!f) return -1;
    char raw[8192] = {0};
    fread(raw, 1, sizeof(raw)-1, f);
    fclose(f);

    /* Parse: "content":"..." from choices[0].message.content */
    const char *tag = strstr(raw, "\"content\":\"");
    if (!tag) {
        snprintf(response, resp_size, "[unexpected server response]");
        return -1;
    }
    tag += 11;
    size_t i = 0;
    while (*tag && i < resp_size-1) {
        if (*tag == '\\' && *(tag+1) == '"')  { response[i++]='"';  tag+=2; }
        else if (*tag == '\\' && *(tag+1) == 'n') { response[i++]='\n'; tag+=2; }
        else if (*tag == '\\' && *(tag+1) == '\\') { response[i++]='\\'; tag+=2; }
        else if (*tag == '"') break;
        else response[i++] = *tag++;
    }
    response[i] = '\0';
    return 0;
}

/* ── Cloud API via wget (Anthropic) ──────────────────────────────────────── */
static int call_cloud_api(const char *prompt, char *response, size_t resp_size) {
    if (!ai_cloud_available()) return -1;

    /* Build context string */
    char ctx[MAX_CONTEXT] = {0};
    context_read(ctx, sizeof(ctx));

    /* Escape prompt for JSON: replace " with \" and newlines with \n */
    char escaped_prompt[8192] = {0};
    size_t j = 0;
    for (size_t i = 0; prompt[i] && j < sizeof(escaped_prompt)-3; i++) {
        if (prompt[i] == '"')       { escaped_prompt[j++] = '\\'; escaped_prompt[j++] = '"'; }
        else if (prompt[i] == '\n') { escaped_prompt[j++] = '\\'; escaped_prompt[j++] = 'n'; }
        else if (prompt[i] == '\\') { escaped_prompt[j++] = '\\'; escaped_prompt[j++] = '\\'; }
        else escaped_prompt[j++] = prompt[i];
    }
    escaped_prompt[j] = '\0';

    /* Write JSON body to temp file (avoid shell escaping nightmares) */
    FILE *body_f = fopen("/tmp/ai_request.json", "w");
    if (!body_f) return -1;
    fprintf(body_f,
        "{"
        "\"model\":\"%s\","
        "\"max_tokens\":512,"
        "\"system\":\"%s\","
        "\"messages\":[{\"role\":\"user\",\"content\":\"%s\"}]"
        "}",
        g_config.cloud_model,
        "You are the AI shell of PryzentOS. Reply concisely. For shell commands output only the command. For tool calls output only [TOOL:name key=val]. For conversation reply naturally.",
        escaped_prompt);
    fclose(body_f);

    /* Call API using wget */
    char cmd[2048];
    snprintf(cmd, sizeof(cmd),
        "wget -q -O /tmp/ai_response.json "
        "--header='Content-Type: application/json' "
        "--header='x-api-key: %s' "
        "--header='anthropic-version: 2023-06-01' "
        "--post-file=/tmp/ai_request.json "
        "'https://api.anthropic.com/v1/messages' 2>/dev/null",
        g_config.cloud_api_key);

    int rc = system(cmd);
    if (rc != 0) {
        snprintf(response, resp_size, "[cloud API call failed — check network]");
        return -1;
    }

    /* Extract text from response JSON: look for "text":"..." */
    FILE *resp_f = fopen("/tmp/ai_response.json", "r");
    if (!resp_f) { snprintf(response, resp_size, "[no response file]"); return -1; }

    char raw[8192] = {0};
    fread(raw, 1, sizeof(raw)-1, resp_f);
    fclose(resp_f);

    const char *text_tag = strstr(raw, "\"text\":\"");
    if (!text_tag) {
        /* Check for error message */
        const char *err = strstr(raw, "\"message\":\"");
        if (err) {
            err += 11;
            size_t i = 0;
            while (*err && *err != '"' && i < resp_size-1)
                response[i++] = *err++;
            response[i] = '\0';
        } else {
            snprintf(response, resp_size, "[unexpected API response]");
        }
        return -1;
    }

    text_tag += 8; /* skip "text":" */
    size_t i = 0;
    while (*text_tag && i < resp_size-1) {
        if (*text_tag == '\\' && *(text_tag+1) == '"')  { response[i++] = '"';  text_tag += 2; }
        else if (*text_tag == '\\' && *(text_tag+1) == 'n') { response[i++] = '\n'; text_tag += 2; }
        else if (*text_tag == '\\' && *(text_tag+1) == '\\') { response[i++] = '\\'; text_tag += 2; }
        else if (*text_tag == '"') break;
        else response[i++] = *text_tag++;
    }
    response[i] = '\0';
    return 0;
}

/* ── Extract shell command ────────────────────────────────────────────────── */
void ai_extract_command(const char *response, char *cmd, size_t cmd_size) {
    if (!response || !cmd || cmd_size == 0) return;
    cmd[0] = '\0';

    /* Skip if it's a tool call or plain text (contains spaces/punctuation) */
    if (strstr(response, "[TOOL:")) return;

    /* Code block */
    const char *start = strstr(response, "```");
    if (start) {
        start += 3;
        if (strncmp(start, "bash", 4) == 0 || strncmp(start, "sh", 2) == 0) {
            start = strchr(start, '\n');
            if (start) start++;
        }
        const char *end = strstr(start, "```");
        if (end && (size_t)(end - start) < cmd_size) {
            strncpy(cmd, start, end - start);
            cmd[end - start] = '\0';
            return;
        }
    }

    /* $ prefix */
    const char *dollar = strchr(response, '$');
    if (dollar && (size_t)(dollar - response) < 20) {
        dollar++;
        while (*dollar == ' ') dollar++;
        strncpy(cmd, dollar, cmd_size-1);
        cmd[cmd_size-1] = '\0';
        char *nl = strchr(cmd, '\n');
        if (nl) *nl = '\0';
        return;
    }

    /* Single-line response that looks like a command (starts with a known command word) */
    const char *cmds[] = {"ls","df","free","ps","ip","cat","echo","mount",
                          "top","uname","uptime","dmesg","ping","wget","find",NULL};
    for (int i = 0; cmds[i]; i++) {
        size_t clen = strlen(cmds[i]);
        if (strncmp(response, cmds[i], clen) == 0 &&
            (response[clen] == ' ' || response[clen] == '\0' || response[clen] == '\n')) {
            const char *nl = strchr(response, '\n');
            size_t len = nl ? (size_t)(nl - response) : strlen(response);
            if (len < cmd_size) { strncpy(cmd, response, len); cmd[len] = '\0'; }
            return;
        }
    }
}

/* ── Main query entry point ───────────────────────────────────────────────── */
ai_response_t ai_query(const char *intent) {
    ai_response_t resp = {0};

    if (!g_initialized) {
        snprintf(resp.text, sizeof(resp.text), "[ai not initialized]");
        return resp;
    }

    /* Re-read API key from env (may have been set after init) */
    const char *env_key = getenv("ANTHROPIC_API_KEY");
    if (env_key && strlen(env_key) > 0)
        strncpy(g_config.cloud_api_key, env_key, sizeof(g_config.cloud_api_key)-1);

    /* Append user message to context */
    context_append("user", intent);

    /* Build prompt with memory context */
    char memory_context[MAX_MEMORY/2] = {0};
    FILE *mf = fopen(MEMORY_FILE, "r");
    if (mf) {
        char line[256];
        int count = 0;
        while (fgets(line, sizeof(line), mf) && count < 10) {
            if (line[0] != '#' && line[0] != '\n') {
                strncat(memory_context, line, sizeof(memory_context)-strlen(memory_context)-1);
                count++;
            }
        }
        fclose(mf);
    }

    char prompt[8192];
    if (memory_context[0])
        snprintf(prompt, sizeof(prompt), "[Memory]\n%s\n[Request]\n%s", memory_context, intent);
    else
        strncpy(prompt, intent, sizeof(prompt)-1);

    int rc = -1;

    /* 1. Local llama.cpp (model file loaded in VM) */
    if (g_config.mode == AI_MODE_LOCAL ||
        (g_config.mode == AI_MODE_AUTO && ai_local_available() && local_llm_ready())) {
        rc = call_local_llama(prompt, resp.text, sizeof(resp.text));
        resp.backend_used = AI_BACKEND_LOCAL_LLAMA;
    }

    /* 2. llama-server on host Mac (10.0.2.2:8080) */
    if (rc != 0 && (g_config.mode == AI_MODE_LOCAL_SERVER ||
        (g_config.mode == AI_MODE_AUTO && llama_server_available()))) {
        rc = call_local_server(prompt, resp.text, sizeof(resp.text));
        resp.backend_used = AI_BACKEND_LOCAL_SERVER;
    }

    /* 3. Cloud API */
    if (rc != 0 && (g_config.mode == AI_MODE_CLOUD ||
        (g_config.mode == AI_MODE_AUTO && ai_cloud_available()))) {
        rc = call_cloud_api(prompt, resp.text, sizeof(resp.text));
        resp.backend_used = AI_BACKEND_CLOUD_ANTHROPIC;
    }

    if (rc == 0) {
        resp.success = 1;
        context_append("assistant", resp.text);

        /* Check for tool call */
        char tool_result[2048] = {0};
        if (tool_dispatch(resp.text, tool_result, sizeof(tool_result))) {
            strncpy(resp.text, tool_result, sizeof(resp.text)-1);
        } else {
            ai_extract_command(resp.text, resp.command, sizeof(resp.command));
        }
    } else if (rc != 0) {
        snprintf(resp.text, sizeof(resp.text),
                 "[no AI available — try '!cloud' and set ANTHROPIC_API_KEY, or '!keywords']");
    }

    return resp;
}
