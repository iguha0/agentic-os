# Agentic OS v0.2.0-beta — Release Notes

**Branch:** `beta-release` · **Date:** 2026-08-24 · **Status: BETA**

The home screen is an agent. The phone is a server.

---

## What shipped in v0.2.0-beta

### 1. Agent has real internet (fixed)
The VM previously booted a stale image and the agent couldn't act online.
- Rebuilt initramfs pipeline (`scripts/install-rootfs.sh` + `scripts/mkinitramfs.sh`) — no more drift between source and image
- `!net` / `TOOL:net_check`: layered diagnostics (interface → gateway → ICMP → DNS → HTTP → HTTPS → SearXNG → llama)
- Search fallback chain: on-device SearXNG → DuckDuckGo Lite → DDG instant answers
- `web_read`, `weather`, TLS+CA verified working in-guest

### 2. AgentoNet — share from your phone, your phone is the server
- **`agrelay.py`**: blind-pipe relay (long-poll tunnel; stateless, self-hostable, stdlib-only). Relay never sees or stores content.
- **`agtunnel.sh`**: device-side tunnel client, pure busybox (wget + sh). Short-poll design survives NAT/idle drops; self-reporting heartbeats.
- Three share modes, all gate-tested end-to-end:
  - 🌐 **Public** — link anyone can fetch
  - 🎟 **Restricted/Selective** — per-person tokens with expiry + max-download caps + revoke
  - 🔐 **Private** — E2E encrypted via **libsodium crypto_box_seal** (X25519 + XSalsa20-Poly1305); only the recipient's key can open
- Per-share access logs; CID = sha256(content)

### 3. AgentoNet Search
- **DHT index node** (`dht-node.py`): metadata-only records, gossip replication, TTL expiry
- Shares publish automatically to the index; `netsearch <query>` builtin + web app query it
- Round-trip verified: publish from guest → discover by keyword → fetch through relay

### 4. Premium phone-OS UI
- Hero clock, app grid, glass dock — feels like a phone home screen now
- New **Share app**: create/list/revoke shares, all three modes
- New **Net Search app**: search everything shared publicly on AgentoNet
- Upgraded chat: typing indicator, tool-activity chips, quick actions
- Live status bar: network / AI / node identity / tunnel state
- New CGI endpoints: `share_list.sh`, `share_create.sh`, `share_revoke.sh`, `netsearch.sh`

### 5. Stability
- Fixed kernel panic on shell exit (PID1 respawn loop)
- Fresh text **and** graphical initramfs rebuilt; graphical boot verified through Chromium-kiosk focus

---

## Running the beta

```bash
# text mode (fastest)
./test-interactive.sh            # then open http://localhost:<port> for the web UI

# graphical mode (flagship)
./create-data-disk.sh            # once, for persistent memory/identity
./launch-graphical.sh            # QEMU window: kiosk home + xterm agent shell

# host-side infra (relay + DHT) — run on any machine incl. the Mac
python3 net/relay/agrelay.py --port 7075 --host 0.0.0.0 &
python3 net/search/dht-node.py --port 8889 &

# inside the OS
!net                     # connectivity matrix
share a file             # via Share app, or: agentic-shared share /path public
netsearch photos         # search shared content
```

## Known limitations (beta)
- Relay/DHT bootstrap default to the developer Mac (`10.0.2.2`) — production domains TBD
- Private-share recipient flow is CLI-level (`agseal open`) — UI decrypt lands post-beta
- SearXNG ships only in the graphical image (text mode falls back to DDG chain)
- Nostr/Lightning helpers remain prototypes
- libsodium static lib must be rebuilt with GNU ar for linking (see `prebuilt/agseal`)

## Verification summary (all automated, expect-driven QEMU boots)
| Test | Result |
|---|---|
| Guest network stack (ICMP/DNS/HTTP/HTTPS) | PASS |
| `!net` diagnostics matrix | PASS |
| Agent weather / web_read | PASS |
| Public share fetch via relay | PASS |
| Token gating (403 / 200 / 429-limit) | PASS |
| Private E2E sealed-box round-trip | PASS |
| DHT publish → search → result | PASS |
| Web UI CGI surface (status/share/netsearch/chat) | PASS |
| Exit → respawn (no kernel panic) | PASS |
| Graphical boot → kiosk focused | PASS |
