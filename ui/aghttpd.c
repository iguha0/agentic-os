/*
 * aghttpd.c — minimal HTTP/1.0 server for PryzentOS
 * Serves static files and executes CGI scripts (cgi-bin/).
 * Single-threaded, fork-per-request.
 * Compile: aarch64-linux-gnu-gcc -static -O2 -o aghttpd aghttpd.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define MAX_REQ   8192
#define MAX_PATH  2048
#define MAX_HDR   64

static char g_docroot[MAX_PATH] = "/usr/share/agentic/ui";
static int  g_port              = 7080;

/* ── MIME types ──────────────────────────────────────────────────────────── */
static const char *mime_type(const char *path) {
    const char *ext = strrchr(path, '.');
    if (!ext) return "application/octet-stream";
    if (strcmp(ext, ".html") == 0 || strcmp(ext, ".htm") == 0) return "text/html";
    if (strcmp(ext, ".css")  == 0) return "text/css";
    if (strcmp(ext, ".js")   == 0) return "application/javascript";
    if (strcmp(ext, ".json") == 0) return "application/json";
    if (strcmp(ext, ".png")  == 0) return "image/png";
    if (strcmp(ext, ".jpg")  == 0 || strcmp(ext, ".jpeg") == 0) return "image/jpeg";
    if (strcmp(ext, ".svg")  == 0) return "image/svg+xml";
    if (strcmp(ext, ".ico")  == 0) return "image/x-icon";
    if (strcmp(ext, ".txt")  == 0) return "text/plain";
    return "application/octet-stream";
}

/* ── URL decode ──────────────────────────────────────────────────────────── */
static void url_decode(const char *src, char *dst, int dstlen) {
    int i = 0;
    while (*src && i < dstlen - 1) {
        if (*src == '%' && src[1] && src[2]) {
            char hex[3] = { src[1], src[2], 0 };
            dst[i++] = (char)strtol(hex, NULL, 16);
            src += 3;
        } else if (*src == '+') {
            dst[i++] = ' ';
            src++;
        } else {
            dst[i++] = *src++;
        }
    }
    dst[i] = '\0';
}

/* ── Send a simple error response ────────────────────────────────────────── */
static void send_error(int fd, int code, const char *msg) {
    char buf[512];
    int n = snprintf(buf, sizeof(buf),
        "HTTP/1.0 %d %s\r\n"
        "Content-Type: text/plain\r\n"
        "Connection: close\r\n"
        "\r\n"
        "%d %s\n", code, msg, code, msg);
    write(fd, buf, n);
}

/* ── Serve a static file ─────────────────────────────────────────────────── */
static void serve_file(int fd, const char *fpath) {
    struct stat st;
    if (stat(fpath, &st) != 0 || !S_ISREG(st.st_mode)) {
        send_error(fd, 404, "Not Found");
        return;
    }
    int ffd = open(fpath, O_RDONLY);
    if (ffd < 0) { send_error(fd, 403, "Forbidden"); return; }

    char hdr[512];
    int n = snprintf(hdr, sizeof(hdr),
        "HTTP/1.0 200 OK\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %ld\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Connection: close\r\n"
        "\r\n", mime_type(fpath), (long)st.st_size);
    write(fd, hdr, n);

    char buf[4096];
    ssize_t r;
    while ((r = read(ffd, buf, sizeof(buf))) > 0)
        write(fd, buf, r);
    close(ffd);
}

