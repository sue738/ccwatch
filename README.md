# ccwatch ⏱

**A native macOS menu bar app for your Claude Code usage — no config file, no cache directory, no companion daemon.**

ccwatch shells out directly to the CLIs it depends on and to Anthropic's own
usage endpoint. Nothing runs in the background except ccwatch itself.

## What it shows

See [METRICS.md](METRICS.md) for exactly how each card's number is calculated
(source CLI, exact command, and the formula) — also linked from inside the app
itself ("計算ロジック" next to the title).

Each card only appears if its CLI is installed — no error, no placeholder, it just isn't there:

- **稼働時間 / コスト / トークン** (today + 30-day) — `cchours` and `ccusage`
- **レート制限** (5-hour, weekly, and any model-scoped weekly window) — read directly from `https://api.anthropic.com/api/oauth/usage`, authenticated with the OAuth token Claude Code itself already stores in your Keychain (or `~/.claude/.credentials.json` as a fallback). Read-only: ccwatch never writes back to your credentials.
- **コスト推移 / トークンコスト($/Mtok)** — 30-day stacked cost by model, and cost per million tokens — `ccusage`
- **稼働時間 / 最長連続稼働 / アクティビティ** — daily hours, longest unbroken run, hour×day heatmap — `cchours`
- **並列度 / 委譲率** — how many agents ran at once, and what share of that time was delegated to subagents — `cchours`
- **固定トークン** — the always-on token overhead sent before your first word, broken down against your own memory files — `ccsendstats`
- **コンテキスト使用率(分布)** — daily p25/p50/p75 of how full the context window got — `ccsendstats`
- **実行中の割り込み率** — share of prompts sent while the previous turn was still running — `ccsendstats`
- **ツール失敗率** — which tools are failing, and how often — `ccflaky`
- **スキル発火** — which of your Claude Code skills actually fire — `ccskillstats`
- **セッションあたり発話数** — how long an average conversation ran — `ccattention`
- **自己訂正率 / 差し戻し** — how often the assistant walked back its own answer, and how often a hook bounced it — `ccattention`

## Install

```sh
npm install -g cchours ccusage ccattention ccflaky ccskillstats ccsendstats
git clone https://github.com/sue738/ccwatch.git
cd ccwatch
./build.sh
```

All of these are on npm. `ccusage` is the one written by someone else — the
rest are this author's, and ccwatch delegates cost and token totals to
`ccusage` rather than reimplementing them.

Any missing CLI is fine — ccwatch still works, that CLI's cards just don't
appear. No error, no placeholder. But install all of them and you get the
full board.

**Requirements: macOS 14 or later, and the Xcode command line tools** (`xcode-select
--install`) for `swift build`. The app's UI is in Japanese; the CLIs it reads
are English by default.

`build.sh` builds the release binary, assembles `dist/ccwatch.app` (with a
proper `Info.plist` — bundle identifier, `LSUIElement` so it doesn't show in
the Dock), and ad-hoc code-signs it. It prints the install/login-item
commands; it doesn't touch `~/Applications` or your login items on its own.

## Security & trust

- No dependencies beyond Apple's own frameworks (SwiftUI, Foundation, Charts).
- Reads local files (Keychain, `~/.claude/.credentials.json`) and shells out
  to the local CLIs above — nothing else touches disk.
- The only network calls are to `api.anthropic.com` (your own usage data,
  authenticated with your own token) and `status.claude.com` (public status
  page, no auth). No telemetry, no third-party endpoint.
- **The first run shows a Keychain permission dialog** for the
  `Claude Code-credentials` item, because ccwatch shells out to
  `/usr/bin/security` to read the token the `claude` CLI already stored.
  Choose *Always Allow* — *Allow* means the prompt returns on every refresh.
  Declining is fine too: you lose the rate-limit card and keep everything else.
- Never writes to your credentials store, never refreshes your OAuth token —
  if it's expired, ccwatch just says so and waits for you to run `claude`
  again.
- The `api.anthropic.com/api/oauth/usage` call sends the same `User-Agent`
  the official `claude` CLI sends (`claude-cli/2.1.220 (external, cli)`) —
  this endpoint isn't publicly documented; ccwatch is reusing it the way the
  CLI itself does, with your own token, not impersonating a different client
  for access it wouldn't otherwise have. Worth knowing before you `git clone`
  and run this against your own account.

## Why a second app instead of just extending ccmenubar

This author has a separate personal build (`ccmenubar-app`, not public) that
reads cache files a private xbar plugin writes on a schedule specific to one
machine's setup; it isn't something a stranger's `git clone` would produce
any data from. ccwatch is the self-contained version of the same idea: same
visual language, but every number here comes from a command this app ran
itself, in front of you.

## Status

Public. Every CLI it depends on is installable from npm, so a `git clone` plus
the install line above gets you the full set of cards.
