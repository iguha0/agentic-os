/*
 * Agentic Shell with Real AI Integration
 * Uses llama.cpp (Gemma) for local inference OR cloud APIs
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/reboot.h>
#include <fcntl.h>
#include <signal.h>
#include <errno.h>

#define MAX_LINE 4096

#include "ai_client.h"

/* Global AI config */
static ai_config_t g_ai_config = {
    .mode = AI_MODE_AUTO,
    .model_path = "/usr/share/agentic/models/gemma-4-E4B-it-Q4_K_M.gguf",
    .context_size = 2048,
    .threads = 2,
    .cloud_provider = "anthropic",
    .cloud_api_key = "",  // Set from env var at runtime
    .cloud_model = "claude-3-5-haiku-20241022",
    .cloud_endpoint = "https://api.anthropic.com",
    .system_prompt = ""
};

/* Current AI mode */
static int g_ai_mode_index = 0;
static const char* g_ai_modes[] = {"auto", "local", "cloud", "keywords", NULL};

static void print_help(void) {
    printf("\nAgentic OS — just type what you want\n");
    printf("\nSystem commands:\n");
    printf("  help                    this help\n");
    printf("  exit / quit             leave\n");
    printf("  $ <cmd>                 run raw shell command\n");
    printf("\nAI mode:\n");
    printf("  !auto                   local model → llama-server → cloud\n");
    printf("  !local                  force local model (in VM)\n");
    printf("  !llama                  use llama-server on your Mac (10.0.2.2:8080)\n");
    printf("  !cloud                  force cloud (needs API key)\n");
    printf("  !keywords               no AI, keyword matching only\n");
    printf("  !mode                   show current mode\n");
    printf("  !key <ANTHROPIC_KEY>    set cloud API key for this session\n");
    printf("\nBuilt-in tools (AI will use these automatically):\n");
    printf("  remember <thing>        save something to memory\n");
    printf("  recall <thing>          retrieve from memory\n");
    printf("  note <text>             save a note\n");
    printf("  notes                   list all notes\n");
    printf("  weather <city>          get weather (needs network)\n");
    printf("  search <query>          web search (needs network)\n");
    printf("  set alarm <time> <msg>  set an alarm\n");
    printf("\nExamples:\n");
    printf("  show disk usage\n");
    printf("  remember my name is Indrajit\n");
    printf("  what's the weather in Mumbai\n");
    printf("  note meeting with team tomorrow 3pm\n\n");
}

