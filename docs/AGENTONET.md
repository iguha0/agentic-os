# AgentoNet — Architecture & Protocol Spec
# Agentic OS v0.1 — Decentralized Sharing Layer

## Philosophy

Your device is the server. Content never leaves your hands.
A relay is just a pipe. The search index stores metadata, never files.
The AI agent manages everything through natural language.

---

## System Map

```
┌─────────────────────────────────────────────────────────┐
│                    YOUR DEVICE                          │
│                                                         │
│  ┌──────────────┐    ┌───────────────────────────────┐  │
│  │ AI Agent     │───▶│ agentic-shared (daemon)       │  │
│  │ (shell-ai.c) │    │  - serves files via HTTP      │  │
│  │              │    │  - manages access tokens      │  │
│  │ "share X     │    │  - tracks who accessed what   │  │
│  │  with Y"     │    │  - encrypts for private share │  │
│  └──────────────┘    └──────────────┬────────────────┘  │
│                                     │                   │
└─────────────────────────────────────┼───────────────────┘
                                      │ HTTP (tunneled)
                    ┌─────────────────▼─────────────────┐
                    │         RELAY SERVER               │
                    │  (agentic-relay — just a pipe)     │
                    │  - TCP tunnel only                 │
                    │  - never reads content             │
                    │  - open source, self-hostable      │
                    │  - stateless, no storage           │
                    └─────────────────┬─────────────────┘
                                      │
               ┌──────────────────────┼──────────────────────┐
               │                      │                      │
        ┌──────▼──────┐       ┌───────▼─────┐      ┌────────▼────┐
        │  Recipient  │       │  Recipient  │      │  Recipient  │
        │  (anyone    │       │  (token     │      │  (encrypted │
        │   public)   │       │   holder)   │      │   key only) │
        └─────────────┘       └─────────────┘      └─────────────┘
             PUBLIC              SELECTIVE            PRIVATE

                    ┌─────────────────────────────────┐
                    │         DHT NODES               │
                    │  (distributed search index)     │
                    │  - stores metadata only         │
                    │  - CID → relay URL mapping      │
                    │  - title, type, size, owner     │
                    │  - signed by device key         │
                    └─────────────────────────────────┘
```

---

## Content Addressing

Every shared item gets a **Content ID (CID)**:

```
CID = sha256(file_bytes) → hex string
```

The CID is permanent. If the file changes, the CID changes (new share).
This means links are content-addressed — the URL proves what you're getting.

Share URL format:
```
agento://<mode>/<node_id>/<cid>/<filename>
HTTP:   https://<relay>/<mode>/<node_id>/<cid>/<filename>
```

---

## Three Access Modes

### 1. PUBLIC
```
agento://pub/<node_id>/<cid>/<filename>
```
- No authentication required
- Discoverable in search index
- Relay routes anyone with the link directly to device
- Device can set rate limits and download caps

### 2. SELECTIVE
```
agento://sel/<node_id>/<cid>/<token>/<filename>
```
- Requires a valid access token
- Token is generated per-recipient or per-group
- Token can expire: `?expires=2026-12-31`
- Token can have download limit: `?max_downloads=10`
- Revocable at any time ("stop sharing with Rahul")

Token format (signed JWT-like):
```json
{
  "cid": "sha256:abc123...",
  "node": "node_deadbeef",
  "recipient": "rahul@agentic",
  "issued": 1749820800,
  "expires": null,
  "max_dl": null,
  "sig": "<node_private_key_signature>"
}
```

### 3. PRIVATE (one-to-one)
```
agento://prv/<node_id>/<cid>/<encrypted_key_bundle>
```
- File encrypted with recipient's public key (NaCl box)
- Even the relay sees only ciphertext
- Key bundle contains the symmetric key, encrypted for recipient
- No metadata in DHT — completely invisible to search

---

## The Relay Server

**What it does:**
- Accepts WebSocket connections from devices (persistent tunnel)
- Routes incoming HTTP requests to the right device tunnel
- Never buffers more than one TCP packet of content
- Stateless — restarts lose no data (devices reconnect)

**What it does NOT do:**
- Store files (not even temporarily)
- Log request content
- Know what files are being shared
- Require account creation

**Relay routing:**
```
Client GET /<mode>/<node_id>/<cid>/<filename>
  → Relay looks up node_id in connection table
  → Forwards request over WebSocket tunnel to device
  → Streams response back to client
  → Closes connection
```

