/*
 * agbrowser.c — Agentic OS Terminal Browser
 * ==========================================
 * A lightweight interactive text browser for the terminal.
 *
 * Fetch:    uses busybox wget (already in rootfs, handles HTTPS)
 * Render:   strips HTML tags, decodes entities, paginates
 * Navigate: numbered links, URL bar, history (back/forward)
 * No TLS code needed — delegates SSL to wget.
 *
 * Build:
 *   aarch64-linux-gnu-gcc -static -O2 -o agbrowser agbrowser.c
 *
 * Usage:
 *   agbrowser [url]
 *   agbrowser                    — opens homepage
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <signal.h>
#include <ctype.h>
#include <errno.h>

/* ── Config ────────────────────────────────────────────────────────────────── */
#define MAX_URL       2048
#define MAX_LINKS     256
#define MAX_LINE      512
#define PAGE_LINES    40
#define HISTORY_MAX   32
#define CACHE_FILE    "/tmp/agbrowser_page.html"
#define TMP_RENDER    "/tmp/agbrowser_render.txt"
#define WGET_TIMEOUT  15

/* ── Globals ────────────────────────────────────────────────────────────────── */
static char  g_url[MAX_URL]            = "";
static char  g_links[MAX_LINKS][MAX_URL];
static char  g_link_text[MAX_LINKS][64];
static int   g_nlinks                  = 0;
static char  g_history[HISTORY_MAX][MAX_URL];
static int   g_hist_pos                = -1;
static int   g_hist_len                = 0;
static int   g_term_rows               = 24;
static int   g_term_cols               = 80;
static char  g_title[256]              = "";

/* ── Terminal size ───────────────────────────────────────────────────────────── */
static void get_term_size(void) {
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_row > 0) {
        g_term_rows = ws.ws_row;
        g_term_cols = ws.ws_col;
    }
}

/* ── URL handling ───────────────────────────────────────────────────────────── */

/* Resolve a relative URL against a base */
static void resolve_url(const char *base, const char *href, char *out, int outlen) {
    if (!href || !href[0]) { strncpy(out, base, outlen-1); return; }

    /* Absolute URL */
    if (strncmp(href, "http://", 7) == 0 || strncmp(href, "https://", 8) == 0) {
        strncpy(out, href, outlen-1);
        out[outlen-1] = '\0';
        return;
    }

    /* Protocol-relative //example.com */
    if (href[0] == '/' && href[1] == '/') {
        const char *proto_end = strstr(base, "://");
        if (proto_end) {
            int plen = proto_end - base + 1;  /* include : */
            snprintf(out, outlen, "%.*s%s", plen, base, href);
        } else {
            snprintf(out, outlen, "https:%s", href);
        }
        return;
    }

    /* Extract base origin (scheme://host) */
    char origin[512] = "";
    const char *s = strstr(base, "://");
    if (s) {
        /* Find end of host (next / after ://) */
        const char *path_start = strchr(s + 3, '/');
        if (path_start) {
            int olen = path_start - base;
            if (olen < (int)sizeof(origin)-1) {
                strncpy(origin, base, olen);
                origin[olen] = '\0';
            }
        } else {
            strncpy(origin, base, sizeof(origin)-1);
        }
    }

    /* Root-relative /path */
    if (href[0] == '/') {
        snprintf(out, outlen, "%s%s", origin, href);
        return;
    }

    /* Relative path: take base directory + href */
    char base_dir[MAX_URL];
    strncpy(base_dir, base, sizeof(base_dir)-1);
    char *slash = strrchr(base_dir, '/');
    if (slash && slash > base_dir + 8) {  /* keep scheme://host/ */
        *(slash+1) = '\0';
    } else {
        strcat(base_dir, "/");
    }
    snprintf(out, outlen, "%s%s", base_dir, href);
}

/* Encode URL for wget (replace spaces) */
static void url_encode_spaces(char *url) {
    char tmp[MAX_URL];
    int j = 0;
    for (int i = 0; url[i] && j < MAX_URL-3; i++) {
        if (url[i] == ' ') { tmp[j++]='%'; tmp[j++]='2'; tmp[j++]='0'; }
        else tmp[j++] = url[i];
    }
    tmp[j] = '\0';
    strncpy(url, tmp, MAX_URL-1);
}

/* ── HTML renderer ──────────────────────────────────────────────────────────── */

