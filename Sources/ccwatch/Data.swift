// ccwatch — self-contained Claude Code usage menu bar app. Unlike
// ccmenubar-app (reads a private xbar plugin's cache), it shells out
// directly to the public CLIs and Anthropic's oauth/usage endpoint; a
// missing CLI just omits its card.

import SwiftUI
import Foundation
import Charts
import AppKit

// MARK: - CLI discovery

/// GUI apps launched by LaunchServices get a minimal PATH (no Homebrew, no
/// npm bin) — check common install locations, then fall back to a login shell.
func findCLI(_ name: String) -> String? {
    let home = NSHomeDirectory()
    let fm = FileManager.default
    var candidates = [
        "/opt/homebrew/bin/\(name)",
        "/usr/local/bin/\(name)",
        "\(home)/.local/bin/\(name)",
        "\(home)/.npm-global/bin/\(name)",
        "\(home)/.volta/bin/\(name)",
        "\(home)/.bun/bin/\(name)",
    ]
    // nvm/fnm/mise dig a per-node-version directory (fixed paths miss it),
    // and `zsh -l` below doesn't read .zshrc — without this every card vanishes.
    for base in ["\(home)/.nvm/versions/node", "\(home)/.local/share/fnm/node-versions",
                 "\(home)/.local/share/mise/installs/node"] {
        guard let vers = try? fm.contentsOfDirectory(atPath: base) else { continue }
        for v in vers.sorted(by: >) {
            candidates.append("\(base)/\(v)/bin/\(name)")
            candidates.append("\(base)/\(v)/installs/bin/\(name)")
        }
    }
    for c in candidates where fm.isExecutableFile(atPath: c) { return c }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-l", "-c", "command -v \(name) 2>/dev/null"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do {
        try p.run()
    } catch {
        return nil
    }
    // A hung login shell blocks waitUntilExit() forever, and since this runs
    // from Snapshot's init, the whole menu bar never appears — bound with a deadline.
    let deadline = Date().addingTimeInterval(5)
    while p.isRunning && Date() < deadline { usleep(20_000) }
    if p.isRunning {
        p.terminate()
        // terminate() sends SIGTERM but doesn't guarantee immediate exit;
        // returning without reaping risks a zombie process.
        let killDeadline = Date().addingTimeInterval(1)
        while p.isRunning && Date() < killDeadline { usleep(20_000) }
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (out?.isEmpty == false) ? out : nil
}

/// Resolves a CLI's stdout as JSON. Some calls take 30-60s+ (measured:
/// ccusage 31.7s, ccskillstats --days 30: 60s+), and the pipe is read
/// continuously — waiting until exit risks deadlock past the 64KB buffer.
func runJSON(_ path: String, _ args: [String], timeout: TimeInterval = 180) -> Any? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = errPipe
    var collected = Data()
    let lock = NSLock()
    outPipe.fileHandleForReading.readabilityHandler = { handle in
        let chunk = handle.availableData
        lock.lock(); collected.append(chunk); lock.unlock()
    }
    // stderr needs continuous draining too, or the 64KB pipe buffer fills
    // and the child blocks on write() (measured cause of pegged CPU).
    errPipe.fileHandleForReading.readabilityHandler = { handle in
        _ = handle.availableData
    }
    do {
        try p.run()
    } catch {
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        return nil
    }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(50_000) }
    if p.isRunning { p.terminate() }
    // Drain whatever arrived right around exit before tearing the handler down.
    usleep(50_000)
    outPipe.fileHandleForReading.readabilityHandler = nil
    errPipe.fileHandleForReading.readabilityHandler = nil
    lock.lock(); let data = collected; lock.unlock()
    return try? JSONSerialization.jsonObject(with: data)
}

// MARK: - Data models

struct RateWindow {
    let usedPct: Int
    let resetsAt: Date
}

struct ScopedLimit: Identifiable {
    let id = UUID()
    let name: String
    let pct: Int
    let resetsAt: Date
}

struct DailyPoint: Identifiable {
    let id = UUID()
    let date: Date
    let agentHours: Double
    let longestRunHours: Double
    // Already returned by cchours --daily (no new fetch) — measured:
    // parallelism 1.0-1.9, delegation 0.8%-56%.
    let parallelism: Double
    let subShare: Double
}

struct CostPoint: Identifiable {
    let id = UUID()
    let date: Date
    let model: String
    let cost: Double
}

struct EfficiencyPoint: Identifiable {
    let id = UUID()
    let date: Date
    let perMtok: Double
    let totalTokens: Double
    // Input and output differ in nature — totalTokens alone hides which dominates.
    let inputTokens: Double
    let outputTokens: Double
}

