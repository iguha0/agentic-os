/*
 * Agentic Shell — the only "app" in PryzentOS.
 * Reads intent from stdin, sends to local model, executes answer as shell.
 * No app drawer, no home screen. This is the home screen.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/types.h>
#include <sys/reboot.h>

#define MAX_LINE 4096

static void print_help(void) {
    printf("\nAgentic Shell — type what you want\n");
    printf("Built-in commands:\n");
    printf("  help              show this help\n");
    printf("  exit, quit        leave the agent\n");
    printf("  $ <command>       run a raw shell command (e.g. $ ls)\n");
    printf("\nOtherwise, just type what you want in plain English.\n");
    printf("The agent will figure out what to do.\n\n");
}

static int run_shell_command(const char *cmd) {
    pid_t pid = fork();
    if (pid == 0) {
        execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
        _exit(127);
    }
    int status;
    waitpid(pid, &status, 0);
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    return -1;
}

/*
 * The local model client. For now, this is a stub that
 * echoes intent + runs basic command inference. Real implementation
 * would talk to the cloud model (Claude/GPT/Gemini) over HTTPS.
 */
static int handle_intent(const char *intent) {
    char cmd[MAX_LINE];

    /* Simple intent-to-command inference. Real model would do this. */
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
    } else if (strncmp(intent, "hello", 5) == 0 || strncmp(intent, "hi", 2) == 0 || strncmp(intent, "hey", 3) == 0) {
        printf("agent: hi. what do you want to do?\n");
        return 0;
    } else if (strstr(intent, "book") && (strstr(intent, "flight") || strstr(intent, "ticket"))) {
        printf("agent: i can't book flights yet. this is a demo OS - no network, no apps, no APIs.\n");
        printf("agent: in a real build, this would call a flight booking API.\n");
        return 0;
    } else if (strstr(intent, "search") || strstr(intent, "find") || strstr(intent, "google")) {
        printf("agent: no internet here. this is an isolated demo OS.\n");
        return 0;
    } else if (strstr(intent, "who") && strstr(intent, "you")) {
        printf("agent: i'm the agentic shell. no apps. no menu. just type what you want.\n");
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
        printf("agent: i don't know how to do that yet. in a real build, the cloud model would figure it out.\n");
        return 0;
    }

    printf("agent: i'll run: %s\n", cmd);
    return run_shell_command(cmd);
}

int main(void) {
    char line[MAX_LINE];

    print_help();

    /* Make stdin/stdout unbuffered for interactive use */
    setvbuf(stdin, NULL, _IONBF, 0);
    setvbuf(stdout, NULL, _IONBF, 0);

    while (1) {
        printf("> ");
        fflush(stdout);

        if (!fgets(line, sizeof(line), stdin)) {
            printf("\n");
            break;
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

        if (strcmp(line, "exit") == 0 || strcmp(line, "quit") == 0) {
            printf("bye.\n");
            break;
        }

        if (strcmp(line, "help") == 0) {
            print_help();
            continue;
        }

        /* $ prefix bypasses intent parsing — raw shell */
        if (line[0] == '$' && line[1] == ' ') {
            int rc = run_shell_command(line + 2);
            if (rc != 0) {
                printf("[exit %d]\n", rc);
            }
            continue;
        }

        handle_intent(line);
    }

    return 0;
}