**Self-hostable.** Anyone can run `relay/relay-server.py` on a $5 VPS.
Public relay: `relay.agentos.dev` (operated by project, open source)

---

## DHT Search Index

For PUBLIC shares only. Devices gossip small metadata records:

```json
{
  "cid":       "sha256:abc123...",
  "node_id":   "node_deadbeef",
  "relay_url": "https://relay.agentos.dev",
  "title":     "Sunset photos from Goa",
  "type":      "image/jpeg",
  "size_kb":   4200,
  "tags":      ["photo", "travel", "goa"],
  "published": 1749820800,
  "sig":       "<node_private_key_signature>"
}
```

**How it spreads:**
1. Device publishes record to 3 known bootstrap nodes
2. Bootstrap nodes gossip to their peers
3. Each node stores up to 10,000 records (tiny — ~10MB total)
4. Records expire after 30 days unless re-published
5. Device re-publishes every 24h while share is active

**Search query:**
```
GET /search?q=goa+photos&type=image&limit=20
```
Returns ranked list of metadata records. Client then fetches
content directly from the device via relay.

**AI-powered search:**
The local model on your device can do semantic search over
cached metadata. "show me hiking videos" matches
"trail run footage from Manali" even without exact keywords.

---

## Node Identity

Each device generates a keypair at first boot:
```
node_keypair = ed25519.generate()
node_id      = sha256(public_key)[:16]  → "node_deadbeef12"
```

Keypair stored at `/usr/share/agentic/identity/`
- `node.key`  — private key (never leaves device)
- `node.pub`  — public key (shared freely)
- `node.id`   — node_id string

People share public keys via QR codes or `agento://id/<node_id>/<pub_key_b64>`

---

## Offline Behavior

When your device is offline, public shares show:
```
This content is temporarily offline.
Owner: Indrajit  |  Last seen: 2 hours ago
Content: "Sunset photos from Goa" (4.2 MB, 12 files)
[Notify me when online]
```

**Optional trusted-peer caching:**
You can designate up to 3 trusted peers (friends' devices) who will
temporarily cache your public shares when you go offline.
Cache expires 48h after you come back online.
You control this: `"let Rahul cache my public shares"`

---

## Agent Commands (Natural Language → Protocol)

```
"share this photo with everyone"
  → mode=PUBLIC, index in DHT, return link

"share this doc only with Rahul and Priya"
  → mode=SELECTIVE, generate 2 tokens, share via message

"share my portfolio privately with the hiring manager"
  → mode=PRIVATE, exchange keys, encrypt, send bundle

"who accessed my Goa photos?"
  → read access log from agentic-shared

"stop sharing with Rahul"
  → revoke Rahul's token

"take down the Goa photos from public"
  → remove from DHT, close public route

"make this available only until Friday"
  → set expiry on token/share

"share this folder — family only, no downloads"
  → mode=SELECTIVE, view-only flag (serve inline, no Content-Disposition)
```

---

## File Layout on Device

```
/usr/share/agentic/
├── identity/
│   ├── node.key          # private key
│   ├── node.pub          # public key
│   └── node.id           # node_id string
├── shares/
│   ├── index.json        # all active shares
│   ├── tokens/           # per-share token files
│   └── logs/             # access logs
├── contacts/
│   └── contacts.json     # name → node_id + pub_key
└── cache/
    └── dht/              # cached DHT records for search
```

---

## Security Model

- Private key never leaves device — relay cannot sign or decrypt
- All share records signed by device key — forgery impossible
- SELECTIVE tokens signed — cannot be forged by relay
- PRIVATE mode: relay sees only encrypted bytes
- Relay runs in untrusted mode: compromising the relay exposes
  zero content (PUBLIC links) or zero content + zero metadata (PRIVATE)
- The worst a malicious relay can do: deny service (drop connections)

---

## Implementation Plan

### Phase 1 — Foundation (build now)
- [x] Protocol design (this doc)
- [ ] `net/share/agentic-shared.sh`  — daemon prototype in shell
- [ ] `net/relay/relay-server.py`    — relay server
- [ ] `net/share/share-tools.sh`     — agent tool hooks

### Phase 2 — Discovery
- [ ] DHT node implementation
- [ ] Bootstrap nodes
- [ ] Search API

### Phase 3 — Production
- [ ] Rewrite daemon in C (fits OS binary model)
- [ ] E2E encryption (PRIVATE mode)
- [ ] Mobile-friendly relay with WebRTC fallback
- [ ] Trusted-peer caching
