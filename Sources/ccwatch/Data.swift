// ccwatch — self-contained Claude Code usage menu bar app.
//
// Unlike ccmenubar-app (this author's personal build, which reads cache
// files a private xbar plugin writes), ccwatch shells out directly to the
// public companion CLIs (cchours, ccusage, ccattention, ccflaky,
// ccskillstats, ccsendstats) and to
// Anthropic's own oauth/usage endpoint. Any card whose CLI isn't installed
// is simply omitted — graceful degradation, same philosophy as the
// published `ccmenubar` xbar plugin.

import SwiftUI
import Foundation
import Charts
import AppKit

// MARK: - CLI discovery

/// GUI apps launched by LaunchServices get a minimal PATH (no Homebrew, no
/// npm global bin). Check common install locations first, then fall back to
/// asking a login shell — the same PATH the user's own terminal would use.
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
    // nvm / fnm / mise は node のバージョンごとにディレクトリを掘るので、
    // 固定パスでは当たらない。これらは PATH を .zshrc に書くのが既定で、
    // 下の `zsh -l` は **.zshrc を読まない**(非対話 login shell)。
    // つまりこの層が無いと、npm install -g 済みでも全カードが無言で消える。
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
    // login shell 起動が固まる(壊れた dotfile 等)と waitUntilExit() が無期限に
    // ブロックし、これが Snapshot の init から呼ばれるためメニューバー自体が
    // 出てこなくなる。上限を設けて越えたら打ち切る。
    let deadline = Date().addingTimeInterval(5)
    while p.isRunning && Date() < deadline { usleep(20_000) }
    if p.isRunning {
        p.terminate()
        // terminate() はSIGTERMを送るだけで即終了を保証しない。後始末をせず
        // returnするとゾンビ化しうる — 短く待って回収する(レビューで発見)。
        let killDeadline = Date().addingTimeInterval(1)
        while p.isRunning && Date() < killDeadline { usleep(20_000) }
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (out?.isEmpty == false) ? out : nil
}

/// Runs a CLI already resolved to an absolute path and parses its stdout as
/// JSON. Some of these (ccskillstats/ccflaky on a large transcript history,
/// ccusage on 30 days of usage) genuinely take 30-60s+ — measured directly
/// (ccusage: 31.7s, ccskillstats --days 30: 60s+) — so the timeout here is
/// generous. Reads the pipe continuously while the process runs, not just
/// after it exits: waiting until exit to read risks a real deadlock once
/// output exceeds the ~64KB kernel pipe buffer, since the child then blocks
/// on write() with nobody draining the other end.
/// 既定は 180 秒。上のコメント自身が「ccskillstats --days 30: 60s+」と
/// 実測を書いているのに 60 秒で切っていたので、履歴の大きい人ではスキル発火
/// カードが毎回タイムアウトし、永続的に無言で欠落していた。
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
    // stderrも読み続けないと、子が大量に書いた時に64KBのkernelパイプバッファが
    // 埋まってwrite()でブロックする — stdoutだけ対策してこちらを放置していた
    // (実測でCPUを焼き続ける原因の一つ)。中身は使わないので読んで捨てるだけ。
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
    // cchours --daily が同じレスポンスで返す値(実測: 日次で並列度1.0〜1.9台、
    // 委譲率(subagentHours/agentHours)は0.8%〜56%と大きく動く。新規fetch不要)。
    let parallelism: Double
    let subShare: Double
}

struct CostPoint: Identifiable {
    let id = UUID()
    let date: Date
    let model: String
    let cost: Double
}

/// $/1Mトークン。キャッシュ読込が多いほど下がる — 下がっている方が
/// 良い使い方(元のxbarプラグインの per_mtok と同じ発想)。
struct EfficiencyPoint: Identifiable {
    let id = UUID()
    let date: Date
    let perMtok: Double
    let totalTokens: Double
    // 入力側(uncached input + cache_creation + cache_read)と出力側
    // (output)は性質が違う — 入力は文脈量、出力は生成量。合算した
    // totalTokens だけでは「読む量が多いのか書く量が多いのか」が消える。
    let inputTokens: Double
    let outputTokens: Double
}

