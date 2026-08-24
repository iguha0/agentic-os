# Reddit Post — PryzentOS (community-first version)

## Title (pick one)

- I spent months building a Linux OS where the home screen is an LLM agent — AGPL-3.0, boots in QEMU today
- I built an OS that turns your phone into a server: E2E-encrypted sharing, DHT discovery, on-device LLM. Beta is up (AGPL-3.0)

---

## Body

Hey everyone. Long-time reader, first-time poster. I've been building a hobby OS called **PryzentOS** and the beta is finally bootable, so I wanted to share it with people who'll actually appreciate how weird it is.

**The premise:** every "OS innovation" since iOS has been UI polish. I wanted to test a different thesis — what if the home screen *is* an agent, and the device *is* the server? So I built one from scratch. No Android, no systemd. Custom shell init as PID 1, Alpine userland, and a local LLM as the primary interface.

**What actually works right now (all verified by automated gate tests):**

- Boots in QEMU (aarch64, ~26MB text image / ~340MB graphical). Custom init mounts everything, starts llama-server inside the guest, and drops you into an agent shell
- On-device inference — Qwen2.5-1.5B via llama.cpp, served on localhost. Pull the network cable and it still works. Prompts never leave the machine
- The agent has a real tool grammar: `TOOL:search`, `TOOL:web_read`, browser automation over CDP (it can drive Chromium using *your* logged-in sessions — sessions persist across reboots), and `TOOL:create_tool` which lets the model write new tools at runtime
- **AgentoNet** — the part I'm most excited about. Your device hosts its own content:
  - public links (content-addressed, sha256 CIDs)
  - per-person tokens with expiry + download caps + revoke
  - end-to-end encrypted shares (libsodium sealed boxes — the relay only ever sees ciphertext)
  - a metadata-only DHT so devices can discover each other's public shares. I verified this with **two independent QEMU VMs**: B found A's share via the DHT and pulled the bytes through the relay
- Nostr publishing with real BIP340 Schnorr signatures (I wrote the signer in pure stdlib Python — no deps). 6/7 live relays accepted a test post, and I fetched it back from nos.lol to confirm
- Lightning receive via LNURL-pay (`zap 100` gets you a real BOLT11 invoice — tested live against getalby)
- A web home screen (the kiosk browser shows it): chat with the agent, a share manager, DHT search, and an F-Droid catalogue bridge

**What it absolutely is not (yet):**

- Not a daily driver. It's a QEMU beta. No Android app runtime (F-Droid APKs download as take-away artifacts)
- The relay/DHT bootstrap currently defaults to my Mac — self-hostable, but production infra isn't up
- Private-share decrypt on the receiving side is functional but CLI-flavored
- SearXNG (the fancy search backend) only ships in the graphical image; text mode falls back to scrapers
- The LLM is a 1.5B model. It's surprisingly capable with tools but it's no GPT-4, by design — the point is local

**Links:**

- Source + docs: https://github.com/iguha0/agentic-os (AGPL-3.0)
- Beta downloads: https://github.com/iguha0/agentic-os/releases/tag/v0.3.0-beta
- Protocol design doc: https://github.com/iguha0/agentic-os/blob/main/docs/AGENTONET.md

If you boot it, `!net` inside the shell shows a connectivity matrix, and `help` lists the agent commands. I'd genuinely love feedback — especially from folks who've built OSes or run relays/DHTs in production. What would you attack first? What's missing before this is worth running outside QEMU?

I'll be in the comments all day.

---

## Posting playbook (don't skip)

1. **Best subreddits, in order of fit:**
   - r/osdev — "from scratch OS" angle, they'll ask about the init/kernel (answer: Alpine linux-virt kernel, custom busybox init — be upfront it's a Linux distro, not a from-scratch kernel, or you'll get eaten alive)
   - r/LocalLLaMA — lead with the on-device Qwen2.5 + tool-use angle
   - r/selfhosted — lead with AgentoNet "your device is the server"
   - r/opensource + r/linux — general launch post
2. **One sub per day.** Crossposting identical text to many subs at once reads as spam and mods will nuke it.
3. **Adjust the first paragraph per sub** — lead with what THAT community cares about.
4. **Reply to every comment within the first 2 hours.** Reddit ranks by comment activity; also it's just right.
5. If someone breaks something, say "thank you + it's on the list" — bug reports in comments are gold.
6. Don't mention the LinkedIn post or "launch/marketing" anywhere. The word "beta" + "feedback wanted" is the honest framing.
