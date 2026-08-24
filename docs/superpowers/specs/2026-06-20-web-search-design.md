# Web Search for PryzentOS — Design Spec

**Date:** 2026-06-20
**Status:** Approved (design), pending implementation plan
**Scope:** Subsystem A of three (web search). Subsystems B (credential vault) and
C (act-on-behalf task execution) are explicitly **out of scope** here and get
their own spec → plan → build cycles.

## 1. Goal

Give the agent real, Google-quality web search and the ability to read a chosen
result page — fully self-contained inside the QEMU guest, with **no dependency on
the Mac host**. Replace the current weak `web_search` tool, which only hits
DuckDuckGo's instant-answer API via `wget | grep AbstractText`
(`shell/ai_client.c:252`).

## 2. Constraints & principles

- **Standalone OS.** Everything runs in-guest. Nothing may depend on a service
  running on the developer's Mac (unlike the current `llama-server` host
  fallback at `10.0.2.2:8080`). This mirrors the in-guest llama-server the boot
  already starts on `127.0.0.1:8080`.
- **No Python on the per-command path.** The shell, browser, and httpd are C.
  Per-tool-call work must not spawn an interpreter. The only Python permitted is
  the SearXNG daemon, whose interpreter cost is paid **once at boot** and
  amortized across the session — identical to the trade already accepted for
  llama-server.
- **Graphical mode only.** SearXNG and its deps live in `rootfs-graphical`,
  which has Python 3.11 + openssl. The text rootfs (busybox `wget` only) is not
  targeted; in text mode the tools degrade gracefully (see §7).
- **Public results only.** No login-gated search, no credentials. That is
  subsystem B/C.

## 3. Architecture

```
agentic-init.sh ──(at boot, after llama-server, graphical mode)──► searxng on 127.0.0.1:8888
                                                                          ▲
                                                                          │ GET /search?format=json
shell (agentic-shell2) ─► ai_client.c tool_dispatch ─► web_search (C)  ───┘
                                                     └► web_read   (C)  ───► GET <url> (wget+TLS)
```

Two moving parts:

1. **SearXNG** — a long-lived metasearch daemon started once at boot.
2. **`web_search` / `web_read`** — C tool handlers compiled into the shell. No
   helper scripts, no per-command process spawn beyond the existing `wget`.

## 4. Components

### 4.1 SearXNG boot service

- **Location:** vendored into `rootfs-graphical` at `/opt/searxng` (Python venv).
- **Config:** `/etc/searxng/settings.yml`
  - `server.bind_address: 127.0.0.1`, `server.port: 8888`
  - `server.secret_key:` generated at boot if absent (see init block)
  - `server.limiter: false` (single local user, no bot-rate-limiting)
  - `search.formats: [json, html]` (json is what the tools consume)
  - `redis.url: false` (no Redis/Valkey dependency)
  - **Engines:** Google (primary) + Bing + Brave + DuckDuckGo enabled. SearXNG's
    multi-engine aggregation is the whole point: when Google rate-limits the
    single guest IP, results still come from the others.
- **Startup:** new `start_searxng()` block in `init/agentic-init.sh`, invoked in
  graphical mode right after the llama-server block. Behavior mirrors
  llama-server exactly:
  - generate `secret_key` into settings if missing (busybox `head -c 32
    /dev/urandom | hexdump`-style, or `openssl rand -hex 32`)
  - launch the venv's searxng (`/opt/searxng/bin/python -m searx.webapp` or the
    granian/uwsgi entrypoint chosen at build time) in the background
  - poll `http://127.0.0.1:8888/healthz` (or `/` if no health route) with a
    **bounded** timeout, logging to `/tmp/searxng.log`
  - **non-fatal:** if it never comes up, boot continues; search just reports
    unavailable. The shell must never block on it.

### 4.2 `web_search` (C, in `ai_client.c`)

- Triggered by `[TOOL:web_search query=<query>]` (already in the tool grammar).
- Implementation: replace the current DuckDuckGo block at `ai_client.c:252`.
- **Transport:** `wget` via `popen` (consistent with all existing HTTP in this
  file). URL: `http://127.0.0.1:8888/search?q=<urlenc>&format=json`.