/// Daily average fixed cost (system prompt+CLAUDE.md+memory+tool defs)
/// (ccsendstats --daily --baseline) — measured: ~33k→52k over 9 days.
/// Share of runs where the next prompt was sent mid-run (--daily --interrupt)
/// — measured: 0%→100% over 30 days.
struct InterruptPoint: Identifiable {
    let id = UUID()
    let date: Date
    let interruptRate: Double
    let total: Int
}

struct BaselinePoint: Identifiable {
    let id = UUID()
    let date: Date
    let avgBaseline: Double
    // Ties to cost-trend/peak% noise (measured: swings 2-54).
    let sessions: Int
}

/// Daily context-window usage (ccsendstats --daily). peak pins near 90%+ on
/// busy days (no signal); p50 moves 16.7%-63% over 9 days — show p50.
struct ContextUsagePoint: Identifiable {
    let id = UUID()
    let date: Date
    let p25Pct: Double
    let p50Pct: Double
    let p75Pct: Double
}

/// Fixed-cost breakdown before a conversation starts — system prompt/tool
/// defs don't persist in the transcript, but memory files' mtime+size do,
/// reconstructing cumulative tokens/category day by day (measured: ~1.2k on
/// 8/15 to ~19.1k on 8/22, matching baseline's +19k growth).
struct MemoryGrowthPoint: Identifiable {
    let id = UUID()
    let date: Date
    let category: String
    let cumulativeTokens: Double
}

struct ToolFailure: Identifiable {
    let id = UUID()
    let name: String
    let calls: Int
    let errorRate: Double
}

struct SkillFire: Identifiable {
    let id = UUID()
    let name: String
    let total: Int
}

struct ErrorRatePoint: Identifiable {
    let id = UUID()
    let date: Date
    let errorRate: Double
}

struct SkillPoint: Identifiable {
    let id = UUID()
    let date: Date
    let total: Double
}

/// "Who invoked it": tool (Claude chose it) / typed (/name) / auto (cron).
/// Measured: auto 63%, tool 17%.
struct SkillFireKindRow: Identifiable {
    let id = UUID()
    let date: Date
    let kind: String
    let count: Double
}

/// Effort you paid — times you had to type per matter (perThread), same
/// formula as xbar plugin claude-limits.1m.sh.
struct AttentionPoint: Identifiable {
    let id = UUID()
    let date: Date
    let perThread: Double
    let charsPerThread: Double
    let blocksPerThread: Double
    let selffixRate: Double
    // Raw pushback count, not divided by matter — the "matter" definition
    // is fuzzy, so per-thread normalization was dropped; raw count isn't.
    let blocksRaw: Int
}

let isoDay: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone.current
    return f
}()

extension ISO8601DateFormatter {
    static let flexible: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

func tokFmt(_ n: Double) -> String {
    let units: [(String, Double)] = [("T", 1e12), ("B", 1e9), ("M", 1e6), ("k", 1e3)]
    for (u, div) in units where n >= div {
        return String(format: "%.1f%@", n / div, u)
    }
    return String(format: "%.0f", n)
}

func moneyFmt(_ v: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = 0
    return "$" + (f.string(from: NSNumber(value: v)) ?? String(format: "%.0f", v))
}

// MARK: - Snapshot

// @MainActor: writing to @Published off the main thread crashes
// NSAssertionHandler (measured). But refresh() blocks (CLI shell-outs,
// network) — sync on MainActor blocks the menu bar's first render too
// (measured) — keep refresh() async, offload blocking calls to Task.detached.
@MainActor
final class Snapshot: ObservableObject {
    @Published var hasCchours = false
    @Published var hasCcusage = false
    @Published var hasCcflaky = false
    @Published var hasCcskillstats = false
    /// Cards whose result hasn't returned — distinguishes empty data from
    /// absent, since a heavy CLI (measured 60s+) would look absent otherwise.
    @Published var pending: Set<String> = []
    @Published var hasAttention = false
    @Published var hasCcsendstats = false
    @Published var hasCredentials = false

    @Published var agentHoursToday: Double?
    @Published var agentHours30: Double?
    @Published var costToday: Double?
    @Published var cost30: Double?
    @Published var tokensToday: Double?
    @Published var tokens30: Double?
    @Published var dailyHours: [DailyPoint] = []
    @Published var hourlyHeatmap: [[Double]] = []
    @Published var costSeries: [CostPoint] = []
    @Published var efficiencySeries: [EfficiencyPoint] = []
    @Published var baselineSeries: [BaselinePoint] = []
    @Published var interruptSeries: [InterruptPoint] = []
    @Published var contextUsageSeries: [ContextUsagePoint] = []
    @Published var memoryGrowthSeries: [MemoryGrowthPoint] = []

    @Published var fiveHour: RateWindow?
    @Published var sevenDay: RateWindow?
    @Published var scopedLimits: [ScopedLimit] = []
    @Published var rateLimitError: String?