/* ── Run a CGI script ────────────────────────────────────────────────────── */
static void run_cgi(int fd, const char *script_path,
                    const char *method, const char *query,
                    const char *body, int body_len,
                    const char *remote_addr,
                    const char *content_type) {
    /* pipe: CGI stdout → fd */
    int pipefd[2];
    if (pipe(pipefd) < 0) { send_error(fd, 500, "pipe failed"); return; }

    /* pipe for POST body → CGI stdin */
    int body_pipe[2] = { -1, -1 };
    if (body_len > 0) pipe(body_pipe);

    pid_t pid = fork();
    if (pid < 0) { send_error(fd, 500, "fork failed"); return; }

    if (pid == 0) {
        /* child: set up CGI environment */
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[1]);

        if (body_len > 0 && body_pipe[0] >= 0) {
            close(body_pipe[1]);
            dup2(body_pipe[0], STDIN_FILENO);
            close(body_pipe[0]);
        } else {
            /* redirect stdin from /dev/null */
            int devnull = open("/dev/null", O_RDONLY);
            if (devnull >= 0) { dup2(devnull, STDIN_FILENO); close(devnull); }
        }

        /* CGI env vars */
        setenv("REQUEST_METHOD",  method,      1);
        setenv("QUERY_STRING",    query ? query : "", 1);
        setenv("SCRIPT_NAME",     script_path, 1);
        setenv("REMOTE_ADDR",     remote_addr ? remote_addr : "127.0.0.1", 1);
        setenv("SERVER_SOFTWARE", "aghttpd/1.0", 1);
        setenv("GATEWAY_INTERFACE", "CGI/1.1",  1);
        if (content_type)
            setenv("CONTENT_TYPE", content_type, 1);
        if (body_len > 0) {
            char cl[32]; snprintf(cl, sizeof(cl), "%d", body_len);
            setenv("CONTENT_LENGTH", cl, 1);
        }

        execl("/bin/sh", "sh", script_path, NULL);
        _exit(1);
    }

    /* parent: feed POST body then relay output */
    close(pipefd[1]);
    if (body_len > 0 && body_pipe[1] >= 0) {
        close(body_pipe[0]);
        write(body_pipe[1], body, body_len);
        close(body_pipe[1]);
    }

    /* send HTTP header + CGI output */
    /* CGI scripts emit their own headers; we just relay them */
    char buf[4096];
    ssize_t r;
    int sent_http = 0;
    char header_buf[2048];
    int hb_pos = 0;

    /* We need to inject "HTTP/1.0 200 OK\r\n" before CGI headers */
    /* Read CGI output and prefix with HTTP status line */
    char out_buf[65536];
    int out_pos = 0;
    while ((r = read(pipefd[0], buf, sizeof(buf))) > 0) {
        if (out_pos + r < (int)sizeof(out_buf))
            memcpy(out_buf + out_pos, buf, r);
        out_pos += r;
    }
    close(pipefd[0]);
    waitpid(pid, NULL, 0);

    if (out_pos == 0) {
        send_error(fd, 500, "CGI no output");
        return;
    }

    /* Prepend HTTP/1.0 200 OK if CGI didn't already send one */
    if (strncmp(out_buf, "HTTP/", 5) != 0) {
        const char *status = "HTTP/1.0 200 OK\r\n";
        write(fd, status, strlen(status));
    }
    write(fd, out_buf, out_pos);
    (void)sent_http; (void)hb_pos; (void)header_buf;
}