/// 会話の中身に関係なく毎回乗っている固定費(system prompt+CLAUDE.md+
/// メモリ+ツール定義など、最初の一言より前の実測トークン)の日別平均
/// (ccsendstats --daily --baseline)。キャッシュ内訳・入出力比は30〜50セッション/日
/// を混ぜると帯域に収束して動かなくなることを実測で確認済みだが、これは
/// 実際に週単位で動く(実測: 9日で約33k→52k)。
/// 実行中に次のプロンプトを送った割合(ccsendstats --daily --interrupt)。
/// トークンではなく行動の指標 — 実測30日で0%→100%まで明確な上昇トレンド
/// (待たずに次を投げるスタイルへの変化を捉えている、日次でもノイズに埋もれない)。
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
    // ccsendstats --daily --baseline が既に返す値(コスト推移・peak%等の
    // ノイズの多くを説明する文脈: 実測で2〜54と大きく動く)。
    let sessions: Int
}

/// コンテキスト窓使用率の日別分布(ccsendstats --daily)。peakは「その日一番長く
/// 続いたセッション」で決まりがちで、セッション数が多い日ほど構造的に
/// 上限へ張り付く(実測: ほぼ毎日90%台で固定・示唆なし)。p50(中央値)は
/// 実際に動く(実測: 9日で16.7%〜63%)ので、peakではなくp50を見せる。
struct ContextUsagePoint: Identifiable {
    let id = UUID()
    let date: Date
    let p25Pct: Double
    let p50Pct: Double
    let p75Pct: Double
}

/// 会話開始前の固定費(baseline)の内訳候補。system prompt・ツール定義は
/// transcriptに残らないため積み上げできない(ccsendstatsのproxy節参照)が、
/// auto memoryファイル(~/.claude/projects/<slug>/memory/*.md)は
/// mtime+サイズが直接読めるので、種別(MEMORY.mdと同じuser/feedback/
/// project/reference分類)ごとの累積推定トークン数を日別に再構成できる。
/// 実測: 8/15の約1.2kトークンから8/22の約19.1kトークンまで増加していて、
/// baselineの伸び(約33k→52k、+19k)とほぼ一致 — baseline増加の主因の
/// 少なくとも一部と見てよい。CLAUDE.md本体・スキルは単一ファイルでmtimeが
/// 「最後に触った日」しか示さず過去の変遷を再構成できないため含まない。
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

/// スキル発火の「誰が呼んだか」— tool(Claudeが会話中に自主的に選んだ)/
/// typed(自分で/nameと打った)/auto(cron等の自動化)。実測: autoが63%、
/// toolはわずか17% — descriptionが会話中に拾われているかの診断材料になる。
struct SkillFireKindRow: Identifiable {
    let id = UUID()
    let date: Date
    let kind: String
    let count: Double
}

/// あなたが払った手間。私の饒舌さや稼働時間ではなく、1つの用件を通すのに
/// 何回打ったか(perThread)が主指標 — xbarプラグイン claude-limits.1m.sh の
/// attention節と同じ計算式。
struct AttentionPoint: Identifiable {
    let id = UUID()
    let date: Date
    let perThread: Double
    let charsPerThread: Double
    let blocksPerThread: Double
    let selffixRate: Double
    // 用件(スレッド)で割らない生の差し戻し件数。用件の定義は微妙という指摘で
    // per-thread正規化した指標は撤去したが、生の件数自体は定義に依存しない。
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

// @MainActor: @Published の書き込みは MenuBarExtra の裏にある NSMenu の
// 更新につながり、メインスレッド以外から書くと NSAssertionHandler が
// abort する(実測でクラッシュした — -[NSMenu itemArray] 経由)。
// 一方 refresh() 自身は CLI をshell out・ネットワークを叩くブロッキング
// 処理を含み(数秒かかりうる)、MainActor上で同期実行すると今度は
// メニューバー項目の初期描画がブロックされて出てこなくなる(これも実測)。
// 正しい形は「重い処理だけ Task.detached に逃がし、await で結果を受けたら
// 自動的にMainActorへ戻ってから@Publishedへ代入する」— refresh()自体は
// asyncにして、ブロッキング呼び出しをそれぞれ detached task で包む。
@MainActor
final class Snapshot: ObservableObject {
    @Published var hasCchours = false
    @Published var hasCcusage = false
    @Published var hasCcflaky = false
    @Published var hasCcskillstats = false
    /// まだ結果が返っていないカードのキー。CLIはあるがデータが空、という
    /// 状態を「無い」と区別するために持つ。これが無いと、重いCLI(実測で
    /// 60秒超)が返るまでカードがただ存在しないのと同じ見た目になり、
    /// 壊れているのか集計中なのかがユーザーに区別できない。
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