/* Decode common HTML entities in-place */
static void decode_entities(char *s) {
    static const struct { const char *ent; char ch; } table[] = {
        {"&amp;",  '&'}, {"&lt;",   '<'}, {"&gt;",   '>'},
        {"&quot;", '"'}, {"&apos;", '\''}, {"&nbsp;", ' '},
        {"&#39;",  '\''}, {"&mdash;", '-'}, {"&ndash;", '-'},
        {"&ldquo;", '"'}, {"&rdquo;", '"'}, {"&lsquo;", '\''},
        {"&rsquo;", '\''}, {"&hellip;", '.'}, {"&copy;", 'c'},
        {"&reg;", 'R'}, {"&trade;", 'T'}, {NULL, 0}
    };
    char out[MAX_LINE * 4];
    int i = 0, j = 0;
    while (s[i] && j < (int)sizeof(out)-1) {
        if (s[i] == '&') {
            int matched = 0;
            for (int k = 0; table[k].ent; k++) {
                int elen = strlen(table[k].ent);
                if (strncasecmp(s+i, table[k].ent, elen) == 0) {
                    out[j++] = table[k].ch;
                    i += elen;
                    matched = 1;
                    break;
                }
            }
            if (!matched) {
                /* Numeric entity &#NNN; */
                if (s[i+1] == '#') {
                    int num = 0;
                    int k = i + 2;
                    if (s[k] == 'x' || s[k] == 'X') {
                        k++;
                        while (isxdigit(s[k])) num = num*16 + (isdigit(s[k]) ? s[k]-'0' : tolower(s[k])-'a'+10), k++;
                    } else {
                        while (isdigit(s[k])) num = num*10 + s[k++]-'0';
                    }
                    if (s[k] == ';') {
                        out[j++] = num < 128 ? (char)num : '?';
                        i = k + 1;
                        matched = 1;
                    }
                }
                if (!matched) out[j++] = s[i++];
            }
        } else {
            out[j++] = s[i++];
        }
    }
    out[j] = '\0';
    strncpy(s, out, MAX_LINE*4-1);
}

