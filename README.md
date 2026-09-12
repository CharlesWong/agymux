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
```

---

## 🏗️ Architecture & Storage

- **Configuration**: `~/.agymux/pools.json`
- **Active Sessions**: `~/.agymux/sessions/<pid>.json`
- **Lock File**: `~/.agymux/switch.lock`
- **Credential Storage**: Reuses `~/.aisw/profiles/antigravity/` and macOS Keychain (`gemini / antigravity`)
- **Shared Workspace**: Leverages shared `~/.gemini/antigravity-cli` (conversations, brain, history)