    @Published var toolErrorRate: Double?
    @Published var toolCallsToday: Int?
    @Published var topFailingTools: [ToolFailure] = []
    @Published var errorRateSeries: [ErrorRatePoint] = []

    @Published var skillsFired: Int?
    @Published var skillsTotal: Int?
    @Published var topSkills: [SkillFire] = []
    @Published var skillsSeries: [SkillPoint] = []
    @Published var skillFireKindSeries: [SkillFireKindRow] = []

    @Published var attentionPerThreadToday: Double?
    @Published var attentionSeries: [AttentionPoint] = []

    @Published var claudeStatusIndicator: String?
    @Published var claudeStatusDesc: String?

    @Published var lastRefresh = Date()

    // As `let`, all five would resolve **sequentially** (findCLI falls back
    // to a 5s login shell each), blocking MainActor up to 25s during
    // Snapshot() construction. Kept `var`, resolved concurrently after launch.
    private var cchoursPath: String?
    private var ccusagePath: String?
    private var ccflakyPath: String?
    private var ccskillstatsPath: String?
    private var attentionPath: String?
    private var ccsendstatsPath: String?
    private var pathsResolved = false

    private func resolvePathsIfNeeded() async {
        guard !pathsResolved else { return }
        pathsResolved = true
        async let a = Task.detached { findCLI("cchours") }.value
        async let b = Task.detached { findCLI("ccusage") }.value
        async let c = Task.detached { findCLI("ccflaky") }.value
        async let d = Task.detached { findCLI("ccskillstats") }.value
        async let e = Task.detached { findCLI("ccattention") }.value
        async let f = Task.detached { findCLI("ccsendstats") }.value
        (cchoursPath, ccusagePath, ccflakyPath, ccskillstatsPath, attentionPath, ccsendstatsPath) = await (a, b, c, d, e, f)
    }

    // ccskillstats etc. can exceed 90s (per README); an overlapping tick
    // would cause extra rate-limit hits — skip the next call while one runs.
    private var isRefreshing = false

    // Scanning transcripts every 60s tick measured out to 4 node processes
    // near 100% CPU — these reuse the xbar plugin's production cache
    // intervals instead: cchours 5min; ccflaky/ccskillstats 900s/3600s.
    private var nextHours = Date.distantPast
    private var nextCost = Date.distantPast
    private var nextToolStats = Date.distantPast
    private var nextSkills = Date.distantPast
    private var nextAttention = Date.distantPast
    private var nextRateLimit = Date.distantPast
    private var nextBaseline = Date.distantPast
    private var nextInterrupt = Date.distantPast
    private var nextContextUsage = Date.distantPast
    private var nextMemoryGrowth = Date.distantPast
    private let hoursCostTTL: TimeInterval = 300
    private let toolStatsTTL: TimeInterval = 900
    private let skillsTTL: TimeInterval = 900
    private let attentionTTL: TimeInterval = 1800
    // --baseline reads full session text (heaviest) — same 30-min interval as attention.
    private let baselineTTL: TimeInterval = 1800
    private let interruptTTL: TimeInterval = 1800
    // --daily (peak/avg/p50) only needs usage totals (as light as --cache).
    private let contextUsageTTL: TimeInterval = 900
    private let memoryGrowthTTL: TimeInterval = 900
    // /api/oauth/usage rate-limits per account (measured: 60s polling gets
    // a 429 on 1 of 2 calls, 3+ consecutive when colliding with other
    // processes) — base interval 180s, exponential backoff on 429.
    private let rateLimitBaseTTL: TimeInterval = 180
    private var consecutive429 = 0

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await resolvePathsIfNeeded()

        hasCchours = cchoursPath != nil
        hasCcusage = ccusagePath != nil
        hasCcflaky = ccflakyPath != nil
        hasCcskillstats = ccskillstatsPath != nil
        hasAttention = attentionPath != nil
        hasCcsendstats = ccsendstatsPath != nil