/* Render HTML file to text, extracting links into g_links[] */
static int render_html(const char *html_file, const char *out_file, const char *base_url) {
    FILE *in  = fopen(html_file, "r");
    FILE *out = fopen(out_file,  "w");
    if (!in || !out) {
        if (in)  fclose(in);
        if (out) fclose(out);
        return 0;
    }

    g_nlinks = 0;
    g_title[0] = '\0';

    char buf[65536];
    int  n = fread(buf, 1, sizeof(buf)-1, in);
    buf[n] = '\0';
    fclose(in);

    /* ── Pass 1: extract <title> ─────────────────────────────────────────── */
    char *tp = strcasestr(buf, "<title");
    if (tp) {
        tp = strchr(tp, '>');
        if (tp) {
            tp++;
            char *te = strcasestr(tp, "</title>");
            if (te) {
                int tlen = te - tp < (int)sizeof(g_title)-1 ? te - tp : (int)sizeof(g_title)-1;
                strncpy(g_title, tp, tlen);
                g_title[tlen] = '\0';
                decode_entities(g_title);
            }
        }
    }

    /* ── Pass 2: walk through HTML, strip tags, collect links ────────────── */
    int   col        = 0;
    int   in_script  = 0;
    int   in_style   = 0;
    int   in_head    = 0;
    int   last_space = 1;
    int   skip_tag   = 0;

    char  cur_href[MAX_URL] = "";
    int   in_anchor  = 0;
    char  anchor_text[256] = "";
    int   alen = 0;

    int   i = 0;
    while (i < n) {
        if (buf[i] == '<') {
            /* Find end of tag */
            int j = i + 1;
            while (j < n && buf[j] != '>') j++;
            char tag[512];
            int tlen = j - i - 1 < 510 ? j - i - 1 : 510;
            strncpy(tag, buf + i + 1, tlen);
            tag[tlen] = '\0';

            /* Tag name */
            char tagname[64];
            int k = 0;
            while (tag[k] && !isspace(tag[k]) && tag[k] != '/' && k < 63) {
                tagname[k] = tolower(tag[k]); k++;
            }
            tagname[k] = '\0';

            int closing = (tag[0] == '/');
            if (closing) {
                /* Get real name after / */
                k = 1;
                int m = 0;
                while (tag[k] && !isspace(tag[k]) && m < 63) tagname[m++] = tolower(tag[k++]);
                tagname[m] = '\0';
            }

            /* Track script/style blocks */
            if (!closing && strcmp(tagname, "script") == 0) { in_script = 1; i = j+1; continue; }
            if (!closing && strcmp(tagname, "style")  == 0) { in_style  = 1; i = j+1; continue; }
            if (!closing && strcmp(tagname, "head")   == 0) { in_head   = 1; i = j+1; continue; }
            if ( closing && strcmp(tagname, "script") == 0) { in_script = 0; i = j+1; continue; }
            if ( closing && strcmp(tagname, "style")  == 0) { in_style  = 0; i = j+1; continue; }
            if ( closing && strcmp(tagname, "head")   == 0) { in_head   = 0; i = j+1; continue; }

            if (in_script || in_style || in_head) { i = j+1; continue; }

            /* Block elements → newline */
            if (strcmp(tagname, "p")   == 0 || strcmp(tagname, "div") == 0 ||
                strcmp(tagname, "br")  == 0 || strcmp(tagname, "tr")  == 0 ||
                strcmp(tagname, "li")  == 0 || strcmp(tagname, "dt")  == 0 ||
                strcmp(tagname, "dd")  == 0 || strcmp(tagname, "h1")  == 0 ||
                strcmp(tagname, "h2")  == 0 || strcmp(tagname, "h3")  == 0 ||
                strcmp(tagname, "h4")  == 0 || strcmp(tagname, "h5")  == 0 ||
                strcmp(tagname, "h6")  == 0 || strcmp(tagname, "pre") == 0 ||
                strcmp(tagname, "blockquote") == 0) {
                if (col > 0) { fputc('\n', out); col = 0; last_space = 1; }
                if (strcmp(tagname, "h1")==0 || strcmp(tagname,"h2")==0) {
                    if (!closing) { fputs("\n=== ", out); col = 5; }
                    else          { fputs(" ===\n\n", out); col = 0; }
                }
                if (strcmp(tagname, "li")==0 && !closing) {
                    fputs("  • ", out); col = 4;
                }
            }

            /* Anchors */
            if (!closing && strcmp(tagname, "a") == 0) {
                /* Extract href */
                char *hp = strcasestr(tag, "href=");
                if (hp) {
                    hp += 5;
                    char delim = ' ';
                    if (*hp == '"' || *hp == '\'') { delim = *hp; hp++; }
                    int m = 0;
                    while (*hp && *hp != delim && *hp != '>' && m < MAX_URL-1)
                        cur_href[m++] = *hp++;
                    cur_href[m] = '\0';
                    /* skip javascript: and mailto: */
                    if (strncmp(cur_href, "javascript:", 11) != 0 &&
                        strncmp(cur_href, "mailto:",      7) != 0 &&
                        cur_href[0] != '\0') {
                        in_anchor = 1;
                        alen = 0;
                        anchor_text[0] = '\0';
                    }
                }
            }
            if (closing && strcmp(tagname, "a") == 0 && in_anchor) {
                if (g_nlinks < MAX_LINKS && cur_href[0]) {
                    char resolved[MAX_URL];
                    resolve_url(base_url, cur_href, resolved, sizeof(resolved));
                    strncpy(g_links[g_nlinks], resolved, MAX_URL-1);
                    strncpy(g_link_text[g_nlinks], anchor_text, 63);
                    g_link_text[g_nlinks][63] = '\0';
                    /* Print link reference inline */
                    fprintf(out, "[%d]", g_nlinks + 1);
                    col += 4;
                    g_nlinks++;
                }
                in_anchor = 0;
                cur_href[0] = '\0';
            }

            /* Table cells → tab */
            if (strcmp(tagname, "td") == 0 || strcmp(tagname, "th") == 0) {
                fputc('\t', out); col += 4;
            }

            i = j + 1;
            continue;
        }

        /* Text content */
        if (in_script || in_style || in_head) { i++; continue; }

        char c = buf[i++];

        /* Collapse whitespace */
        if (c == '\n' || c == '\r' || c == '\t') c = ' ';
        if (c == ' ' && last_space) continue;

        if (c < 32 && c != '\n') continue;

        /* Decode entity sequences inline */
        if (c == '&') {
            /* peek for entity */
            char ent[16]; int em = 0;
            ent[em++] = '&';
            int k = i;
            while (k < n && buf[k] != ';' && em < 14 && !isspace(buf[k])) ent[em++] = buf[k++];
            if (k < n && buf[k] == ';') {
                ent[em++] = ';'; ent[em] = '\0';
                decode_entities(ent);
                c = ent[0]; i = k + 1;
            }
        }

        /* Word-wrap at terminal width */
        if (c == ' ' && col >= g_term_cols - 2) {
            fputc('\n', out); col = 0; last_space = 1; continue;
        }
        if (col >= g_term_cols - 1 && c != ' ') {
            fputc('\n', out); col = 0;
        }

        fputc(c, out);
        col++;
        last_space = (c == ' ');

        /* Collect anchor text */
        if (in_anchor && alen < 62 && c != '\n') {
            anchor_text[alen++] = c;
            anchor_text[alen] = '\0';
        }
    }

    if (col > 0) fputc('\n', out);
    fclose(out);
    return 1;
}

