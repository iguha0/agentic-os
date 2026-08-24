# PryzentOS v0.2.0-beta — Release Notes

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

## Day-2 additions (same beta branch)

### Private-share full flow (was CLI-only)
- `open <link>` (shell builtin + /usr/local/bin/open) and Share-app card:
  fetch → E2E-decrypt → `/usr/share/agentic/inbox/`
- Agent tool: `TOOL:open_share url=…`

### Nostr is real now (was prototype)
- Pure-stdlib BIP340 secp256k1 Schnorr (`net/nostr/bip340.py`)
- Device nostr identity (`identity/nostr.key|pub`), canonical NIP-01 events
- **Live-verified**: post accepted by nos.lol / primal / offchain / nostr.mom /
  snort / wellorder; independently fetched back from nos.lol
- Text mode degrades honestly (signing needs python3 → graphical image)

### Lightning receive is real now (was prototype)
- Full LNURL-pay (LUD-01/06/16): lightning address → params → callback → BOLT11
- Live-verified against getalby.com (100-sat & 21-sat invoices)
- `zap <sats>` builtin/CLI, `TOOL:request_payment`, Settings ⚡ card (+SVG QR when py3-qrcode present), tip-url on public shares

### Apps, sessions & store
- Persistent Chromium profile per device ⇒ agent can act on user's logged-in sessions via CDP tools
- "＋ Add App": any site becomes a home-screen app backed by that session
- F-Droid catalogue search + APK download-to-inbox (take-away artifacts;
  no Android runtime by design)

### Search hardening
- botasaurus-inspired fallbacks: rotating UAs + Wikipedia opensearch merge
- SearXNG remains the premium engine (graphical image)

## Known limitations (beta)
- Relay/DHT bootstrap defaults to the developer Mac (`10.0.2.2`) — configurable
  via env (`AGENTOS_RELAY_URL`, `AGENTOS_DHT_NODES`); production domains TBD
- Invoice QR renders only where py3-qrcode exists (graphical); text mode shows the bolt11 string
- Nostr signing needs python3 (graphical image)
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
| Two independent VMs: DHT discovery + relay transfer | PASS |
| Private-share open flow (VM as recipient) | PASS |
| Nostr post accepted by 6 live relays + fetch-back | PASS |
| Lightning invoice via getalby LNURLp (host + in-guest zap) | PASS |
| App create/list round-trip + F-Droid live search in-guest | PASS |

---

## License

PryzentOS — Copyright (C) Indrajit Guha — **AGPL-3.0** (see [LICENSE](LICENSE)).
Model weights (Qwen2.5) are Apache-2.0, fetched separately via `download-model.sh`.
