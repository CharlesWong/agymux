# `agymux` (`agyx`)
### Smart Multi-Profile Dispatcher, Quota Manager & Concurrency Governor for Antigravity CLI

`agymux` (aliased as `agyx`) is an autonomous, high-performance CLI wrapper for Google's Antigravity CLI (`agy`). It automatically switches profiles at session startup, isolates VIP accounts into a **Reserved Pool**, cycles commodity accounts in an **Auto Pool** based on multi-window quotas, enforces per-profile active thread limits, and seamlessly migrates conversations across profiles when hitting quota walls.

---

## ⚡ Quickstart

```bash
# 1. Check health and discovered profiles
agyx doctor

# 2. View live multi-account quota & concurrency dashboard
agyx pool status

# 3. Launch an AGY session (auto-dispatches to the healthiest profile)
agyx

# 4. Resume the most recent conversation on the best available profile
agyx -c
agyx resume

# 5. Explicitly use a reserved account (e.g. personal/VIP)
agyx --profile current
```

---

## 🎯 Key Features

### 1. Dual Pool Categorization
- **Auto Pool** (`charleswongjy`, `everestmountaineer`, `mitnick162`, `mitnick915`, `quavolve`):
  Automated rotation. The scheduler evaluates remaining quotas and active concurrency slots before each session.
- **Reserved Pool** (`current` / primary VIP account):
  Manual-only protection. Shielded from routine automated batch exhaustion. Only activated when explicitly requested (`agyx --profile current`) or via configurable fallback prompt when all auto accounts are depleted.

### 2. Five Quota Choosing Strategies
- **`smart` (Default)**: Multi-objective composite scoring balancing remaining quota (50%), reset urgency bonus (20%), and concurrency penalty (30%).
- **`max-headroom`**: Greedy selection prioritizing the profile with the highest bottleneck quota.
- **`harvest`**: Prioritizes accounts whose 5-hour window is expiring soonest (<60 min) with usable quota ($\ge 15\%$), harvesting tokens before they reset.
- **`balanced`**: Evenly drains quota across accounts to maintain uniform headroom.
- **`model-adaptive`**: Automatically evaluates Claude/GPT quotas when `--model claude...` is requested, and Gemini quotas when Gemini is requested.

### 3. Concurrency Guard & Slot Governor
- **Default: 3 active threads per profile** (configurable).
- Eliminates intra-profile quota competition and backend HTTP 429 rate limit throttling.
- Session registry in `~/.agymux/sessions/<pid>.json` with dead PID auto-pruning.

### 4. Cross-Profile Mid-Session Resumption
- Supervised execution tracks child process output for `RESOURCE_EXHAUSTED`, `429`, or quota exhaustion warnings.
- Gracefully flushes conversation state to disk (`~/.gemini/antigravity-cli/conversations/<id>.db`).
- Automatically selects the next healthiest Auto Pool profile, switches Keychain, and relaunches `agy --conversation <id>` with 100% conversation continuity.

### 5. Continuation Stickiness & Prompt Cache Preservation
- **Prompt Cache Optimization**: When continuing a conversation (`-c`, `--continue`, `--conversation <id>`, or `resume`), `agyx` tracks which account previously handled that thread.
- **Cache Hit Guarantee**: If the prior account has **sufficient quota** ($\ge 15\%$ bottleneck quota and $< 3$ active threads), `agyx` sticks to that account, maximizing Gemini & Claude server-side context cache hits (reducing latency and token consumption).
- **Graceful Failover**: If the sticky account runs out of quota ($< 15\%$ or depleted) or hits thread capacity, stickiness breaks automatically, re-routing to the healthiest profile in the Auto Pool.

---

## 🛠️ CLI Reference

### Session Management
```bash
# Transparent drop-in usage
agyx

# Resume latest conversation
agyx -c
agyx --continue
agyx resume

# Resume exact conversation ID
agyx --conversation <uuid>

# Non-interactive print mode with auto-retry across profiles on quota hit
agyx -p "Explain this codebase"

# Pass through any official AGY flags
agyx --model gemini-2.5-pro --effort high
```