/* ── Fetch a URL using busybox wget ─────────────────────────────────────────── */
static int fetch_url(const char *url) {
    char cmd[MAX_URL + 256];
    /* -q quiet, -O output file, --no-check-certificate for self-signed */
    snprintf(cmd, sizeof(cmd),
        "wget -q -O '%s' --timeout=%d --no-check-certificate "
        "--user-agent='Agentic/1.0 (terminal browser)' '%s' 2>/dev/null",
        CACHE_FILE, WGET_TIMEOUT, url);
    int r = system(cmd);
    /* Check file exists and is non-empty */
    struct stat st;
    return (r == 0 || (stat(CACHE_FILE, &st) == 0 && st.st_size > 0)) ? 1 : 0;
}

/* ── History management ─────────────────────────────────────────────────────── */
static void history_push(const char *url) {
    if (g_hist_len > 0 && strcmp(g_history[g_hist_pos], url) == 0) return;
    g_hist_pos++;
    if (g_hist_pos >= HISTORY_MAX) g_hist_pos = 0;
    strncpy(g_history[g_hist_pos], url, MAX_URL-1);
    g_hist_len = g_hist_pos + 1;
}

/* ── Display page ───────────────────────────────────────────────────────────── */
static void display_page(int start_line) {
    FILE *f = fopen(TMP_RENDER, "r");
    if (!f) { printf("(render failed)\n"); return; }

    /* Clear screen */
    printf("\033[2J\033[H");

    /* Status bar */
    char short_url[80];
    strncpy(short_url, g_url, 79);
    if (strlen(g_url) > 72) { short_url[70] = '.'; short_url[71] = '.'; short_url[72] = '\0'; }
    printf("\033[7m %-*s \033[0m\n", g_term_cols-2, g_title[0] ? g_title : g_url);
    printf("\033[2m %s \033[0m\n", short_url);

    /* Page content */
    char line[MAX_LINE];
    int  ln = 0;
    int  shown = 0;
    int  page_h = g_term_rows - 5;

    while (fgets(line, sizeof(line), f)) {
        if (ln++ < start_line) continue;
        if (shown >= page_h) break;

        /* Highlight link numbers [N] */
        char *p = line;
        while (*p) {
            if (*p == '[' && isdigit(*(p+1))) {
                printf("\033[36m");  /* cyan */
                while (*p && *p != ']') putchar(*p++);
                if (*p == ']') { putchar(*p++); }
                printf("\033[0m");
            } else {
                putchar(*p++);
            }
        }
        shown++;
    }
    fclose(f);

    /* Bottom bar */
    printf("\033[7m");
    int has_more = (shown >= page_h);
    if (has_more) printf(" [SPACE=next page] ");
    else          printf(" [END OF PAGE]     ");
    printf("[NUM=follow link] [u=URL] [b=back] [q=quit] ");
    int blen = has_more ? 19 : 19;
    int remaining = g_term_cols - blen - 48;
    for (int i = 0; i < remaining && i < 20; i++) putchar(' ');
    printf("\033[0m");
    fflush(stdout);
}

/* ── Count lines in render file ─────────────────────────────────────────────── */
static int count_lines(void) {
    FILE *f = fopen(TMP_RENDER, "r");
    if (!f) return 0;
    int count = 0;
    char line[MAX_LINE];
    while (fgets(line, sizeof(line), f)) count++;
    fclose(f);
    return count;
}

/* ── Load and display a URL ─────────────────────────────────────────────────── */
static int load_url(const char *url) {
    strncpy(g_url, url, MAX_URL-1);
    printf("\033[2J\033[H");
    printf("Loading: %s\n", url);
    fflush(stdout);

    if (!fetch_url(url)) {
        printf("\n[browser] failed to fetch: %s\n", url);
        printf("Check network connection. Press Enter to continue.\n");
        getchar();
        return 0;
    }

    render_html(CACHE_FILE, TMP_RENDER, url);
    history_push(url);
    return 1;
}