    // findCLI は候補パスで見つからないとログインシェルを起動する(最大5秒)。
    // 5本を `let` の初期化子として書くと Snapshot() 生成時に**逐次**5回呼ばれ、
    // 最悪25秒 MainActor をブロックする(このファイル冒頭のコメントが警告する
    // 「MainActor上の同期ブロッキングでメニューバー項目が出てこない」実測済みの
    // 症状そのものを、initの経路で再現していた — レビューで発見)。
    // var にして起動直後に非同期で並行解決する。
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

    // ccskillstats 等が90秒超かかることがある(README記載)。次のtimer tickが
    // それより早く来ると多重実行になり、レート制限エンドポイントを余計に
    // 叩く原因になる — 実行中は次呼び出しを素通りさせる。
    private var isRefreshing = false

    // 60秒ごとのtimerで毎回、全transcript履歴を舐めるCLIまで呼ぶと、実測で
    // 4本のnodeがほぼ常時100% CPU(duty cycleがほぼ1.0)になった。レート制限
    // (軽いHTTP)とstatus(同)は毎tickで問題ないが、cchours/ccusage/ccflaky/
    // ccskillstatsは「値の鮮度」より「常時焼かない」を優先し、xbarプラグイン
    // (claude-limits.1m.sh)が実運用で使っているキャッシュ間隔をそのまま踏襲する
    // (cchours=5分キャッシュ、ccflaky/ccskillstatsは1日分900秒・30日分含む
    // 呼び出しは3600秒)。
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
    // --baselineは全セッションの全文を読む(--cacheはusage合計だけで済む)ので
    // 最も重い部類 — attentionと同じ30分間隔にする。
    private let baselineTTL: TimeInterval = 1800
    private let interruptTTL: TimeInterval = 1800
    // --daily(peak/avg/p50)はusage合計だけで済む(--cacheと同じ軽さ)。
    private let contextUsageTTL: TimeInterval = 900
    // ローカルファイルのstatだけなので軽い。CLI呼び出しではない。
    private let memoryGrowthTTL: TimeInterval = 900
    // /api/oauth/usage 自体がアカウント単位で厳しくレート制限されている
    // (実測: 60秒間隔でポーリングすると2回に1回429、実機のclaude CLI等
    // 他プロセスの呼び出しと衝突すると3回以上連続で429することも確認)。
    // 60秒tickのたびに叩くと自ら制限にぶつかり続け、結果が返らない限り
    // fiveHour/sevenDayが更新されず「hだけ出てwが出ない」状態が長時間
    // 固定化する。基本間隔を180秒に緩め、429が続いたら指数バックオフする。
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