static int run_shell_command(const char *cmd) {
    int rc;
    int status = 0;
    pid_t pid = fork();

    if (pid == 0) {
        /* Child */
        /* Set signal handlers back to default for child */
        signal(SIGINT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);

        /* Run in a new shell process */
        execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
        _exit(127); /* Should never reach here */
    }

    /* Parent */
    do {
        rc = waitpid(pid, &status, 0);

        if (rc == -1 && errno == EINTR) {
            /* Child terminated with signal? */
            if (WIFSIGNALED(status)) {
                printf("Command terminated by signal %d\n", WTERMSIG(status));
            }
        }
    } while (rc == -1 && errno == EINTR);

    if (rc == pid && WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return -1;
}

static void handle_ai_mode_command(const char *cmd) {
    if (strcmp(cmd, "!local") == 0) {
        ai_set_mode(AI_MODE_LOCAL);
        printf("AI mode: local (offline)\n");
    } else if (strcmp(cmd, "!cloud") == 0) {
        ai_set_mode(AI_MODE_CLOUD);
        printf("AI mode: cloud (online)\n");
    } else if (strcmp(cmd, "!auto") == 0) {
        ai_set_mode(AI_MODE_AUTO);
        printf("AI mode: auto (try local first)\n");
    } else if (strcmp(cmd, "!keywords") == 0) {
        ai_set_mode(AI_MODE_KEYWORDS);
        printf("AI mode: keywords only (no AI)\n");
    } else if (strcmp(cmd, "!mode") == 0) {
        const char *mode_str = "unknown";
        switch (ai_get_mode()) {
            case AI_MODE_AUTO:         mode_str = "auto"; break;
            case AI_MODE_LOCAL:        mode_str = "local (in-VM)"; break;
            case AI_MODE_LOCAL_SERVER: mode_str = "llama-server (host Mac)"; break;
            case AI_MODE_CLOUD:        mode_str = "cloud"; break;
            case AI_MODE_KEYWORDS:     mode_str = "keywords"; break;
        }
        printf("Current AI mode: %s\n", mode_str);
        printf("AI backends available:\n");
        printf("  Local: %s\n", ai_local_available() ? "yes" : "no");
        printf("  Cloud: %s\n", ai_cloud_available() ? "yes" : "no");
    } else if (strcmp(cmd, "!llama") == 0 || strncmp(cmd, "!llama ", 7) == 0) {
        ai_set_mode(AI_MODE_LOCAL_SERVER);
        printf("AI mode: llama-server (your Mac at 10.0.2.2:8080)\n");
        printf("Make sure you have it running on your Mac:\n");
        printf("  scripts/run-llama-server.sh\n");
        printf("Or manually:\n");
        printf("  ~/llama.cpp/build-host/bin/llama-server \\\n");
        printf("    -m /Users/indrajitguha/models/gemma-4-E4B-it-Q4_K_M.gguf \\\n");
        printf("    --host 0.0.0.0 --port 8080 --ctx-size 2048 -ngl 0 --no-mmap\n");
    } else if (strncmp(cmd, "!key ", 5) == 0) {
        const char *key = cmd + 5;
        while (*key == ' ') key++;
        if (strlen(key) > 0) {
            setenv("ANTHROPIC_API_KEY", key, 1);
            /* Also write to file so init can load it next boot */
            FILE *f = fopen("/usr/share/agentic/api_key", "w");
            if (f) { fprintf(f, "%s", key); fclose(f); }
            ai_set_mode(AI_MODE_CLOUD);
            printf("API key set. Switched to cloud mode.\n");
        } else {
            printf("Usage: !key <YOUR_ANTHROPIC_API_KEY>\n");
        }
    } else if (strcmp(cmd, "!help") == 0) {
        print_help();
    } else {
        printf("Unknown command: %s. Type 'help' for help.\n", cmd);
    }
}

static int handle_intent(const char *intent) {
    char cmd[MAX_LINE];
    ai_response_t ai_resp;

    /* Check if it's an AI mode command */
    if (intent[0] == '!') {
        handle_ai_mode_command(intent);
        return 0;
    }

    /* Get cloud API key from environment */
    const char *api_key = getenv("ANTHROPIC_API_KEY");
    if (api_key && strlen(api_key) > 0) {
        strncpy(g_ai_config.cloud_api_key, api_key, sizeof(g_ai_config.cloud_api_key) - 1);
    }

    /* Handle keywords if in keywords mode or AI fails */
    if (ai_get_mode() == AI_MODE_KEYWORDS) {
        /* Simple keyword-to-command mapping */
        if (strstr(intent, "list") && strstr(intent, "files")) {
            snprintf(cmd, sizeof(cmd), "ls -la /");
        } else if (strstr(intent, "show") && strstr(intent, "disk")) {
            snprintf(cmd, sizeof(cmd), "df -h");
        } else if (strstr(intent, "show") && (strstr(intent, "memory") || strstr(intent, "ram"))) {
            snprintf(cmd, sizeof(cmd), "free -h");
        } else if (strstr(intent, "show") && strstr(intent, "uptime")) {
            snprintf(cmd, sizeof(cmd), "uptime");
        } else if (strstr(intent, "show") && strstr(intent, "network")) {
            snprintf(cmd, sizeof(cmd), "ip addr && ip route");
        } else if (strstr(intent, "show") && (strstr(intent, "process") || strstr(intent, "ps"))) {
            snprintf(cmd, sizeof(cmd), "ps aux | head -20");
        } else if (strstr(intent, "hello") || strncmp(intent, "hi", 2) == 0 || strncmp(intent, "hey", 3) == 0) {
            printf("agent: hi. what do you want to do?\n");
            return 0;
        } else if (strstr(intent, "who") && strstr(intent, "you")) {
            printf("agent: i'm the agentic shell powered by AI. try 'help' for commands.\n");
            return 0;
        } else if (strstr(intent, "shutdown") || strstr(intent, "power off")) {
            printf("agent: shutting down.\n");
            sync();
            reboot(0x4321fedc);  /* LINUX_REBOOT_CMD_POWER_OFF */
            return 0;
        } else if (strstr(intent, "reboot")) {
            printf("agent: rebooting.\n");
            sync();
            reboot(0x01234567);  /* LINUX_REBOOT_CMD_RESTART */
            return 0;
        } else {
            printf("agent: i don't understand that command (keywords mode only)\n");
            return 0;
        }
    } else {
        /* AI mode - try AI first */
        ai_resp = ai_query(intent);

        if (ai_resp.success) {
            if (strlen(ai_resp.command) > 0) {
                strncpy(cmd, ai_resp.command, sizeof(cmd) - 1);
                cmd[sizeof(cmd) - 1] = '\0';

                /* Log which backend was used */
                const char *backend = "unknown";
                switch (ai_resp.backend_used) {
                    case AI_BACKEND_NONE:            backend = "none"; break;
                    case AI_BACKEND_LOCAL_LLAMA:     backend = "local model"; break;
                    case AI_BACKEND_LOCAL_SERVER:    backend = "llama-server"; break;
                    case AI_BACKEND_CLOUD_ANTHROPIC: backend = "cloud API"; break;
                    case AI_BACKEND_CLOUD_OPENAI:    backend = "OpenAI API"; break;
                }
                printf("agent: [%s] running: %s\n", backend, cmd);

                return run_shell_command(cmd);
            } else {
                printf("agent: [ai] %s\n", ai_resp.text);
                return 0;
            }
        } else {
            printf("agent: [ai] %s\n", ai_resp.text);

            /* Fallback to keywords */
            if (strstr(intent, "list") && strstr(intent, "files")) {
                snprintf(cmd, sizeof(cmd), "ls -la /");
                return run_shell_command(cmd);
            } else if (strstr(intent, "show") && strstr(intent, "disk")) {
                snprintf(cmd, sizeof(cmd), "df -h");
                return run_shell_command(cmd);
            } else if (strstr(intent, "show") && (strstr(intent, "memory") || strstr(intent, "ram"))) {
                snprintf(cmd, sizeof(cmd), "free -h");
                return run_shell_command(cmd);
            } else {
                return 0;
            }
        }
    }
    return 0;
}

int main(void) {
    char line[MAX_LINE];

    /* Initialize AI client */
    if (ai_init(&g_ai_config) != 0) {
        fprintf(stderr, "ERROR: Failed to initialize AI client\n");
        return 1;
    }

    /* Make terminal unbuffered for interactive use */
    setvbuf(stdin, NULL, _IONBF, 0);
    setvbuf(stdout, NULL, _IONBF, 0);

    print_help();

    /* Main loop */
    while (1) {
        printf("> ");
        fflush(stdout);

        /* Read line */
        if (!fgets(line, sizeof(line), stdin)) {
            if (feof(stdin)) {
                printf("\n");
                break;
            } else {
                printf("input error\n");
                continue;
            }
        }

        /* Strip newline */
        size_t len = strlen(line);
        if (len > 0 && line[len-1] == '\n') {
            line[len-1] = '\0';
            len--;
        }

        /* Skip empty lines */
        if (len == 0) {
            continue;
        }

        /* Handle exit */
        if (strcmp(line, "exit") == 0 || strcmp(line, "quit") == 0) {
            printf("bye.\n");
            break;
        }

        /* Handle help */
        if (strcmp(line, "help") == 0) {
            print_help();
            continue;
        }

        /* Handle $ prefix for raw shell commands */
        if (line[0] == '$' && line[1] == ' ') {
            int rc = run_shell_command(line + 2);
            if (rc != 0) {
                printf("[exit %d]\n", rc);
            }
            continue;
        }

        /* Handle AI request */
        handle_intent(line);
    }

    ai_shutdown();
    return 0;
}