        // Each refreshX offloads to Task.detached before awaiting, so
        // MainActor moves on instantly (sequential would add ccusage's 32s +
        // ccskillstats's 60s + ...). Heavy calls only fire once TTL expires.
        let now = Date()
        // Don't re-mark pending if a card already has a value, or it flickers to a skeleton on refresh.
        if now >= nextHours, hasCchours, dailyHours.isEmpty { pending.insert("hours") }
        if now >= nextCost, hasCcusage, costSeries.isEmpty { pending.insert("cost") }
        if now >= nextToolStats, hasCcflaky, toolErrorRate == nil { pending.insert("tool") }
        if now >= nextSkills, hasCcskillstats, skillsTotal == nil { pending.insert("skills") }
        if now >= nextAttention, hasAttention, attentionSeries.isEmpty { pending.insert("attention") }
        if now >= nextContextUsage, hasCcsendstats, contextUsageSeries.isEmpty { pending.insert("context") }
        if now >= nextRateLimit, fiveHour == nil, rateLimitError == nil { pending.insert("rate") }
        async let a: () = now >= nextHours ? refreshHours() : ()
        async let b: () = now >= nextCost ? refreshCost() : ()
        async let c: () = now >= nextRateLimit ? refreshRateLimits() : ()
        async let d: () = now >= nextToolStats ? refreshToolStats() : ()
        async let e: () = now >= nextSkills ? refreshSkills() : ()
        async let f: () = refreshStatus()
        async let g: () = now >= nextAttention ? refreshAttention() : ()
        async let i: () = now >= nextBaseline ? refreshBaseline() : ()
        async let j: () = now >= nextContextUsage ? refreshContextUsage() : ()
        async let k: () = now >= nextMemoryGrowth ? refreshMemoryGrowth() : ()
        async let l: () = now >= nextInterrupt ? refreshInterrupt() : ()
        _ = await (a, b, c, d, e, f, g, i, j, k, l)
        if now >= nextHours { nextHours = Date().addingTimeInterval(hoursCostTTL) }
        if now >= nextCost { nextCost = Date().addingTimeInterval(hoursCostTTL) }
        if now >= nextToolStats { nextToolStats = Date().addingTimeInterval(toolStatsTTL) }
        if now >= nextSkills { nextSkills = Date().addingTimeInterval(skillsTTL) }
        if now >= nextAttention { nextAttention = Date().addingTimeInterval(attentionTTL) }
        if now >= nextBaseline { nextBaseline = Date().addingTimeInterval(baselineTTL) }
        if now >= nextContextUsage { nextContextUsage = Date().addingTimeInterval(contextUsageTTL) }
        if now >= nextMemoryGrowth { nextMemoryGrowth = Date().addingTimeInterval(memoryGrowthTTL) }
        if now >= nextInterrupt { nextInterrupt = Date().addingTimeInterval(interruptTTL) }
        lastRefresh = Date()
    }

    private func refreshStatus() async {
        guard let url = URL(string: "https://status.claude.com/api/v2/status.json") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? [String: Any] else { return }
        claudeStatusIndicator = status["indicator"] as? String
        claudeStatusDesc = status["description"] as? String
    }

    private func refreshHours() async {
        defer { pending.remove("hours") }
        guard let bin = cchoursPath else { return }
        let since = isoDay.string(from: Date().addingTimeInterval(-29 * 86400))
            .replacingOccurrences(of: "-", with: "")
        // Tuple literal elements evaluate **sequentially**, so bundling
        // calls into one Task.detached doesn't parallelize them (measured:
        // this exact mistake caused skill-fire stats to return nil on a 60s timeout).
        async let todayT: Any? = Task.detached(priority: .userInitiated) { runJSON(bin, ["--today", "--json"]) }.value
        async let d30T: Any? = Task.detached(priority: .userInitiated) { runJSON(bin, ["--days", "30", "--json"]) }.value
        async let dailyT: Any? = Task.detached(priority: .userInitiated) { runJSON(bin, ["--daily", "--since", since, "--json"]) }.value
        // Reuse grid[day][hour] from --card's SVG output — no separate --grid flag.
        async let cardT: Any? = Task.detached(priority: .userInitiated) { runJSON(bin, ["--card", "--json", "--since", since]) }.value
        let (today, d30, daily, card) = await (todayT, d30T, dailyT, cardT)
        if let today = today as? [String: Any] {
            agentHoursToday = today["agentHours"] as? Double
        }
        if let d30 = d30 as? [String: Any] {
            agentHours30 = d30["agentHours"] as? Double
        }
        if let daily = daily as? [String: Any], let rows = daily["daily"] as? [[String: Any]] {
            dailyHours = rows.compactMap { row in
                guard let ds = row["date"] as? String, let d = isoDay.date(from: ds),
                      let h = row["agentHours"] as? Double else { return nil }
                let longest = row["longestRunHours"] as? Double ?? 0
                let parallelism = row["parallelism"] as? Double ?? 0
                let subHours = row["subagentHours"] as? Double ?? 0
                let subShare = h > 0 ? subHours / h : 0
                return DailyPoint(date: d, agentHours: h, longestRunHours: longest, parallelism: parallelism, subShare: subShare)
            }
        }
        if let card = card as? [String: Any], let grid = card["grid"] as? [[Any]] {
            hourlyHeatmap = grid.map { day in day.map { ($0 as? NSNumber)?.doubleValue ?? 0 } }
        }
    }

