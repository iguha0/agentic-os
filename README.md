# PryzentOS

**The home screen is an agent. The phone is a server.**

PryzentOS is a from-scratch, AI-first operating system that boots in QEMU
(aarch64). A custom init replaces systemd; an agent shell is your primary
interface; on-device LLM inference (Qwen2.5 via llama.cpp) powers everything;
and **AgentoNet** turns the device into a self-sovereign server — share files
publicly, with per-person tokens, or end-to-end encrypted, discoverable through
a metadata-only DHT search index.

## Quick start

```bash
# download model (Apache-2.0, from HuggingFace)
./download-model.sh

# text mode (~55MB bundle)
./test-interactive.sh

# graphical mode (X11 + Openbox + Chromium kiosk)
./launch-graphical.sh
```

Inside the OS: `!net` for diagnostics · `netsearch <query>` for shared content ·
`open <link>` to decrypt received shares · `zap 100` for a Lightning invoice ·
Share app / Search app / Store in the web UI.

## Highlights

- 🤖 **Agent-first**: local LLM (no cloud), tool use, browser automation over CDP
- 🪐 **AgentoNet**: phone-as-server sharing — public / token-restricted / E2E
  (libsodium sealed boxes), blind relay, DHT index, access logs, revocation
- ⚡ **Lightning**: LNURL-pay receive flow (`zap`, tip links)
- 🛰 **Nostr**: real BIP340 Schnorr signing; live-relay verified
- 🛍 **Apps & Store**: session-backed web apps + F-Droid catalogue bridge
- 🔓 **AGPL-3.0**: copyleft, forever

See [BETA_NOTES.md](BETA_NOTES.md) for the v0.3.0-beta feature/test matrix and
[docs/AGENTONET.md](docs/AGENTONET.md) for the network protocol design.

## License

Copyright (C) Indrajit Guha

This program is free software: you can redistribute it and/or modify it under
the terms of the **GNU Affero General Public License** as published by the Free
Software Foundation, version 3 of the License ([LICENSE](LICENSE)).

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU Affero General Public License for more details.