- **Parse:** hand-parse the JSON `results` array for `title`, `url`, `content`
  (snippet), using the same manual-scan technique already used for llama-server
  and Anthropic responses (`ai_client.c:435`, `:513`). Return the **top 5** as:
  ```
  1. <title>
     <url>
     <snippet>
  ```
- **URL-encoding:** the query must be percent-encoded before substitution
  (space → `%20`, etc.) — a small C helper, since queries are free text.
- **Pluggable backend (config-driven, future-proof, no rewrite later):** read
  `/usr/share/agentic/search.conf` if present:
  - `backend=searxng` (default) → local SearXNG as above
  - `backend=serpapi` + `api_key=…` → `https://serpapi.com/search.json?...`
  - `backend=google_cse` + `api_key=…` + `cx=…` → Google CSE JSON API
  This is the upgrade path for when/if local scraping gets blocked; the JSON
  shapes differ per backend but the parse-and-format step is shared.

### 4.3 `web_read` (C, in `ai_client.c`)

- New tool: `[TOOL:web_read url=<url>]`. Single-purpose sibling — the agent
  searches, sees snippets, then reads a chosen result.
- **Transport:** `wget` via `popen` (needs TLS for external `https://` pages;
  already works in this image — the Anthropic call uses it).
- **HTML→text:** ~40-line C tag-stripper: drop everything between `<` and `>`,
  skip the contents of `<script>`/`<style>` blocks, decode a handful of common
  entities (`&amp; &lt; &gt; &quot; &#39;`), collapse runs of whitespace.
- **Caps:** request timeout 5s; truncate output to ~3 KB so it fits the model
  context; binary/oversized pages truncated, not streamed.

### 4.4 Tool grammar + system prompt

- Update `SYSTEM_PROMPT` in `ai_client.c:24` to document:
  - `[TOOL:web_search query=<query>]` — search the web (already listed)
  - `[TOOL:web_read url=<url>]` — read a result page (new)
- No change to `tool_dispatch`'s dispatch mechanism; just the two branches.

## 5. Build / packaging

- **`build-graphical-rootfs.sh`:**
  - install SearXNG into `/opt/searxng` venv. Use Alpine `apk` for C-extension
    deps that must match musl/aarch64 (`py3-lxml`, `py3-babel`, `py3-yaml`),
    then `pip` inside the venv for SearXNG itself and pure-Python deps.
  - write the base `/etc/searxng/settings.yml` (secret left blank, filled at
    boot).
- **No new files in `/usr/local/bin`** — the tools are compiled into the shell,
  not scripts.
- **`init/agentic-init.sh`:** add `start_searxng()` and call it in the graphical
  path after llama-server.

## 6. Data flow (happy path)

1. User: "search for the latest news on X" → model emits
   `[TOOL:web_search query=latest news on X]`.
2. `tool_dispatch` → `web_search` → `wget` GET `127.0.0.1:8888/search?...&format=json`.
3. SearXNG queries Google/Bing/Brave, returns aggregated JSON.
4. C parses top 5 results → formatted string → returned to the model as the tool
   result.
5. (Optional) model picks a URL → `[TOOL:web_read url=…]` → `web_read` fetches +
   strips to text → returned to the model, which summarizes for the user.

## 7. Error handling

- **SearXNG not ready / network down:** `web_search` returns a friendly
  "search unavailable (is the network up?)" string within the `wget` timeout
  (2–5s). Never hangs.
- **No results:** explicit "no results found" message.
- **Boot poll fails:** non-fatal; shell boots normally; search reports
  unavailable until/unless the daemon recovers.
- **`web_read` on a bad/huge/binary URL:** timeout + truncate; return whatever
  readable text was obtained, or a clear error.
- **Text (non-graphical) mode:** SearXNG isn't present; `web_search` detects the
  connection failure to `:8888` and, if a `search.conf` API-key backend is
  configured, falls back to it; otherwise reports unavailable.