### Pool & Strategy Administration
```bash
# Multi-account quota and slot dashboard
agyx pool status

# Change a profile's category
agyx pool set charleswongjy reserved
agyx pool set quavolve auto

# Inspect detailed 5-hour and weekly quota breakdown
agyx quota quavolve

# Configure default model (defaults to gemini-3.8-flash-high)
agyx config set model "gemini 3.8 flash high"
agyx config set model claude-sonnet-4-6

# Configure default strategy
agyx config set strategy [smart | max-headroom | harvest | balanced | model-adaptive]

# Configure max active threads per profile (defaults to 3)
agyx config set max-threads 3

# Configure reserved fallback mode (prompt | never | auto)
agyx config set reserved-fallback prompt

# Configure stickiness minimum quota threshold (defaults to 15%)
agyx config set stickiness-quota 15%
```

---

## 🤖 Guidelines for AI Agents & Automation Harnesses

When invoking `agyx` programmatically from subagents, background jobs, or CI/CD pipelines:

1. **Always pass `-p` / `--print`**: Running bare `agyx` requires a full interactive terminal TTY. Headless processes will hang on stdin if `-p` is omitted.
2. **Preserve Prompt Cache**: For multi-turn tasks, chain rounds with:
   ```bash
   agyx -c -p "<next instruction>" --output-format json
   ```
   `agyx` automatically locks to the previous account if quota is $\ge 15\%$, hitting the server-side prompt/KV cache and saving 75%–90% of input token quota and latency.
3. **Structured JSON Output**: Use `--output-format json` to get machine-parseable outputs containing `conversation_id`, `response`, and token `usage`.
4. **Persistent Daemon / IPC**: For continuous multi-turn harnesses without process spawn overhead:
   ```bash
   agyx -p --input-format stream-json --output-format stream-json
   ```
5. **No Need for Retry Loops**: Do not implement 429/quota retry logic in agent harnesses. `agyx` intercepts `RESOURCE_EXHAUSTED` and migrates profiles across the Auto Pool autonomously.
6. **Reserved Pool Protection**: Never pass `--profile current` unless explicitly commanded by the human user.

---

## 🏗️ Architecture & Storage

- **Configuration**: `~/.agymux/pools.json`
- **Stickiness Registry**: `~/.agymux/stickiness.json`
- **Active Sessions**: `~/.agymux/sessions/<pid>.json`
- **Switch Lock**: `~/Library/Application Support/AgySwitcher/switch.lock`, shared with Switchboard and `agyctl`
- **Credential Storage**: Reuses `~/.aisw/profiles/antigravity/` and macOS Keychain (`gemini / antigravity`)
- **Shared Workspace**: Leverages shared `~/.gemini/antigravity-cli` (conversations, brain, history)

Profile activation requires Switchboard's patched `aisw-switchboard` bridge with
the `antigravity_credential_only` capability. Install or update it with
`../switcher/scripts/install-shim.sh`. Upstream `aisw` can restore or delete shared
settings and conversation files, so it is never used for activation. A failed
bridge operation stops the launch; there is no direct Keychain/config write fallback.
An interrupted Switchboard transition must be recovered in Switchboard first.
Both terminal and print-mode sessions start through the installed `agyctl` launcher,
which checks the expected profile under the shared switch lock and preserves the
original working directory and arguments, including `-c`. If another switch wins
the race before launch, retry the command; it will not silently use that account.
Every AGY session launched by agyx uses `--dangerously-skip-permissions` to
auto-approve tool requests, including interactive, print, resumed, and migrated
sessions. This launch policy does not change ordinary `agy` invocations.

Switcher can launch `agyx` with its **Use agyx** checkbox. Its saved manual AGY
profile is independent of automatic scheduling: the `agyx` handoff always uses
its own selected profile, and activating it never updates Switchboard's manual
preference. Switchboard labels these sessions as agyx-managed and excludes them
from manual profile-switch restart plans. Both tools still share the physical
Keychain credential and the existing settings/conversation directories.