    private func refreshCost() async {
        defer { pending.remove("cost") }
        guard let bin = ccusagePath else { return }
        let since = isoDay.string(from: Date().addingTimeInterval(-29 * 86400))
            .replacingOccurrences(of: "-", with: "")
        let daily: Any? = await Task.detached(priority: .userInitiated) {
            runJSON(bin, ["daily", "--since", since, "--breakdown", "--json"])
        }.value
        if let daily = daily as? [String: Any],
           let days = daily["daily"] as? [[String: Any]] {
            var points: [CostPoint] = []
            var todayC = 0.0, todayT = 0.0, rangeC = 0.0, rangeT = 0.0
            var dayCost: [Date: Double] = [:], dayTokens: [Date: Double] = [:]
            // Tallied separately, same split as ccsendstats' realIn/out — don't invent a new definition.
            var dayInput: [Date: Double] = [:], dayOutput: [Date: Double] = [:]
            let todayKey = isoDay.string(from: Date())
            for day in days {
                // ccusage renamed the date key from "date" to "period" in
                // v20. Reading only one silently skips every row, showing
                // "$0 / 0 tokens" — wrong but real-looking. Homebrew here is
                // v18 (date); the README's npm install is v20 (period).
                guard let ds = (day["date"] as? String) ?? (day["period"] as? String),
                      let d = isoDay.date(from: ds),
                      let models = day["modelBreakdowns"] as? [[String: Any]] else { continue }
                let isToday = ds == todayKey
                for m in models {
                    guard let name = m["modelName"] as? String, let c = m["cost"] as? Double else { continue }
                    points.append(CostPoint(date: d, model: name.replacingOccurrences(of: "claude-", with: ""), cost: c))
                    rangeC += c
                    if isToday { todayC += c }
                    var tok = 0.0
                    for key in ["inputTokens", "outputTokens", "cacheCreationTokens", "cacheReadTokens"] {
                        tok += (m[key] as? Double) ?? 0
                    }
                    rangeT += tok
                    if isToday { todayT += tok }
                    dayCost[d, default: 0] += c
                    dayTokens[d, default: 0] += tok
                    let out = (m["outputTokens"] as? Double) ?? 0
                    dayOutput[d, default: 0] += out
                    dayInput[d, default: 0] += tok - out
                }
            }
            efficiencySeries = dayCost.keys.sorted().map { d in
                let tok = dayTokens[d] ?? 0
                let perMtok = tok > 0 ? (dayCost[d] ?? 0) / tok * 1_000_000 : 0
                return EfficiencyPoint(date: d, perMtok: perMtok, totalTokens: tok,
                                       inputTokens: dayInput[d] ?? 0, outputTokens: dayOutput[d] ?? 0)
            }
            let allDates = Array(Set(points.map(\.date))).sorted()
            let allModels = Array(Set(points.map(\.model)))
            var byKey: [String: Double] = [:]
            for p in points { byKey["\(p.date.timeIntervalSince1970)|\(p.model)"] = p.cost }
            var filled: [CostPoint] = []
            for d in allDates {
                for m in allModels {
                    filled.append(CostPoint(date: d, model: m, cost: byKey["\(d.timeIntervalSince1970)|\(m)"] ?? 0))
                }
            }
            costSeries = filled
            costToday = todayC
            cost30 = rangeC
            tokensToday = todayT
            tokens30 = rangeT
        }
    }