## 8. Testing

- **Host-side unit tests** of the pure C logic: the JSON result extractor and
  the HTML→text stripper, fed fixture strings (no network). These are the parts
  with real parsing logic.
- **In-VM smoke test** via `test-interactive.sh`:
  1. boot graphical mode, confirm `127.0.0.1:8888` answers `/search?...&format=json`
  2. run `[TOOL:web_search query=...]` end-to-end, verify formatted results
  3. run `[TOOL:web_read url=...]` on a known-simple page, verify readable text
- **Boot resilience:** confirm that killing/omitting SearXNG still lets the shell
  boot and that `web_search` reports unavailable rather than hanging.

## 9. Out of scope (YAGNI)

- Credential storage / login-gated search (subsystem B).
- Browser-automation "act on my behalf" tasks (subsystem C).
- Raw-`socket()` transport for the local SearXNG call (a future micro-opt that
  removes one `fork` per search; `wget`+`popen` is the chosen baseline).
- Result caching, pagination beyond top-5, image/video/news verticals.

## 9b. As-built (implemented 2026-06-20)

The design above predates reading the graphical shell. Corrections made during
implementation (all verified in a headless QEMU boot):

- **Edit target is `shell2/agentic-shell2.c`**, not `ai_client.c`. The graphical
  shell (`/bin/agentic-shell2`, launched by `start_graphical_home`) is
  self-contained with its own tool dispatch. Grammar is `TOOL:search query=…`
  and the new `TOOL:web_read url=…` (no `[ ]` brackets). `ai_client.c` is the
  text-mode shell and was left unchanged.
- **Transport for search is a raw socket**, not `wget`. Reused the file's
  existing client style as a new `http_get()` (read timeout 25s — the first
  metasearch fan-out is slow). `web_read` uses `wget` via `popen` for TLS.
- **Parser:** `json_str_after()` + `url_encode()` + `html_to_text()` are new C
  helpers. Host-side unit test: `/tmp/test_search.c` (kept out of the repo).
- **Build (`build-graphical-rootfs.sh`)**: SearXNG venv at `/opt/searxng`. Build
  toolchain + python go in the **container** (not `--root /rootfs`); only
  runtime libs (`libxml2 libxslt libffi yaml`) go into the image. Install order:
  `requirements.txt` first, then the package `--no-build-isolation` (SearXNG
  imports itself during build). The binary `rootfs/bin/agentic-shell2` is the
  source the rebuild copies — install there, not just `rootfs-graphical/`.
- **Init (`rootfs/init`, the file actually packed):** `start_searxng()` runs in
  the graphical path, generates the secret, launches
  `/opt/searxng/bin/python -m searx.webapp`, polls `/healthz`, non-fatal.

### Four gotchas that each blocked startup (all fixed)
1. **`KeyError: 'PATH'`** — PID1 has no `PATH`; SearXNG reads `os.environ["PATH"]`
   at import. Fix: pass `PATH=…` on the launch line in `start_searxng`.
2. **`FileNotFoundError` for git** — `searx/version.py` shells out to `git` at
   import. Fix: write `searx/version_frozen.py` during build.
3. **All engines `timeout`, `results: []`** — default ~3s outgoing timeout is too
   short through QEMU NAT under emulation. Fix: `outgoing.request_timeout: 12.0`
   in `settings.yml`.
4. **Shell parsed 0 results** — SearXNG (`json.dumps`) emits `"key": "value"`
   with a space after the colon; the parser needles assumed none. Fix:
   `json_str_after` tolerates whitespace after `:`. (The unit test had used
   compact JSON and missed this.)

## 10. Open follow-ups (not blocking)

- Exact SearXNG entrypoint/server (`granian` vs `uwsgi` vs `python -m
  searx.webapp`) to be pinned during the build step based on what installs
  cleanly on the Alpine/musl image.
- Memory/RAM headroom in the VM with llama + Chromium + SearXNG all resident —
  measure during implementation; SearXNG idle footprint is modest but worth
  confirming on the target VM size.