/* ── Raw terminal input (single keypress) ───────────────────────────────────── */
static struct termios g_orig_term;
static void term_raw(void) {
    struct termios t;
    tcgetattr(STDIN_FILENO, &g_orig_term);
    t = g_orig_term;
    t.c_lflag &= ~(ICANON | ECHO);
    t.c_cc[VMIN] = 1; t.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSANOW, &t);
}
static void term_restore(void) {
    tcsetattr(STDIN_FILENO, TCSANOW, &g_orig_term);
}

/* ── Show link list ─────────────────────────────────────────────────────────── */
static void show_links(void) {
    printf("\033[2J\033[H");
    printf("Links on this page (%d total):\n\n", g_nlinks);
    int show = g_nlinks < 30 ? g_nlinks : 30;
    for (int i = 0; i < show; i++) {
        char short_link[60];
        strncpy(short_link, g_links[i], 59);
        printf("  \033[36m[%2d]\033[0m %-25s  %s\n",
            i+1,
            g_link_text[i][0] ? g_link_text[i] : "(link)",
            short_link);
    }
    printf("\nEnter number (or press Enter to go back): ");
    fflush(stdout);
}

/* ── Main ───────────────────────────────────────────────────────────────────── */
int main(int argc, char *argv[]) {
    get_term_size();

    /* Homepage */
    const char *start_url = argc > 1 ? argv[1] : "https://lite.duckduckgo.com/lite/";

    /* Add https:// if missing */
    char url_buf[MAX_URL];
    if (argc > 1 && strncmp(argv[1], "http", 4) != 0) {
        snprintf(url_buf, sizeof(url_buf), "https://%s", argv[1]);
        start_url = url_buf;
    }

    if (!load_url(start_url)) {
        /* Try DuckDuckGo lite as fallback */
        if (strcmp(start_url, "https://lite.duckduckgo.com/lite/") != 0)
            load_url("https://lite.duckduckgo.com/lite/");
    }

    term_raw();
    atexit(term_restore);

    int  cur_line  = 0;
    int  total_lines = count_lines();
    int  in_links_view = 0;
    char link_num_buf[8];
    int  lnb_pos = 0;

    display_page(cur_line);

    while (1) {
        char c = getchar();

        if (in_links_view) {
            /* Collecting link number */
            if (c == '\n' || c == '\r') {
                in_links_view = 0;
                if (lnb_pos > 0) {
                    link_num_buf[lnb_pos] = '\0';
                    int num = atoi(link_num_buf);
                    if (num > 0 && num <= g_nlinks) {
                        term_restore();
                        load_url(g_links[num-1]);
                        term_raw();
                        cur_line = 0;
                        total_lines = count_lines();
                    }
                }
                lnb_pos = 0;
                display_page(cur_line);
                continue;
            }
            if (isdigit(c) && lnb_pos < 4) {
                link_num_buf[lnb_pos++] = c;
                putchar(c); fflush(stdout);
            }
            if (c == 27 || c == 'q') { in_links_view = 0; lnb_pos = 0; display_page(cur_line); }
            continue;
        }

        int page_h = g_term_rows - 5;

        if (c == 'q' || c == 'Q') break;

        if (c == ' ' || c == 'f' || c == 'F') {
            /* Next page */
            if (cur_line + page_h < total_lines) {
                cur_line += page_h;
                display_page(cur_line);
            }
            continue;
        }
        if (c == 'p' || c == 'b' && c != 'b') {
            /* Prev page */
            cur_line -= page_h;
            if (cur_line < 0) cur_line = 0;
            display_page(cur_line);
            continue;
        }
        /* Arrow keys / scroll */
        if (c == 'j' || c == '\x0e') { /* down */
            if (cur_line + 1 < total_lines) { cur_line++; display_page(cur_line); }
            continue;
        }
        if (c == 'k' || c == '\x10') { /* up */
            if (cur_line > 0) { cur_line--; display_page(cur_line); }
            continue;
        }
        if (c == 'g') { cur_line = 0; display_page(cur_line); continue; }
        if (c == 'G') { cur_line = total_lines - page_h; if (cur_line < 0) cur_line=0; display_page(cur_line); continue; }

        /* Back */
        if (c == 'b') {
            if (g_hist_pos > 0) {
                g_hist_pos--;
                term_restore();
                load_url(g_history[g_hist_pos]);
                term_raw();
                cur_line = 0;
                total_lines = count_lines();
                display_page(cur_line);
            }
            continue;
        }

        /* Links list */
        if (c == 'l' || c == 'L') {
            term_restore();
            show_links();
            term_raw();
            in_links_view = 1;
            lnb_pos = 0;
            continue;
        }

        /* Direct number → follow link */
        if (isdigit(c) && c != '0') {
            link_num_buf[0] = c;
            lnb_pos = 1;
            term_restore();
            printf("\n\033[7m Follow link: \033[0m %c", c);
            fflush(stdout);
            term_raw();
            in_links_view = 1;
            continue;
        }

        /* URL entry */
        if (c == 'u' || c == 'o' || c == '\n') {
            term_restore();
            printf("\n\033[7m URL: \033[0m ");
            fflush(stdout);
            char new_url[MAX_URL];
            if (fgets(new_url, sizeof(new_url), stdin)) {
                /* strip newline */
                new_url[strcspn(new_url, "\r\n")] = '\0';
                if (new_url[0]) {
                    char full_url[MAX_URL];
                    if (strncmp(new_url, "http", 4) != 0)
                        snprintf(full_url, sizeof(full_url), "https://%s", new_url);
                    else
                        strncpy(full_url, new_url, MAX_URL-1);
                    load_url(full_url);
                    cur_line = 0;
                    total_lines = count_lines();
                }
            }
            term_raw();
            display_page(cur_line);
            continue;
        }

        /* Reload */
        if (c == 'r' || c == 'R') {
            term_restore();
            load_url(g_url);
            term_raw();
            cur_line = 0;
            total_lines = count_lines();
            display_page(cur_line);
            continue;
        }

        /* Search (DuckDuckGo lite) */
        if (c == '/' || c == 's') {
            term_restore();
            printf("\n\033[7m Search: \033[0m ");
            fflush(stdout);
            char query[256];
            if (fgets(query, sizeof(query), stdin)) {
                query[strcspn(query, "\r\n")] = '\0';
                if (query[0]) {
                    /* URL-encode spaces */
                    char search_url[MAX_URL];
                    char encoded[512]; int ej = 0;
                    for (int i = 0; query[i] && ej < 500; i++) {
                        if (query[i] == ' ') { encoded[ej++]='%'; encoded[ej++]='2'; encoded[ej++]='0'; }
                        else if (isalnum(query[i]) || query[i]=='-' || query[i]=='_') encoded[ej++]=query[i];
                        else { sprintf(encoded+ej, "%%%02X", (unsigned char)query[i]); ej+=3; }
                    }
                    encoded[ej] = '\0';
                    snprintf(search_url, sizeof(search_url),
                        "https://lite.duckduckgo.com/lite/?q=%s", encoded);
                    load_url(search_url);
                    cur_line = 0;
                    total_lines = count_lines();
                }
            }
            term_raw();
            display_page(cur_line);
            continue;
        }

        /* Help */
        if (c == '?') {
            term_restore();
            printf("\033[2J\033[H");
            printf("Agentic Browser — Keyboard Shortcuts\n\n");
            printf("  SPACE / f    next page\n");
            printf("  j / n        scroll down one line\n");
            printf("  k            scroll up one line\n");
            printf("  g / G        top / bottom\n");
            printf("  b            back in history\n");
            printf("  l            show all links\n");
            printf("  1-9          follow link number\n");
            printf("  u / o        enter URL\n");
            printf("  /  or  s     search DuckDuckGo\n");
            printf("  r            reload page\n");
            printf("  q            quit\n\n");
            printf("Press any key to continue...");
            fflush(stdout);
            term_raw();
            getchar();
            display_page(cur_line);
            continue;
        }

        /* Escape sequence (arrow keys) */
        if (c == 27) {
            char c2 = getchar();
            if (c2 == '[') {
                char c3 = getchar();
                if (c3 == 'A') { /* up */ if (cur_line>0){cur_line--;display_page(cur_line);} }
                if (c3 == 'B') { /* down */ if(cur_line+1<total_lines){cur_line++;display_page(cur_line);} }
                if (c3 == '5') { getchar(); cur_line-=page_h; if(cur_line<0)cur_line=0; display_page(cur_line); }
                if (c3 == '6') { getchar(); if(cur_line+page_h<total_lines)cur_line+=page_h; display_page(cur_line); }
            }
            continue;
        }
    }

    term_restore();
    printf("\033[2J\033[H");
    printf("Exiting browser.\n");

    /* Cleanup */
    unlink(CACHE_FILE);
    unlink(TMP_RENDER);
    return 0;
}