    /// Reads Claude Code's own OAuth token — Keychain first (macOS standard
    /// storage), falling back to ~/.claude/.credentials.json. Read-only: this
    /// never writes back or refreshes an expired token, unlike the personal
    /// claude-usage-api.sh this was modeled on — a distributed app should not
    /// be mutating someone's credential store.
    //
    // Measured: calling SecItemCopyMatching directly would scope the ACL
    // tighter, but before the item is registered it hangs indefinitely on
    // real hardware even with interactionNotAllowed=true (specific to
    // command-line launches) — uses `/usr/bin/security` shell-out instead.
    nonisolated private func readAccessToken() -> String? {
        let service = "Claude Code-credentials"
        let account = NSUserName()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        // First run's Keychain dialog needs a password for "Always Allow" —
        // a 5s timeout would always kill it early; 45s gives room to finish.
        let deadline = Date().addingTimeInterval(45)
        while p.isRunning && Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate() } else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !s.isEmpty, let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
               let oauth = obj["claudeAiOauth"] as? [String: Any],
               let token = oauth["accessToken"] as? String {
                return token
            }
        }
        let credsPath = NSHomeDirectory() + "/.claude/.credentials.json"
        if let data = FileManager.default.contents(atPath: credsPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let oauth = obj["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String {
            return token
        }
        return nil
    }

    private func refreshRateLimits() async {
        defer { pending.remove("rate") }
        let token = await Task.detached(priority: .userInitiated) { self.readAccessToken() }.value
        guard let token else {
            hasCredentials = false
            rateLimitError = T("Not signed in (run claude to log in)")
            nextRateLimit = Date().addingTimeInterval(rateLimitBaseTTL)
            return
        }
        hasCredentials = true

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("claude-cli/2.1.220 (external, cli)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        var usage: [String: Any]?
        var statusCode = 0
        if let (data, response) = try? await URLSession.shared.data(for: req) {
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            usage = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        guard let usage, statusCode == 200, let limits = usage["limits"] as? [[String: Any]] else {
            rateLimitError = statusCode == 401
                ? T("Login expired (run claude once)")
                : statusCode == 429
                ? T("Rate limited (will retry on the next refresh)")
                : T("Could not fetch rate limits")
            if ProcessInfo.processInfo.environment["CCWATCH_DEBUG_RATELIMIT"] != nil {
                let ts = ISO8601DateFormatter().string(from: Date())
                FileHandle.standardError.write(
                    "[\(ts)] rateLimits FAILED: statusCode=\(statusCode) hasUsage=\(usage != nil) rawKeys=\(usage?.keys.sorted() ?? [])\n"
                        .data(using: .utf8)!)
            }
            // Exponential backoff only on 429 (401/others retry at base interval); capped at 15 min.
            if statusCode == 429 {
                consecutive429 = min(consecutive429 + 1, 4)
                let backoff = rateLimitBaseTTL * pow(2, Double(consecutive429))
                nextRateLimit = Date().addingTimeInterval(min(backoff, 900))
            } else {
                consecutive429 = 0
                nextRateLimit = Date().addingTimeInterval(rateLimitBaseTTL)
            }
            return
        }
        consecutive429 = 0
        nextRateLimit = Date().addingTimeInterval(rateLimitBaseTTL)
        rateLimitError = nil
        scopedLimits = []
        func iso(_ s: String) -> Date? { ISO8601DateFormatter.flexible.date(from: s) }
        var seenKinds: [String] = []
        var droppedKinds: [String] = []
        for l in limits {
            let rawKind = l["kind"] as? String ?? "<nil>"
            guard let kind = l["kind"] as? String, let p = l["percent"] as? Int,
                  let rs = l["resets_at"] as? String, let r = iso(rs) else {
                droppedKinds.append(rawKind)
                continue
            }
            seenKinds.append(kind)
            switch kind {
            case "session": fiveHour = RateWindow(usedPct: p, resetsAt: r)
            case "weekly_all": sevenDay = RateWindow(usedPct: p, resetsAt: r)
            case "weekly_scoped":
                let scope = l["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let name = (model?["display_name"] as? String) ?? "model"
                scopedLimits.append(ScopedLimit(name: name, pct: p, resetsAt: r))
            default: break
            }
        }
        if ProcessInfo.processInfo.environment["CCWATCH_DEBUG_RATELIMIT"] != nil {
            let ts = ISO8601DateFormatter().string(from: Date())
            FileHandle.standardError.write(
                "[\(ts)] rateLimits: seen=\(seenKinds) dropped=\(droppedKinds) sevenDay=\(sevenDay != nil) scopedCount=\(scopedLimits.count)\n"
                    .data(using: .utf8)!)
        }
    }

    private func refreshToolStats() async {
        defer { pending.remove("tool") }
        guard let bin = ccflakyPath else { return }
        // Same tuple-sequential trap as refreshHours — separate async lets.
        async let todayT: Any? = Task.detached(priority: .userInitiated) { runJSON(bin, ["--json", "--days", "1"]) }.value
        async let dailyT: Any? = Task.detached(priority: .userInitiated) { runJSON(bin, ["--daily", "--json", "--days", "30"]) }.value
        let (today, daily) = await (todayT, dailyT)
        if let today = today as? [String: Any] {
            toolCallsToday = today["total"] as? Int
            // "Recent" = most-recent-day rate — 30-day average is already on the errorRateSeries chart.
            toolErrorRate = today["errorRate"] as? Double
            if let rows = today["rows"] as? [[String: Any]] {
                // 1-day sample is smaller than 30-day — relax threshold (calls>=20 showed almost nothing).
                topFailingTools = rows.compactMap { r in
                    guard let name = r["name"] as? String, let calls = r["calls"] as? Int,
                          let rate = r["errorRate"] as? Double, calls >= 5, rate >= 5 else { return nil }
                    return ToolFailure(name: name, calls: calls, errorRate: rate)
                }.sorted { $0.errorRate > $1.errorRate }.prefix(3).map { $0 }
            }
        }
        if let daily = daily as? [String: Any], let rows = daily["daily"] as? [[String: Any]] {
            errorRateSeries = rows.compactMap { row in
                guard let ds = row["date"] as? String, let d = isoDay.date(from: ds),
                      let rate = row["errorRate"] as? Double else { return nil }
                return ErrorRatePoint(date: d, errorRate: rate)
            }.sorted { $0.date < $1.date }
        }
    }

    private func refreshSkills() async {
        defer { pending.remove("skills") }
        guard let bin = ccskillstatsPath else { return }
        // Same tuple-sequential trap as refreshHours — this one caused
        // skill-fire stats to return nil on a 60s timeout until fixed.
        async let allT: Any? = Task.detached(priority: .userInitiated) { runJSON(bin, ["--json"]) }.value
        async let dailyT: Any? = Task.detached(priority: .userInitiated) { runJSON(bin, ["--daily", "--json", "--days", "30"]) }.value
        // "fired/installed" counts over all time (--days 30 would misclassify
        // dormant skills); top 3 fetched separately, limited to 30 days.
        async let recentT: Any? = Task.detached(priority: .userInitiated) { runJSON(bin, ["--json", "--days", "30"]) }.value
        let (all, daily, recent) = await (allT, dailyT, recentT)
        if let all = all as? [String: Any], let skills = all["skills"] as? [[String: Any]] {
            skillsTotal = skills.count
            skillsFired = skills.filter { ($0["total"] as? Int ?? 0) > 0 }.count
        }
        if let recent = recent as? [String: Any], let skills = recent["skills"] as? [[String: Any]] {
            topSkills = skills.compactMap { s -> SkillFire? in
                guard let name = s["name"] as? String, let total = s["total"] as? Int, total > 0 else { return nil }
                return SkillFire(name: name, total: total)
            }.sorted { $0.total > $1.total }.prefix(3).map { $0 }
        }
        if let daily = daily as? [String: Any], let periods = daily["periods"] as? [[String: Any]] {
            skillsSeries = periods.compactMap { row in
                guard let ds = row["key"] as? String, let d = isoDay.date(from: ds),
                      let total = row["total"] as? Int else { return nil }
                return SkillPoint(date: d, total: Double(total))
            }.sorted { $0.date < $1.date }
            // Same daily response already has the tool/typed/auto breakdown — no new fetch.
            skillFireKindSeries = periods.flatMap { row -> [SkillFireKindRow] in
                guard let ds = row["key"] as? String, let d = isoDay.date(from: ds) else { return [] }
                let tool = Double(row["tool"] as? Int ?? 0)
                let typed = Double(row["typed"] as? Int ?? 0)
                let total = Double(row["total"] as? Int ?? 0)
                let auto = max(0, total - tool - typed)
                return [
                    SkillFireKindRow(date: d, kind: "tool", count: tool),
                    SkillFireKindRow(date: d, kind: "typed", count: typed),
                    SkillFireKindRow(date: d, kind: "auto", count: auto),
                ]
            }.sorted { $0.date < $1.date }
        }
    }

    // ccsendstats --daily --cache tallies input tokens by billing rate; it
    // re-reads every transcript, so shares ccskillstats/ccflaky's 900s TTL.
    private func refreshBaseline() async {
        guard let bin = ccsendstatsPath else { return }
        let raw = await Task.detached(priority: .userInitiated) {
            runJSON(bin, ["--daily", "--baseline", "--days", "30", "--json"])
        }.value
        guard let obj = raw as? [String: Any], let days = obj["daily"] as? [[String: Any]] else { return }
        baselineSeries = days.compactMap { row -> BaselinePoint? in
            guard let ds = row["date"] as? String, let d = isoDay.date(from: ds),
                  let avg = row["avgBaseline"] as? Double,
                  let sessions = row["sessions"] as? Int else { return nil }
            return BaselinePoint(date: d, avgBaseline: avg, sessions: sessions)
        }
    }

    private func refreshInterrupt() async {
        guard let bin = ccsendstatsPath else { return }
        let raw = await Task.detached(priority: .userInitiated) {
            runJSON(bin, ["--daily", "--interrupt", "--days", "30", "--json"])
        }.value
        guard let obj = raw as? [String: Any], let days = obj["daily"] as? [[String: Any]] else { return }
        interruptSeries = days.compactMap { row -> InterruptPoint? in
            guard let ds = row["date"] as? String, let d = isoDay.date(from: ds),
                  let rate = row["interruptRate"] as? Double,
                  let total = row["total"] as? Int else { return nil }
            return InterruptPoint(date: d, interruptRate: rate, total: total)
        }
    }

    private func refreshContextUsage() async {
        defer { pending.remove("context") }
        guard let bin = ccsendstatsPath else { return }
        let raw = await Task.detached(priority: .userInitiated) {
            runJSON(bin, ["--daily", "--days", "30", "--json"])
        }.value
        guard let obj = raw as? [String: Any], let days = obj["daily"] as? [[String: Any]] else { return }
        contextUsageSeries = days.compactMap { row -> ContextUsagePoint? in
            guard let ds = row["date"] as? String, let d = isoDay.date(from: ds),
                  let p25 = row["p25Pct"] as? Double, let p50 = row["p50Pct"] as? Double,
                  let p75 = row["p75Pct"] as? Double else { return nil }
            return ContextUsagePoint(date: d, p25Pct: p25, p50Pct: p50, p75Pct: p75)
        }
    }

    // Only card with no CLI — stats ~/.claude/projects/<slug>/memory/*.md
    // directly via FileManager, summing mtime+size per category to
    // reconstruct cumulative tokens by day.
    private func refreshMemoryGrowth() async {
        let home = NSHomeDirectory()
        let slug = home.replacingOccurrences(of: "/", with: "-")
        let dir = home + "/.claude/projects/" + slug + "/memory"
        let entries = await Task.detached(priority: .userInitiated) { () -> [(Date, String, Int)] in
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
            var out: [(Date, String, Int)] = []
            for f in files where f.hasSuffix(".md") && f != "MEMORY.md" {
                let path = dir + "/" + f
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mtime = attrs[.modificationDate] as? Date,
                      let size = attrs[.size] as? Int else { continue }
                // Source of truth is frontmatter's `type:` — the filename
                // prefix is a fallback only (else other users' files all land in reference).
                var category = "reference"
                if let head = (try? String(contentsOfFile: path, encoding: .utf8))?.prefix(400),
                   let r = head.range(of: "type:[ \t]*(user|feedback|project|reference)",
                                      options: .regularExpression) {
                    category = head[r].split(separator: ":").last.map {
                        $0.trimmingCharacters(in: .whitespaces)
                    } ?? "reference"
                } else if f.hasPrefix("feedback_") { category = "feedback" }
                else if f.hasPrefix("project_") { category = "project" }
                else if f.hasPrefix("user_") { category = "user" }
                out.append((mtime, category, size))
            }
            return out.sorted { $0.0 < $1.0 }
        }.value
        guard !entries.isEmpty else { return }
        // Cumulative is computed over full history (back through March), but
        // display caps at 30 days — else labels overlap on a 6-month axis (measured).
        var running: [String: Double] = [:]
        var byDay: [Date: [String: Double]] = [:]
        let cal = Calendar.current
        for (date, category, bytes) in entries {
            running[category, default: 0] += Double(bytes) / 4  // ~4 bytes/token estimate (same as ccsendstats)
            byDay[cal.startOfDay(for: date)] = running
        }
        let cutoff = cal.startOfDay(for: Date().addingTimeInterval(-30 * 86400))
        memoryGrowthSeries = byDay.keys.filter { $0 >= cutoff }.sorted().flatMap { day in
            byDay[day]!.map { category, tokens in
                MemoryGrowthPoint(date: day, category: category, cumulativeTokens: tokens)
            }
        }
    }

    private func refreshAttention() async {
        defer { pending.remove("attention") }
        guard let bin = attentionPath else { return }
        let raw = await Task.detached(priority: .userInitiated) {
            runJSON(bin, ["--json", "--days", "30"])
        }.value
        guard let byDay = raw as? [String: Any] else { return }
        // Skipping the assignment when today has no key would leave
        // @Published showing yesterday's value under "Today:" — reset to nil.
        let todayKey = isoDay.string(from: Date())
        if let today = byDay[todayKey] as? [String: Any],
           let user = today["user"] as? Int, let threads = today["threads"] as? Int, threads > 0 {
            attentionPerThreadToday = Double(user) / Double(threads)
        } else {
            attentionPerThreadToday = nil
        }
        attentionSeries = byDay.compactMap { key, v -> AttentionPoint? in
            guard let d = isoDay.date(from: key), let dict = v as? [String: Any],
                  let user = dict["user"] as? Int, let threads = dict["threads"] as? Int, threads > 0
            else { return nil }
            let mineChars = (dict["mine_chars"] as? Double) ?? Double(dict["mine_chars"] as? Int ?? 0)
            let blocks = (dict["blocks"] as? Int) ?? 0
            let mine = (dict["mine"] as? Int) ?? 0
            let selffix = (dict["selffix"] as? Int) ?? 0
            return AttentionPoint(date: d, perThread: Double(user) / Double(threads),
                                   charsPerThread: mineChars / Double(threads),
                                   blocksPerThread: Double(blocks) / Double(threads),
                                   selffixRate: mine > 0 ? Double(selffix) / Double(mine) * 100 : 0,
                                   blocksRaw: blocks)
        }.sorted { $0.date < $1.date }
    }
}