        // 並行に開始する。各 refreshX は自分の重い処理を Task.detached に
        // 逃がしてから await するので、MainActor 上の記帳は一瞬で次へ移り、
        // バックグラウンドの実作業は実質並列に進む(逐次だとccusage 32秒+
        // ccskillstats 60秒+…の合計待ちになり、大きい履歴では数分かかる)。
        // 重いCLI呼び出しはTTLが満ちている時だけ実際に叩く。
        let now = Date()
        // 既に値が入っているカードは pending にしない — 定期更新のたびに
        // 中身がスケルトンへ戻ると、画面がちらついて読めなくなる。
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
        // タプルリテラルの各要素は左から順に**逐次**評価されるため、1本の
        // Task.detached にまとめても並列にはならない(実測: スキル発火の
        // 全体集計が60秒タイムアウトで毎回nilのまま出なかった原因の1つが
        // この誤りのコピー — 呼び出し元のコメントは「並列」と書いていたが
        // 実際は最悪3本ぶん逐次で待つ形になっていた)。呼び出しごとに
        // 別のasync letで包み、実際に並行させる。
        async let todayT: Any? = Task.detached(priority: .userInitiated) { runJSON(bin, ["--today", "--json"]) }.value
        async let d30T: Any? = Task.detached(priority: .userInitiated) { runJSON(bin, ["--days", "30", "--json"]) }.value
        async let dailyT: Any? = Task.detached(priority: .userInitiated) { runJSON(bin, ["--daily", "--since", since, "--json"]) }.value
        // ヒートマップ用の時間帯グリッド。--card がSVGカード用に持っている
        // grid[日][時] をそのまま流用する(--gridという独立フラグは無い)。
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
            // 入力側(uncached + cache_creation + cache_read)と出力側は別集計
            // (ccsendstatsのrealIn/outと同じ区分。ここに独自の定義を増やさない)。
            var dayInput: [Date: Double] = [:], dayOutput: [Date: Double] = [:]
            let todayKey = isoDay.string(from: Date())
            for day in days {
                // ccusage は v20 で daily 行の日付キーを date → period に改名した
                // (書式は同じ yyyy-MM-dd)。片方しか読まないと、全行が
                // ここで skip されたまま下の代入だけ走り、カードは空になる
                // どころか「$0 / 0トークン」という**誤った実数**を出す。
                // 手元は Homebrew の v18(date)、README が入れさせる npm は
                // v20(period)なので、作者の環境では一生再現しない。
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
    // 試して分かったこと(実測): SecItemCopyMatching をアプリ内から直接呼ぶ方が
    // ACLのスコープはccwatch自身に限定できて理屈上は安全だが、この項目のACLに
    // 未登録の状態から呼ぶと、interactionNotAllowed=true を付けても実機で
    // 無限にハングした(SecurityAgentの認証プロンプトがウィンドウとして
    // 描画されないまま待ち続ける — コマンドライン起動固有の問題と見られる)。
    // ハングする「安全な実装」より、動く `/usr/bin/security` shell-out を
    // タイムアウト付きで使う方を選ぶ。ACLの拡大についてはREADMEに明記する。
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
        // 初回はキーチェーンのアクセス許可ダイアログが出る。「常に許可」は
        // パスワード入力を伴うので、5秒だと必ず間に合わず kill され、
        // 180秒ごとにダイアログが出ては勝手に消える上に「ログイン情報が
        // 見つかりません」という誤診断が固定表示される。人が操作を終える
        // だけの猶予を取る(この呼び出しは detached なので UI は止まらない)。
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
            rateLimitError = "ログイン情報が見つかりません(claude でログインしてください)"
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
                ? "ログインの有効期限が切れています(claude を一度実行してください)"
                : statusCode == 429
                ? "レート制限に達しました(次回更新時に再試行します)"
                : "レート制限を取得できませんでした"
            if ProcessInfo.processInfo.environment["CCWATCH_DEBUG_RATELIMIT"] != nil {
                let ts = ISO8601DateFormatter().string(from: Date())
                FileHandle.standardError.write(
                    "[\(ts)] rateLimits FAILED: statusCode=\(statusCode) hasUsage=\(usage != nil) rawKeys=\(usage?.keys.sorted() ?? [])\n"
                        .data(using: .utf8)!)
            }
            // 429だけ指数バックオフする(サーバー側の窓を自分で埋め続けない
            // ため)。401/その他は一時的な事象の可能性が高いので基本間隔で
            // 素直にリトライする。上限15分。
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
        // 1本のTask.detachedにまとめたタプルは逐次評価される(refreshHours
        // 参照)。呼び出しごとに別のasync letで実際に並行させる。
        async let todayT: Any? = Task.detached(priority: .userInitiated) { runJSON(bin, ["--json", "--days", "1"]) }.value
        async let dailyT: Any? = Task.detached(priority: .userInitiated) { runJSON(bin, ["--daily", "--json", "--days", "30"]) }.value
        let (today, daily) = await (todayT, dailyT)
        if let today = today as? [String: Any] {
            toolCallsToday = today["total"] as? Int
            // 「直近」は直近1日の失敗率にする(指摘) — 30日平均は
            // errorRateSeriesの折れ線側に既に出ているので二重管理しない。
            toolErrorRate = today["errorRate"] as? Double
            if let rows = today["rows"] as? [[String: Any]] {
                // 1日分は30日分よりサンプル数が少ないので閾値を緩める
                // (calls>=20だと当日は主要ツール以外ほぼ出なかった)。
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
        // 同じ誤り(1本のTask.detachedのタプルは逐次評価される)が
        // refreshHours/refreshToolStatsだけ直っていてここに残っていた —
        // まさにこの関数の逐次待ちが「スキル発火が60秒タイムアウトで
        // 毎回nilのまま出なかった」動機そのものだったのに、Fableレビューで
        // 見落としを指摘されるまで直っていなかった。
        async let allT: Any? = Task.detached(priority: .userInitiated) { runJSON(bin, ["--json"]) }.value
        async let dailyT: Any? = Task.detached(priority: .userInitiated) { runJSON(bin, ["--daily", "--json", "--days", "30"]) }.value
        // 「発火数/インストール数」は全期間で数える(--days 30に絞ると
        // 直近未発火のインストール済みスキルの扱いが変わりうるので、
        // 既存の分母はそのまま)。上位3件だけ直近30日に絞った別呼び出しで取る。
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
            // 同じdaily応答に既にtool/typed/autoの内訳が入っている(新規取得なし)。
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

    // xbarプラグイン(claude-limits.1m.sh)にあった「attention（あなたが払った
    // 手間）」節。アプリ化した際に単純に移植し忘れていた項目 — 実際に使って
    // いたユーザーから指摘があり追加(旧xbarと同じ計算式: 用件=threads、
    // 発話数=user、を用件数で割る)。
    // ccsendstatsの --daily --cache は入力トークンを課金レート別(非キャッシュ/
    // キャッシュ書込1h/5m/読込)に日別集計する。ccsendstatsは他のCLI群と違い
    // 全セッションのtranscriptを都度読むので、ccskillstats/ccflakyと
    // 同じ900秒TTLを与える(毎tick叩かない)。
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

    // auto memoryファイルはCLIを経由しない唯一のカード — ローカルの
    // ~/.claude/projects/<home slug>/memory/*.md をFileManagerで直接stat。
    // 各ファイルのmtime+サイズを種別(ファイル名prefix)別に時系列順で足し込み、
    // 「その日までに積み上がった推定トークン数」を種別ごとに再構成する。
    // 単一ファイルの上書き編集(CLAUDE.md本体等)は最終更新日しか分からず
    // 過去のサイズ推移を再構成できないため対象外 — 個別ファイルが多数ある
    // memoryディレクトリだけがこの手法で歴史を持てる。
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
                // 分類の正典は frontmatter の `type:`。ファイル名の接頭辞は
                // この作者の付け方でしかないので、それだけを見ると他人の
                // メモリが全部 reference に落ちて内訳が無意味になる。
                // 接頭辞は type が無いファイル向けのフォールバックに下げる。
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
        // 累積自体は全履歴で計算する(3月分含め正しい値にする)が、表示は他の
        // カードと同じ直近30日に絞る — 絞らないと半年分の横軸に直近の変化が
        // 潰れて見えなくなる(実測: x軸ラベルが重なって読めなくなった)。
        var running: [String: Double] = [:]
        var byDay: [Date: [String: Double]] = [:]
        let cal = Calendar.current
        for (date, category, bytes) in entries {
            running[category, default: 0] += Double(bytes) / 4  // 4 bytes/token概算(ccsendstatsと同じ)
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
        // 今日のキーが無い時に代入をスキップするだけだと、@Publishedは前回の
        // 成功値(前日分など)を保持したまま「今日:」ラベルで出続ける
        // (日付をまたぐと古い値が今日の実績として表示され続ける — レビューで
        // 発見)。該当なしなら明示的にnilへ戻す。
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
