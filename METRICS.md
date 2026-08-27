# How each card is calculated

A summary of where each metric ccwatch displays comes from and how it is
calculated. Everything is computed locally, either from the local
`~/.claude/projects/**/*.jsonl` files (Claude Code's local transcripts) or
from Anthropic's own usage endpoint. Nothing is ever sent to an external
server (see the "Security & trust" section of each CLI's README).

## Hours / cost / tokens (summary tiles)

- Today's value: `cchours --today --json` / `ccusage daily --since <today> --json`
- 30-day value: `cchours --days 30 --json` / `ccusage daily --since <30 days ago> --json`

## Rate limits

Calls `https://api.anthropic.com/api/oauth/usage` directly. Authentication
reads the OAuth token that Claude Code itself stores in the Keychain
(falling back to `~/.claude/.credentials.json`). Shows usage rates for the
5-hour window, the weekly window, and per-model weekly windows (e.g. the
Fable window), along with each window's reset time.

## Cost trend

Takes the per-day, per-model cost from
`ccusage daily --since <30 days ago> --breakdown --json` and renders it
directly as a stacked area chart by model.

## Hours / longest run

`agentHours` (that day's total active hours) and `longestRunHours` (that
day's longest continuous run), both returned per day by
`cchours --daily --since <30 days ago> --json`. The two scales differ
greatly (hours vs. minutes), so the right axis is normalized into the left
axis's range and overlaid (this is one axis with a relabeled right side,
not a true dual-axis chart).

## Parallelism / delegation

`parallelism` (that day's average concurrency multiplier) and
`subagentHours / agentHours` (delegation rate, the share of time spent on
subagents), both from the same `cchours --daily` response. No new CLI call
is made. Viewed daily, parallelism actually swings widely, from 1.0x to
1.9x, and delegation from 0.8% to 56% (confirmed that collapsing this into
a 45-day aggregate flattens out the movement).

## Activity (hour-of-day heatmap)

Lays the per-day, per-hour active-seconds returned by `cchours --daily`
into a 24-hour × N-day grid, and shades each cell relative to that day's
maximum (on a square-root scale).

## Context usage (distribution)

The p25/p50/p75 of context usage across that day's requests, returned by
`ccsendstats --daily --days 30 --json`. The peak value (the day's single
longest-running session) sits near the 90% mark almost every day in
practice, which carries little signal, so the median is shown instead — it
actually moves week to week (p50: 16.7%-63%) — with a p25-p75 band around
it.

## Turns per session

`user` (that day's number of turns) returned by
`ccattention --json --days 30`, divided by `threads` (the number of
sessions actually talked to that day). This used to split into threads
using a time gap rule — "a new task after a 90-minute gap" — but the
threshold was manufacturing the answer (a day spent typing continuously
never hit a gap, so 239 turns counted as "one task"; conversely a quiet day
produced 0 tasks and was uncomputable — over 30 days of real data, CV =
1.15, and only 29 of 31 days could even be computed). Using the session as
the unit removes the tuning parameter entirely — the same 30 days give CV =
0.56, computable for every day. That said, **a session is not a unit of
work**, so this is really the length of a session, not "how many turns one
task took" (a single session spanning multiple topics will read as long).

## Self-correction / bounces

From the same `ccattention --json --days 30`, the daily self-correction
rate (the share of turns that walked back the previous one = selffix count
÷ total turns) and the raw bounce count. Both are actual counts that don't
depend on how sessions get split, so if what you want is the raw burden
itself, these are the more direct read.

## Interrupt rate while running

`ccsendstats --daily --interrupt --days 30 --json`. The share of prompts
sent while running (the previous turn had not yet finished). Aggregated per
day with entries where `promptSource == 'queued'` as the numerator and
`typed` + `queued` as the denominator. Main loop only (subagent entries are
excluded).

## Tool failure rate

Today's value comes from `ccflaky --json --days 1`, and the trend from
`ccflaky --daily --json --days 30`. Tool calls are matched to their results
by `tool_use_id`, and the share of calls that errored is computed (matching
by ID rather than position means concurrent calls are never mismatched).

## Skills fired

`ccskillstats --json` gives the overall fire count (via the Skill tool plus
explicit `/name` invocations), and `ccskillstats --daily --json --days 30`
gives the daily breakdown (`tool` = times Claude chose it on its own during
a conversation, `typed` = times you typed `/name` yourself, `auto` =
automatic runs such as from cron). `--unused` cross-references SKILL.md
files on disk (e.g. under `~/.claude/skills`) to find skills that have
never fired (skills bundled with the CLI itself have no SKILL.md, so this
inventory is best-effort).

## Token cost ($/Mtok)

`ccusage daily`'s per-day cost divided by per-day token count (actual cost
per million tokens). Lower means better cache efficiency.

## Fixed tokens

A stacked chart of the daily average of "how many tokens are already sent
before the conversation starts (i.e. before the first message goes out),"
returned by `ccsendstats --daily --baseline --days 30 --json`, overlaid
with the breakdown of accumulated memory (cumulative token counts for each
of the `feedback`/`project`/`user`/`reference` categories). The remainder
that memory doesn't account for — the system prompt itself, CLAUDE.md
itself, tool definitions, and anything else that leaves no trace in the
transcript to break down — is bucketed as `other`, shown as-is rather than
hidden, i.e. openly "unknown."

---

For each metric's implementation, see `Sources/ccwatch/Data.swift` (CLI
calls and parsing) and `Sources/ccwatch/UI.swift` (aggregation and
rendering). Comments in the code also keep the concrete numbers confirmed
by running against real data (e.g. "p75 actually moves between 46% and
78%"), along with metrics that were removed in the past and why.