/* ── Parse and handle one HTTP request ──────────────────────────────────── */
static void handle_request(int fd) {
    char req[MAX_REQ];
    int  pos = 0;
    ssize_t r;

    /* Read until double CRLF or buffer full */
    while (pos < (int)sizeof(req) - 1) {
        r = read(fd, req + pos, sizeof(req) - 1 - pos);
        if (r <= 0) break;
        pos += r;
        if (pos >= 4 && strstr(req, "\r\n\r\n")) break;
        if (pos >= 4 && strstr(req, "\n\n"))     break;
    }
    req[pos] = '\0';

    /* Parse request line */
    char method[16], raw_path[MAX_PATH], proto[16];
    if (sscanf(req, "%15s %2047s %15s", method, raw_path, proto) < 2) {
        send_error(fd, 400, "Bad Request");
        return;
    }

    /* Split path and query string */
    char url_path[MAX_PATH], query[MAX_PATH];
    char *q = strchr(raw_path, '?');
    if (q) {
        int plen = q - raw_path;
        if (plen >= MAX_PATH) plen = MAX_PATH - 1;
        strncpy(url_path, raw_path, plen); url_path[plen] = '\0';
        strncpy(query, q + 1, MAX_PATH - 1); query[MAX_PATH-1] = '\0';
    } else {
        strncpy(url_path, raw_path, MAX_PATH - 1); url_path[MAX_PATH-1] = '\0';
        query[0] = '\0';
    }

    /* Decode URL */
    char dec_path[MAX_PATH];
    url_decode(url_path, dec_path, sizeof(dec_path));

    /* Security: block path traversal */
    if (strstr(dec_path, "..")) { send_error(fd, 403, "Forbidden"); return; }

    /* Handle CORS preflight */
    if (strcmp(method, "OPTIONS") == 0) {
        const char *cors =
            "HTTP/1.0 204 No Content\r\n"
            "Access-Control-Allow-Origin: *\r\n"
            "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
            "Access-Control-Allow-Headers: Content-Type\r\n"
            "Connection: close\r\n\r\n";
        write(fd, cors, strlen(cors));
        return;
    }

    /* Extract headers we care about */
    int   content_len  = 0;
    char  content_type[256] = "";
    char *hdr = strstr(req, "\r\n");
    if (!hdr) hdr = strstr(req, "\n");
    if (hdr) {
        char *p = hdr;
        while (*p) {
            /* skip \r\n or \n */
            if (*p == '\r') p++;
            if (*p == '\n') p++;
            if (*p == '\r' || *p == '\n') break; /* blank line = end of headers */
            /* check header name */
            if (strncasecmp(p, "Content-Length:", 15) == 0)
                content_len = atoi(p + 15);
            else if (strncasecmp(p, "Content-Type:", 13) == 0) {
                char *v = p + 13;
                while (*v == ' ') v++;
                int vl = 0;
                while (v[vl] && v[vl] != '\r' && v[vl] != '\n') vl++;
                if (vl >= (int)sizeof(content_type)) vl = sizeof(content_type) - 1;
                strncpy(content_type, v, vl); content_type[vl] = '\0';
            }
            /* advance to next line */
            while (*p && *p != '\n') p++;
        }
    }

    /* Extract POST body (may be in the same buffer after \r\n\r\n) */
    char *body_start = strstr(req, "\r\n\r\n");
    if (body_start) body_start += 4;
    else {
        body_start = strstr(req, "\n\n");
        if (body_start) body_start += 2;
    }
    int body_in_buf = 0;
    if (body_start && body_start < req + pos)
        body_in_buf = (req + pos) - body_start;

    /* Read remaining body if content_len > body_in_buf */
    char *body = NULL;
    int   body_len = 0;
    if (content_len > 0) {
        body = malloc(content_len + 1);
        if (body && body_start) {
            int to_copy = body_in_buf < content_len ? body_in_buf : content_len;
            memcpy(body, body_start, to_copy);
            body_len = to_copy;
        }
        while (body && body_len < content_len) {
            r = read(fd, body + body_len, content_len - body_len);
            if (r <= 0) break;
            body_len += r;
        }
        if (body) body[body_len] = '\0';
    }

    /* Default path: / → /index.html */
    if (strcmp(dec_path, "/") == 0)
        strcpy(dec_path, "/index.html");

    /* Build filesystem path */
    char fspath[MAX_PATH * 2];
    snprintf(fspath, sizeof(fspath), "%s%s", g_docroot, dec_path);

    /* Check if it's a CGI script */
    int is_cgi = (strstr(dec_path, "/cgi-bin/") != NULL);

    if (is_cgi) {
        struct stat st;
        if (stat(fspath, &st) != 0 || !S_ISREG(st.st_mode)) {
            send_error(fd, 404, "CGI Not Found");
        } else {
            run_cgi(fd, fspath, method, query,
                    body, body_len,
                    "127.0.0.1",
                    content_type[0] ? content_type : NULL);
        }
    } else {
        /* Try path as-is, then as directory/index.html */
        struct stat st;
        if (stat(fspath, &st) == 0 && S_ISDIR(st.st_mode)) {
            char idx[MAX_PATH * 2 + 12];
            snprintf(idx, sizeof(idx), "%s/index.html", fspath);
            serve_file(fd, idx);
        } else {
            serve_file(fd, fspath);
        }
    }

    if (body) free(body);
}

/* ── Main ─────────────────────────────────────────────────────────────────── */
int main(int argc, char *argv[]) {
    /* Parse args: aghttpd [-p port] [-h docroot] */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-p") == 0 && i+1 < argc)
            g_port = atoi(argv[++i]);
        else if (strcmp(argv[i], "-h") == 0 && i+1 < argc)
            strncpy(g_docroot, argv[++i], MAX_PATH-1);
    }

    signal(SIGCHLD, SIG_DFL); /* auto-reap children */
    signal(SIGPIPE, SIG_IGN);

    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { perror("socket"); return 1; }

    int opt = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr = {0};
    addr.sin_family      = AF_INET;
    addr.sin_port        = htons(g_port);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(srv, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind"); return 1;
    }
    if (listen(srv, 16) < 0) { perror("listen"); return 1; }

    fprintf(stderr, "[aghttpd] listening on port %d, docroot=%s\n",
            g_port, g_docroot);

    for (;;) {
        /* Reap zombies */
        while (waitpid(-1, NULL, WNOHANG) > 0) {}

        struct sockaddr_in cli;
        socklen_t cli_len = sizeof(cli);
        int cfd = accept(srv, (struct sockaddr*)&cli, &cli_len);
        if (cfd < 0) {
            if (errno == EINTR) continue;
            perror("accept");
            continue;
        }

        pid_t pid = fork();
        if (pid == 0) {
            close(srv);
            handle_request(cfd);
            close(cfd);
            _exit(0);
        }
        close(cfd);
    }
    return 0;
}
