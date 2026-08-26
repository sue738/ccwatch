import SwiftUI
import Charts
import AppKit

// dataviz スキルの検証済みデフォルトパレット(references/palette.md)。
// ライト/ダークそれぞれ用に個別のhexが検証されているので、見た目だけ
// ダークにするのではなく実際にモードごとに違う値を出す。
extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt32(s, radix: 16) ?? 0
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(light: String, dark: String) {
        self = Color(NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        }))
    }
}

/// カテゴリカル配色。固定順で使う(ランクや出現順で塗り替えない) —
/// series-1から順に、CVD安全性が検証済みの並び。
enum Viz {
    // Nordアクセントに寄せて彩度を落としたところ(Fableレビュー指摘への対応)、
    // 今度は「コスト推移の色分けが分かりにくい」との指摘が実際に出た。
    // dataviz スキルの validate_palette.js で検証: 落とした版は light/dark
    // 両方でchroma floor・normal-visionともFAIL(#5e81ac等は彩度不足で
    // 実質グレーとして読める、隣接ペアのΔEが閾値15を割る)。
    // dataviz スキルの検証済みデフォルト(palette.md)に戻す — これはCVD安全性
    // が実測済みの唯一の「カテゴリカル(識別)」用パレットで、目分量での再配色は
    // スキル自体が禁止している("6. Documented palette only")。単一系列の
    // チャート(下のaccentX群)は「識別」ではなく「単一トレンド」の仕事なので
    // 別パレットのままで正しい — 混在ではなく役割の違い。
    static let series: [Color] = [
        Color(light: "#2a78d6", dark: "#3987e5"),  // 1 blue
        Color(light: "#eb6834", dark: "#d95926"),  // 2 orange
        Color(light: "#1baf7a", dark: "#199e70"),  // 3 aqua
        Color(light: "#eda100", dark: "#c98500"),  // 4 yellow
        Color(light: "#e87ba4", dark: "#d55181"),  // 5 magenta
        Color(light: "#008300", dark: "#008300"),  // 6 green
        Color(light: "#4a3aa7", dark: "#9085e9"),  // 7 violet
        Color(light: "#e34948", dark: "#e66767"),  // 8 red
    ]
    static let statusGood = Color(light: "#0ca30c", dark: "#0ca30c")
    // dataviz スキルの documented palette(palette.md)どおりの値に戻す。
    // ライト面でのコントラスト不足(1.79:1)はpalette.md自身が「by design」
    // として明記しており、ステータス色は文字の色自体には使わずアイコンだけに
    // 使う設計が正しい緩和策(このファイル内の実際の使用箇所は既にアイコン限定
    // になっている)。Fableレビューの指摘を受けてこの値を勝手に変えたのは
    // 誤りだった("Documented palette only" — ステータス色はテーマ化しない)。
    static let statusWarning = Color(light: "#fab219", dark: "#fab219")
    static let statusCritical = Color(light: "#d03b3b", dark: "#d03b3b")
    /// 単一系列のグラフ用の落ち着いたインク色(palette.mdの secondary ink)。
    /// カテゴリカルなseries色は「識別」の仕事をする色 — 1系列しか無い
    /// グラフに割り当てても区別する相手が無く、ただ派手なだけになる
    /// (指摘: 「原色系が多くて洗練されていない」)。モデル別コストのような
    /// 本当に複数系列を区別する場面だけ series を使う。
    static let ink = Color(light: "#52514e", dark: "#c3c2b7")

    /// グレー一色は「素っ気ない」という指摘(開発者に馴染みのあるエディタ
    /// 配色に寄せたい)を受けて、Nordテーマ(彩度を抑えた寒色系、開発者に
    /// 定番の配色)からアクセントを抜粋。カテゴリカルseriesほど鮮やかでは
    /// ないが、grayscale一色よりは個性が残る — 単一系列チャートの
    /// 「どのカードか」を色でも軽く手掛かりにする。
    static let accentBlue = Color(light: "#5e81ac", dark: "#81a1c1")     // nord10/9
    static let accentCyan = Color(light: "#5b8b96", dark: "#88c0d0")     // nord8
    static let accentPurple = Color(light: "#946c99", dark: "#b48ead")   // nord15
    static let accentOrange = Color(light: "#c67a4e", dark: "#d08770")   // nord12
    static let accentRed = Color(light: "#a8555f", dark: "#bf616a")      // nord11
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(.primary)
            .tracking(0.5)
    }
}

struct DashStat: View {
    let icon: String
    let color: Color
    let label: String
    let today: String?
    let range: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(color)
                Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(today ?? "–").font(.system(size: 19, weight: .bold, design: .rounded))
            Text("30日 " + (range ?? "–")).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// 経過率(0-100)。窓の開始からいま何%進んだか — 使用率の基準線。
func elapsedPercent(resetsAt: Date, windowHours: Double) -> Double {
    let now = Date()
    let windowStart = resetsAt.addingTimeInterval(-windowHours * 3600)
    let elapsed = now.timeIntervalSince(windowStart)
    return max(0.1, min(100, elapsed / (windowHours * 3600) * 100))
}

// 経過率が10%未満の窓でペース比を出すと、リセット直後に少し使っただけで
// 比が跳ね上がり赤ドットの誤警報になる(xbarプラグイン claude-limits.1m.sh の
// 参照実装・CLAUDE.mdが明記する既存ルールをこのSwift版だけ落としていた —
// レビューで発見)。経過10%未満は判定しない(nil)。
func paceRatio(usedPct: Int, resetsAt: Date, windowHours: Double) -> Double? {
    let elapsedPct = elapsedPercent(resetsAt: resetsAt, windowHours: windowHours)
    guard elapsedPct >= 10 else { return nil }
    return Double(usedPct) / elapsedPct
}

func paceColor(_ ratio: Double?) -> Color {
    guard let ratio else { return .primary }
    if ratio <= 1.0 { return Viz.statusGood }
    if ratio <= 1.15 { return Viz.statusWarning }
    return Viz.statusCritical
}

/// 時間帯×日のアクティビティ・ヒートマップ。GitHubのcontribution graph
/// (通称「草」)と同じ緑ランプを使う — 見た目の馴染みが指標の読み方を
/// そのまま運んでくる(濃い=よく動いた)ので、ここでは既存の共通認識に
/// 乗る方が伝わる。sequential(1色をlight→darkで濃くする)という
/// dataviz スキルの原則自体は満たしている。
struct HoursHeatmap: View {
    let grid: [[Double]] // grid[dayIndex][hour], hour 0-23

    // GitHub contribution graph の4段(light: #9be9a8/#40c463/#30a14e/#216e39)。
    // ダーク面は GitHub 自身のダークテーマ側の値(#0e4429/#006d32/#26a641/#39d353)。
    private static let ramp: [Color] = [
        Color(light: "#9be9a8", dark: "#0e4429"),
        Color(light: "#40c463", dark: "#006d32"),
        Color(light: "#30a14e", dark: "#26a641"),
        Color(light: "#216e39", dark: "#39d353"),
    ]
    private static let emptyCell = Color.primary.opacity(0.05)

    static func legendColor(_ i: Int) -> Color { i == 0 ? emptyCell : ramp[min(i - 1, ramp.count - 1)] }

    private var maxSeconds: Double { max(grid.flatMap { $0 }.max() ?? 0, 1) }

    private func color(_ v: Double) -> Color {
        guard v > 0 else { return Self.emptyCell }
        let t = min(1.0, sqrt(v / maxSeconds))
        let idx = min(Self.ramp.count - 1, Int(t * Double(Self.ramp.count)))
        return Self.ramp[idx]
    }

    var body: some View {
        let hourCount = grid.first?.count ?? 24
        let dayCount = max(grid.count, 1)
        let gap: CGFloat = 1
        GeometryReader { geo in
            let labelW: CGFloat = 20
            let availW = max(0, geo.size.width - labelW - gap)
            let cellW = max(2, (availW - CGFloat(dayCount - 1) * gap) / CGFloat(dayCount))
            let cellH = geo.size.height / CGFloat(hourCount) - gap
            HStack(alignment: .top, spacing: gap) {
                // 元は上端「0時」下端「23時」の2つだけで、真ん中のセルが何時か
                // 読めなかった(指摘)。6時間おきに目盛りを置き、各ラベルを対応する
                // 行の高さに合わせて配置する — セル1つ分の高さ(cellH+gap)に
                // ラベルの箱を揃えるので、行とラベルがずれない。
                let rowH = cellH + gap
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(Array(stride(from: 0, to: hourCount, by: 6)), id: \.self) { h in
                        Text("\(h)時")
                            .font(.system(size: 7)).foregroundStyle(.tertiary)
                            .frame(height: rowH, alignment: .top)
                        if h + 6 < hourCount {
                            Spacer(minLength: 0).frame(height: max(0, rowH * 5))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: labelW, height: geo.size.height, alignment: .top)
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(grid.enumerated()), id: \.offset) { _, day in
                        VStack(spacing: gap) {
                            ForEach(Array(day.enumerated()), id: \.offset) { _, v in
                                Rectangle()
                                    .fill(color(v))
                                    .frame(width: cellW, height: max(1.5, cellH))
                            }
                        }
                    }
                }
            }
        }
    }
}

struct RateRow: View {
    let label: String
    let window: RateWindow
    let windowHours: Double

    var resetShort: String {
        window.resetsAt.formatted(.dateTime.month(.defaultDigits).day().hour().minute())
    }

    var body: some View {
        let elapsed = elapsedPercent(resetsAt: window.resetsAt, windowHours: windowHours)
        let ratio = paceRatio(usedPct: window.usedPct, resetsAt: window.resetsAt, windowHours: windowHours)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(resetShort).font(.system(size: 10)).foregroundStyle(.tertiary)
                Text("\(window.usedPct)%").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(paceColor(ratio))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08)).frame(height: 6)
                    Capsule().fill(paceColor(ratio))
                        .frame(width: max(2, geo.size.width * min(1, Double(window.usedPct) / 100)), height: 6)
                    // 経過位置の基準線。.black 固定だとダークモードで
                    // パネル背景(.regularMaterial)に対して見えなくなる
                    // (実測で指摘) — .primary なら両テーマで見える。
                    Rectangle().fill(Color.primary.opacity(0.7))
                        .frame(width: 1.5, height: 10)
                        .offset(x: geo.size.width * min(1, elapsed / 100))
                }
            }
            .frame(height: 10)
        }
    }
}

/// メニューバーの1文字1文字は他のアプリと横並びで常に視界に入る場所 —
/// 絵文字の丸(🔴🟡🟢)は色付きテキストより主張が強く、他アプリのアイコンと
/// 並ぶと浮く(「もっとおしゃれに」との指摘)。SF Symbolsのドット+
/// 数字自体の色replaceで、システムのメニューバーの見た目に馴染ませる。
struct MenuBarLabel: View {
    @ObservedObject var snap: Snapshot

    private func ratioColor(_ ratio: Double?) -> Color? {
        guard let ratio else { return nil }
        if ratio <= 1.0 { return nil } // オンペースは無色 — 平常時は主張しない
        return ratio <= 1.15 ? Viz.statusWarning : Viz.statusCritical
    }

    // MenuBarExtraのラベルは、値の有無で子ビューを増減させる(if let ... { view })と
    // NSStatusItem側の再描画が効かなくなることがある(実測: sevenDayが起動後
    // 初回のrefreshでnil→値になった回に、Snapshot側の値は正しく更新されている
    // ログを確認済みなのに、実際のNSStatusItemタイトルは何度観測しても更新前の
    // まま固定された)。以前 if let を呼び出し先の関数内部に移しただけの修正を
    // 入れたが、それでも @ViewBuilder 内の if let 自体は残っており、
    // 効果が無いまま再発した。
    // 対策: 個々のセグメントを@ViewBuilderの条件分岐で足し引きするのをやめ、
    // 常に単一の具象型 Text を1つだけ返す。値が無い区間は文字列を空にする
    // (行自体を作らない)ことで、body が組み立てる子ビューの型・個数を
    // どんな入力でも完全に固定する。
    private func windowText(_ prefix: String, _ win: RateWindow?, _ windowHours: Double) -> Text? {
        guard let win else { return nil }
        let ratio = paceRatio(usedPct: win.usedPct, resetsAt: win.resetsAt, windowHours: windowHours)
        return Text("\(prefix)\(win.usedPct)%").foregroundStyle(ratioColor(ratio) ?? Color.primary)
    }

    private func scopedText(_ s: ScopedLimit) -> Text? {
        let ratio = paceRatio(usedPct: s.pct, resetsAt: s.resetsAt, windowHours: 24 * 7)
        guard let color = ratioColor(ratio), let initial = s.name.first else { return nil }
        return Text("\(initial)\(s.pct)%").foregroundStyle(color)
    }

    private func durationText(_ hours: Double?) -> Text? {
        guard let h = hours, h > 0 else { return nil }
        let totalMin = Int((h * 60).rounded())
        let s = totalMin >= 60 ? "\(totalMin / 60)h\(String(format: "%02d", totalMin % 60))m" : "\(totalMin)m"
        return Text(s)
    }

    private var combinedText: Text {
        var parts: [Text] = []
        parts.append(contentsOf: [
            windowText("h", snap.fiveHour, 5),
            windowText("w", snap.sevenDay, 24 * 7),
        ].compactMap { $0 })
        parts.append(contentsOf: snap.scopedLimits.compactMap(scopedText))
        if let d = durationText(snap.agentHoursToday) { parts.append(d) }
        guard var combined = parts.first else { return Text("ccwatch") }
        for p in parts.dropFirst() { combined = combined + Text(" ") + p }
        return combined
    }

    var body: some View {
        let hasAlert = snap.claudeStatusIndicator.map { $0 != "none" } ?? false
        HStack(spacing: 4) {
            // 常設のブランドアイコン。数字だけだとメニューバーの他項目に
            // 埋もれてどれが ccwatch か分からない(指摘)。パネル見出しと同じ
            // シンボルを使い、アイコン⇄パネルの対応をそのまま持たせる。
            // 条件分岐を持たない=トポロジーが常に固定なので、下の
            // NSStatusItem 再描画問題とも無関係でいられる。
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 12, weight: .semibold))
            // Imageは常に存在させ、不要時は幅0+透明にするだけに留める
            // (トポロジー固定と同じ理由 — 挿入・削除そのものを起こさない)。
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Viz.statusCritical)
                .opacity(hasAlert ? 1 : 0)
                .frame(width: hasAlert ? nil : 0)
            // レート制限(h/w)はペース比で既に色が付くが、ツール失敗率はパネルを
            // 開かないと見えなかった(指摘: 「あぶなければ色つけて」)。パネル側の
            // 「ツール失敗率」カードと同じ閾値(10%以上で危険)をそのまま流用する
            // — 独自の基準を増やさない。
            let toolDanger = (snap.toolErrorRate ?? 0) >= 10
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 10))
                .foregroundStyle(Viz.statusCritical)
                .opacity(toolDanger ? 1 : 0)
                .frame(width: toolDanger ? nil : 0)
            combinedText
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
    }
}

/// アルファベット順だと Fable/Haiku/Opus/Sonnet になり、能力の高さと
/// 無関係な並びになる(指摘)。fable→opus→sonnet→haiku の系統順、
/// 同系統内はバージョンの高い順に並べる。
private let modelFamilyOrder = ["fable", "opus", "sonnet", "haiku"]

private func modelVersionNumbers(_ model: String) -> [Int] {
    model.split(separator: "-").dropFirst()
        .compactMap { Int($0) }
}

func sortedModels(_ models: [String]) -> [String] {
    models.sorted { a, b in
        let famA = a.split(separator: "-").first.map(String.init) ?? a
        let famB = b.split(separator: "-").first.map(String.init) ?? b
        let rankA = modelFamilyOrder.firstIndex(of: famA) ?? modelFamilyOrder.count
        let rankB = modelFamilyOrder.firstIndex(of: famB) ?? modelFamilyOrder.count
        if rankA != rankB { return rankA < rankB }
        if famA != famB { return famA < famB }
        // 同系統はバージョン番号が大きい方を先に(4-8 と 5 なら 5 が先)。
        return modelVersionNumbers(a).lexicographicallyPrecedes(modelVersionNumbers(b)) == false
    }
}

func colorFor(model: String, in models: [String]) -> Color {
    let sorted = sortedModels(models)
    guard let idx = sorted.firstIndex(of: model) else { return .gray }
    return Viz.series[idx % Viz.series.count]
}

/// "opus-4-8" → "Opus 4.8". Version kept (not collapsed to just "Opus") —
/// two different model generations showing as identical legend entries was
/// exactly the bug this replaces (opus-4 and opus-5 both read "Opus").
/// Family name isn't hardcoded, so a new one (e.g. a future model line)
/// still renders instead of falling through to a raw truncated string.
func shortModelName(_ model: String) -> String {
    let parts = model.split(separator: "-")
    guard let family = parts.first else { return model }
    // ビルド日付("20251001"のような5桁以上の数字)はバージョンではないので
    // 落とす — haiku-4-5-20251001 が凡例で「Haiku 4.5.20251001」と
    // 長すぎる表示になっていた(指摘)。major.minorの2つまでに絞る。
    let versionParts = parts.dropFirst().prefix(2).filter { $0.count < 5 }
    let version = versionParts.joined(separator: ".")
    let capitalized = family.prefix(1).uppercased() + family.dropFirst()
    return version.isEmpty ? capitalized : "\(capitalized) \(version)"
}

struct ModelLegend: View {
    let models: [String]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(models, id: \.self) { m in
                HStack(spacing: 4) {
                    Circle().fill(colorFor(model: m, in: models)).frame(width: 6, height: 6)
                    Text(shortModelName(m)).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct PanelView: View {
    @ObservedObject var snap: Snapshot

    // 判定も案内も、依存6本すべてを見る。4本しか見ていなかったので、
    // ccsendstats だけ入れた人には「見つかりません」バナーとデータカードが
    // 同時に出ていた。
    var anyCLIFound: Bool {
        snap.hasCchours || snap.hasCcusage || snap.hasCcflaky
            || snap.hasCcskillstats || snap.hasAttention || snap.hasCcsendstats
    }

    var maxPanelHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) - 80
    }

    // 2本のLineMarkを.foregroundStyle(by:)無しで静的な色だけ変えて置くと、
    // 実機で片方(2本目)が描画されなかった(実測: 稼働時間/最長連続稼働、
    // トークン入力/出力のどちらも1本しか出ない — ユーザー指摘で発覚)。
    // コスト推移カードで既に動いている「long format + foregroundStyle(by:)」
    // パターンに統一する — 2軸統合の全チャートでこの構造体を使い回す。
    struct DualLineRow: Identifiable {
        let id = UUID()
        let date: Date
        let series: String
        let value: Double
    }

    struct BaselineBreakdownRow: Identifiable {
        let id = UUID()
        let date: Date
        let category: String
        let tokens: Double
    }

    // 「会話開始前の固定費」(baselineSeries、日別の合計)と「メモリ蓄積」
    // (memoryGrowthSeries、種別ごとの累積・値が変わった日にしか点が無い)を
    // 合成し、固定費の内訳を積み上げで見せる。メモリの値は「その日までの
    // 最新の累積」を前方補完して使う(cumulativeは減らないので、間の日は
    // 直前の値のままで正しい)。memoryの内訳合計を固定費から引いた残りは
    // 「その他(system prompt・CLAUDE.md本体・ツール定義など、内訳不明)」。
    var baselineBreakdownSeries: [BaselineBreakdownRow] {
        guard !snap.baselineSeries.isEmpty else { return [] }
        var byDayMemory: [Date: [String: Double]] = [:]
        for p in snap.memoryGrowthSeries {
            byDayMemory[p.date, default: [:]][p.category] = p.cumulativeTokens
        }
        let memDays = byDayMemory.keys.sorted()
        var rows: [BaselineBreakdownRow] = []
        var carry: [String: Double] = [:]
        var mi = 0
        for b in snap.baselineSeries.sorted(by: { $0.date < $1.date }) {
            while mi < memDays.count && memDays[mi] <= b.date {
                carry = byDayMemory[memDays[mi]]!
                mi += 1
            }
            let memTotal = carry.values.reduce(0, +)
            for cat in ["feedback", "project", "user", "reference"] {
                rows.append(BaselineBreakdownRow(date: b.date, category: cat, tokens: carry[cat] ?? 0))
            }
            rows.append(BaselineBreakdownRow(date: b.date, category: "other", tokens: max(0, b.avgBaseline - memTotal)))
        }
        return rows
    }

    // 「いま/今日」(分単位で変わる: レート制限・今日のコスト・失敗率)は
    // 常に見る価値があるので左列(tier1)へ。「30日トレンド」(日次粒度)は
    // 右列にactivityTab/qualityTab/contextTabとしてそのまま全部並べる
    // (タブ切り替えは「見なくなるから」の指摘で撤回、常時表示に戻した)。
    @ViewBuilder
    private var tier1: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snap.hasCchours || snap.hasCcusage {
                Card {
                    HStack(alignment: .top, spacing: 0) {
                        if snap.hasCchours {
                            DashStat(icon: "clock.fill", color: Viz.accentBlue, label: "稼働時間",
                                     today: snap.agentHoursToday.map { String(format: "%.1fh", $0) },
                                     range: snap.agentHours30.map { String(format: "%.0fh", $0) })
                        }
                        if snap.hasCcusage {
                            DashStat(icon: "dollarsign.circle.fill", color: Viz.accentOrange, label: "コスト",
                                     today: snap.costToday.map(moneyFmt),
                                     range: snap.cost30.map(moneyFmt))
                            DashStat(icon: "circle.hexagongrid.fill", color: Viz.accentPurple, label: "トークン",
                                     today: snap.tokensToday.map(tokFmt),
                                     range: snap.tokens30.map(tokFmt))
                        }
                    }
                }
            }

            Card {
                SectionLabel(text: "レート制限")
                if let err = snap.rateLimitError {
                    // status色をテキスト本体の色にすると、警告色のコントラストは
                    // 元々アイコン+通常色ラベルの組み合わせを前提に検証されて
                    // いる(palette.md: 単色では意味を運ばない設計)。文字は
                    // 通常のインク色にし、アイコンだけをstatus色にする
                    // (レビューで指摘: 本文が薄い黄でコントラスト不足)。
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(Viz.statusWarning)
                        Text(err).font(.system(size: 11)).foregroundStyle(.primary)
                    }
                } else {
                    if let fh = snap.fiveHour { RateRow(label: "5時間枠", window: fh, windowHours: 5) }
                    if let sd = snap.sevenDay { RateRow(label: "週次枠", window: sd, windowHours: 24 * 7) }
                    ForEach(snap.scopedLimits) { s in
                        RateRow(label: "\(s.name)枠", window: RateWindow(usedPct: s.pct, resetsAt: s.resetsAt),
                                 windowHours: 24 * 7)
                    }
                }
            }

            if snap.hasCcusage && !snap.costSeries.isEmpty {
                Card {
                    SectionLabel(text: "コスト推移")
                    let models = Array(Set(snap.costSeries.map(\.model)))
                    Chart(snap.costSeries) { p in
                        AreaMark(x: .value("日付", p.date, unit: .day), y: .value("$", p.cost), stacking: .standard)
                            .foregroundStyle(by: .value("モデル", p.model))
                            .interpolationMethod(.monotone)
                    }
                    .chartForegroundStyleScale(domain: sortedModels(models), range: sortedModels(models).map { colorFor(model: $0, in: models) })
                    .chartLegend(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                            AxisGridLine().foregroundStyle(.tertiary)
                            AxisValueLabel(format: .dateTime.day(), centered: true).font(.system(size: 8))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { v in
                            AxisGridLine().foregroundStyle(.quaternary)
                            if let y = v.as(Double.self) {
                                AxisValueLabel(String(format: "$%.0f", y)).font(.system(size: 8))
                            }
                        }
                    }
                    .frame(height: 60)
                    ModelLegend(models: sortedModels(models))
                }
            }

            if snap.hasCcusage && !snap.efficiencySeries.isEmpty {
                Card {
                    // 「トークン効率」は中身($/Mtok、単価)を正しく指していない
                    // との指摘。単位をタイトルに直接入れる(以前あった説明文の
                    // 削除と両立させる)。
                    SectionLabel(text: "トークンコスト($/Mtok)")
                    Chart(snap.efficiencySeries) { p in
                        LineMark(x: .value("日付", p.date, unit: .day), y: .value("$/Mtok", p.perMtok))
                            .foregroundStyle(Viz.accentBlue).interpolationMethod(.monotone)
                        PointMark(x: .value("日付", p.date, unit: .day), y: .value("$/Mtok", p.perMtok))
                            .foregroundStyle(Viz.accentBlue).symbolSize(10)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                            AxisGridLine().foregroundStyle(.tertiary)
                            AxisValueLabel(format: .dateTime.day(), centered: true).font(.system(size: 8))
                        }
                    }
                    // 既定の目盛り本数だと高さ34ptに対して密度が高すぎ、ラベルが
                    // 物理的に重なっていた(Fableレビュー指摘のバグ級の問題)。
                    // 3本に間引き、高さもカードの2段基準(44/56)のうち小さい方へ。
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { v in
                            AxisGridLine().foregroundStyle(.quaternary)
                            if let y = v.as(Double.self) {
                                AxisValueLabel(String(format: "$%.1f", y)).font(.system(size: 8))
                            }
                        }
                    }
                    .frame(height: 44)
                    // トークン数(入力/出力)は削除した — 実データで入力・出力の
                    // 相対的な動き方がほぼ相関していて、min-max正規化しても
                    // 2本がほぼ重なって見え、$/Mtokや他のトークン量カード
                    // (DashStat・初期トークン数)以上の示唆が無かった
                    // (指摘: 「あんまり意味がなさそう」)。
                }
            }


        }
    }

    @ViewBuilder
    private var activityTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snap.hasCchours && !snap.dailyHours.isEmpty {
                Card {
                    SectionLabel(text: "稼働時間 / 最長連続稼働")
                    // min-max正規化(自分の変動幅を相手の変動幅に写す)はしたが、
                    // 静的な.foregroundStyle(色)を付けた2本のLineMarkを
                    // by:無しで置いたら実機で2本目が描画されなかった(実測:
                    // ユーザー指摘で発覚、「合体してそう」)。long format +
                    // foregroundStyle(by:)というコスト推移カードで実績のある
                    // パターンに統一して確実に2系列として描く。
                    let hoursVals = snap.dailyHours.map(\.agentHours)
                    let longestVals = snap.dailyHours.map(\.longestRunHours)
                    let hMin = hoursVals.min() ?? 0, hMax = max(hoursVals.max() ?? 1, hMin + 0.001)
                    let lMin = longestVals.min() ?? 0, lMax = max(longestVals.max() ?? 1, lMin + 0.001)
                    let longestToHoursScale: (Double) -> Double = { (($0 - lMin) / (lMax - lMin)) * (hMax - hMin) + hMin }
                    let hoursScaleToLongest: (Double) -> Double = { (($0 - hMin) / (hMax - hMin)) * (lMax - lMin) + lMin }
                    let hoursRows: [DualLineRow] = snap.dailyHours.flatMap { row in
                        [
                            DualLineRow(date: row.date, series: "稼働時間", value: row.agentHours),
                            DualLineRow(date: row.date, series: "最長連続稼働", value: longestToHoursScale(row.longestRunHours)),
                        ]
                    }
                    Chart(hoursRows) { r in
                        LineMark(x: .value("日付", r.date, unit: .day), y: .value("時間", r.value))
                            .foregroundStyle(by: .value("種別", r.series))
                            .interpolationMethod(.monotone)
                    }
                    // ドメインを実データの[hMin,hMax]に固定しないと、Swift Chartsが
                    // 目盛りを0や切りのよい数に自動で広げ、右軸ラベルは左軸の広がった
                    // 位置をhoursScaleToLongestで逆変換するため実データ範囲外
                    // (負の値等)が出ることがある(実測: 委譲率チャートで-33%と表示)。
                    .chartYScale(domain: hMin...hMax)
                    .chartForegroundStyleScale(domain: ["稼働時間", "最長連続稼働"], range: [Viz.accentCyan, Viz.accentPurple])
                    .chartLegend(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                            AxisGridLine().foregroundStyle(.tertiary)
                            AxisValueLabel(format: .dateTime.day(), centered: true).font(.system(size: 8))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { v in
                            AxisGridLine().foregroundStyle(.quaternary)
                            if let y = v.as(Double.self) {
                                AxisValueLabel(String(format: "%.0fh", y)).font(.system(size: 8)).foregroundStyle(Viz.accentCyan)
                            }
                        }
                        AxisMarks(position: .trailing) { v in
                            if let y = v.as(Double.self) {
                                AxisValueLabel(String(format: "%.1fh", hoursScaleToLongest(y))).font(.system(size: 8)).foregroundStyle(Viz.accentPurple)
                            }
                        }
                    }
                    .frame(height: 56)
                    HStack(spacing: 10) {
                        HStack(spacing: 3) { Circle().fill(Viz.accentCyan).frame(width: 6, height: 6); Text("稼働時間").font(.system(size: 9)).foregroundStyle(.secondary) }
                        HStack(spacing: 3) { Circle().fill(Viz.accentPurple).frame(width: 6, height: 6); Text("最長連続稼働").font(.system(size: 9)).foregroundStyle(.secondary) }
                    }

                    Divider().padding(.vertical, 2)

                    // 稼働時間と同じcchours --dailyのレスポンスから読む同一系統の
                    // 指標(並列度・委譲率)なので、別カードではなく1枚に同居させる
                    // (Fableレビュー指摘: 「同じデータソースの2枚は1枚にすべき」)。
                    SectionLabel(text: "並列度 / 委譲率")
                    let parVals = snap.dailyHours.map(\.parallelism)
                    let subVals = snap.dailyHours.map { $0.subShare * 100 }
                    let pMin = parVals.min() ?? 0, pMax = max(parVals.max() ?? 1, pMin + 0.001)
                    let sMin = subVals.min() ?? 0, sMax = max(subVals.max() ?? 1, sMin + 0.001)
                    let subToParScale: (Double) -> Double = { (($0 - sMin) / (sMax - sMin)) * (pMax - pMin) + pMin }
                    let parScaleToSub: (Double) -> Double = { (($0 - pMin) / (pMax - pMin)) * (sMax - sMin) + sMin }
                    let rows: [DualLineRow] = snap.dailyHours.flatMap { row in
                        [
                            DualLineRow(date: row.date, series: "並列度", value: row.parallelism),
                            DualLineRow(date: row.date, series: "委譲率", value: subToParScale(row.subShare * 100)),
                        ]
                    }
                    Chart(rows) { r in
                        LineMark(x: .value("日付", r.date, unit: .day), y: .value("値", r.value))
                            .foregroundStyle(by: .value("種別", r.series))
                            .interpolationMethod(.monotone)
                    }
                    // 稼働時間/最長連続稼働と同じ理由でドメインを固定(実測:
                    // 固定前は右軸に-33%という負の委譲率が表示されていた)。
                    .chartYScale(domain: pMin...pMax)
                    .chartForegroundStyleScale(domain: ["並列度", "委譲率"], range: [Viz.accentCyan, Viz.accentOrange])
                    .chartLegend(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                            AxisGridLine().foregroundStyle(.tertiary)
                            AxisValueLabel(format: .dateTime.day(), centered: true).font(.system(size: 8))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { v in
                            AxisGridLine().foregroundStyle(.quaternary)
                            if let y = v.as(Double.self) {
                                AxisValueLabel(String(format: "×%.1f", y)).font(.system(size: 8)).foregroundStyle(Viz.accentCyan)
                            }
                        }
                        AxisMarks(position: .trailing) { v in
                            if let y = v.as(Double.self) {
                                AxisValueLabel(String(format: "%.0f%%", parScaleToSub(y))).font(.system(size: 8)).foregroundStyle(Viz.accentOrange)
                            }
                        }
                    }
                    .frame(height: 56)
                    HStack(spacing: 10) {
                        HStack(spacing: 3) { Circle().fill(Viz.accentCyan).frame(width: 6, height: 6); Text("並列度(同時実行の倍率)").font(.system(size: 9)).foregroundStyle(.secondary) }
                        HStack(spacing: 3) { Circle().fill(Viz.accentOrange).frame(width: 6, height: 6); Text("委譲率(サブエージェント時間の割合)").font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
                }
            }

            // 配置指示: コンテキスト使用率をアクティビティの上へ。
            if snap.hasCcsendstats, !snap.contextUsageSeries.isEmpty {
                Card {
                    SectionLabel(text: "コンテキスト使用率(分布)")
                    // p50単独だとその日の分布の広がりが消える。peakと違って
                    // p25/p75も日によって実際に動く(実測: p75が46%〜78%)ので、
                    // 帯(p25-p75)+中央線(p50)のファンチャートにする。
                    Text("帯 = p25-p75、線 = 中央値(p50)").font(.system(size: 10)).foregroundStyle(.secondary)
                    Chart(snap.contextUsageSeries) { p in
                        AreaMark(x: .value("日付", p.date, unit: .day), yStart: .value("p25", p.p25Pct), yEnd: .value("p75", p.p75Pct))
                            .foregroundStyle(Viz.accentPurple.opacity(0.2)).interpolationMethod(.monotone)
                        LineMark(x: .value("日付", p.date, unit: .day), y: .value("p50", p.p50Pct))
                            .foregroundStyle(Viz.accentPurple).interpolationMethod(.monotone)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                            AxisGridLine().foregroundStyle(.tertiary)
                            AxisValueLabel(format: .dateTime.day(), centered: true).font(.system(size: 8))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { v in
                            AxisGridLine().foregroundStyle(.quaternary)
                            if let y = v.as(Double.self) {
                                AxisValueLabel(String(format: "%.0f%%", y)).font(.system(size: 8))
                            }
                        }
                    }
                    .frame(height: 44)
                }
            }

            if !snap.hourlyHeatmap.isEmpty {
                Card {
                    SectionLabel(text: "アクティビティ")
                    // 元の56pt(24時間で割ると1セル2.3pt、実質判読不能 —
                    // Fableレビュー指摘)から104ptに拡大し、実際に読める
                    // セル高さ(約4.3pt)を確保する。
                    HoursHeatmap(grid: snap.hourlyHeatmap).frame(height: 104)
                    HStack(spacing: 4) {
                        Text("古い日→新しい日 (横) / 少ない").font(.system(size: 8)).foregroundStyle(.tertiary)
                        ForEach(0..<5) { i in
                            Rectangle().fill(HoursHeatmap.legendColor(i)).frame(width: 8, height: 8)
                        }
                        Text("多い").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var qualityTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snap.hasCcflaky, let rate = snap.toolErrorRate {
                Card {
                    SectionLabel(text: "ツール失敗率")
                    HStack {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .foregroundStyle(rate >= 10 ? Viz.statusCritical : rate >= 5 ? Viz.statusWarning : .secondary)
                        Text(String(format: "今日 %.1f%%", rate)).font(.system(size: 12, weight: .medium))
                        Spacer()
                        if let n = snap.toolCallsToday {
                            Text("\(n)回").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                    if !snap.errorRateSeries.isEmpty {
                        Chart(snap.errorRateSeries) { p in
                            LineMark(x: .value("日付", p.date, unit: .day), y: .value("失敗率", p.errorRate))
                                .foregroundStyle(p.errorRate >= 10 ? Viz.statusCritical : Viz.statusWarning)
                                .interpolationMethod(.monotone)
                        }
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                                AxisGridLine().foregroundStyle(.tertiary)
                                AxisValueLabel(format: .dateTime.day(), centered: true).font(.system(size: 8))
                            }
                        }
                        .chartYAxis {
                            AxisMarks(values: .automatic(desiredCount: 3)) { v in
                                AxisGridLine().foregroundStyle(.quaternary)
                                if let y = v.as(Double.self) {
                                    AxisValueLabel(String(format: "%.0f%%", y)).font(.system(size: 8))
                                }
                            }
                        }
                        .frame(height: 44)
                    }
                    ForEach(snap.topFailingTools) { f in
                        HStack(spacing: 8) {
                            Text(f.name).font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head).frame(maxWidth: 170, alignment: .leading)
                            Spacer(minLength: 0)
                            Text(String(format: "%.0f%%(%d)", f.errorRate, f.calls))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Viz.statusCritical).fixedSize()
                        }
                    }
                }
            }

            if snap.hasCcskillstats, let fired = snap.skillsFired, let total = snap.skillsTotal, total > 0 {
                Card {
                    SectionLabel(text: "スキル発火")
                    HStack {
                        Image(systemName: "sparkles").foregroundStyle(fired == total ? Viz.statusGood : Viz.statusWarning)
                        Text("\(fired) / \(total) 発火").font(.system(size: 12, weight: .medium))
                    }
                    // グラフを上・内訳リストを下に(ユーザー指摘: 「上にグラフで
                    // 下に項目」)。「誰が呼んだか」— toolはClaudeが会話中に
                    // 自主的に選んだ回数(=descriptionが拾われた証拠)、typedは
                    // 自分で/nameと打った回数、autoはcron等の自動化。実測:
                    // autoが63%・toolはわずか17% — descriptionが会話の中で
                    // ほとんど拾われていないという診断になる。
                    if !snap.skillFireKindSeries.isEmpty {
                        let kindCategories = ["tool", "typed", "auto"]
                        let kindColors = [Viz.accentCyan, Viz.accentOrange, Color.secondary]
                        Chart(snap.skillFireKindSeries) { r in
                            AreaMark(x: .value("日付", r.date, unit: .day), y: .value("回数", r.count), stacking: .standard)
                                .foregroundStyle(by: .value("種別", r.kind))
                        }
                        .chartForegroundStyleScale(domain: kindCategories, range: kindColors)
                        .chartLegend(.hidden)
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                                AxisGridLine().foregroundStyle(.tertiary)
                                AxisValueLabel(format: .dateTime.day(), centered: true).font(.system(size: 8))
                            }
                        }
                        .chartYAxis {
                            AxisMarks(values: .automatic(desiredCount: 3)) { v in
                                AxisGridLine().foregroundStyle(.quaternary)
                                if let y = v.as(Double.self) {
                                    AxisValueLabel(String(format: "%.0f", y)).font(.system(size: 8))
                                }
                            }
                        }
                        .frame(height: 56)
                        HStack(spacing: 10) {
                            ForEach(Array(zip(kindCategories, kindColors)), id: \.0) { name, color in
                                HStack(spacing: 4) {
                                    Circle().fill(color).frame(width: 6, height: 6)
                                    Text(name).font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    ForEach(snap.topSkills) { s in
                        HStack(spacing: 8) {
                            Text(s.name).font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head).frame(maxWidth: 170, alignment: .leading)
                            Spacer(minLength: 0)
                            Text("\(s.total)回")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Viz.accentPurple).fixedSize()
                        }
                    }
                }
            }

            // 配置指示: スキル発火の下へ。「対話の摩擦」カードごと削除したが
            // (用件=90分ギャップという定義が微妙という指摘)、自己訂正率だけは
            // 用件(スレッド)に依存しない(selffix数÷総発話数の日次比率、
            // スレッド分割の影響を受けない)。巻き添えで消していたので復活
            // させた — データ取得(attention)自体は引き続き動いていたので
            // 追加コストなし。
            // attention の主指標。これまで perThread は取得だけして表示して
            // いなかった — 用件の定義が「90分ギャップ」という閾値頼みで、
            // 1日中打ち続けた日が239発話/1用件になるなど値が信用できなかった
            // ため。用件をセッション単位(閾値なし)に変えて実測CVが1.15→0.56に
            // 下がり、全日で算出できるようになったので出す。
            if snap.hasAttention, !snap.attentionSeries.isEmpty {
                Card {
                    SectionLabel(text: "セッションあたり発話数")
                    if let today = snap.attentionPerThreadToday {
                        HStack {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .foregroundStyle(Viz.accentCyan)
                            Text(String(format: "今日 %.1f 発話/セッション", today))
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    Text("1セッションが平均何往復か。長い=1本で色々やった or 手間取った")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                    Chart(snap.attentionSeries) { p in
                        LineMark(x: .value("日付", p.date, unit: .day), y: .value("発話/セッション", p.perThread))
                            .foregroundStyle(Viz.accentCyan).interpolationMethod(.monotone)
                        PointMark(x: .value("日付", p.date, unit: .day), y: .value("発話/セッション", p.perThread))
                            .foregroundStyle(Viz.accentCyan).symbolSize(10)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                            AxisGridLine().foregroundStyle(.tertiary)
                            AxisValueLabel(format: .dateTime.day(), centered: true).font(.system(size: 8))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { v in
                            AxisGridLine().foregroundStyle(.quaternary)
                            if let y = v.as(Double.self) {
                                AxisValueLabel(String(format: "%.0f", y)).font(.system(size: 8))
                            }
                        }
                    }
                    .frame(height: 44)
                }
            }

            if snap.hasAttention, !snap.attentionSeries.isEmpty {
                Card {
                    SectionLabel(text: "自己訂正率 / 差し戻し")
                    Text("直前の自分の発言を訂正した割合").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Chart(snap.attentionSeries) { p in
                        LineMark(x: .value("日付", p.date, unit: .day), y: .value("自己訂正率", p.selffixRate))
                            .foregroundStyle(Viz.accentOrange).interpolationMethod(.monotone)
                        PointMark(x: .value("日付", p.date, unit: .day), y: .value("自己訂正率", p.selffixRate))
                            .foregroundStyle(Viz.accentOrange).symbolSize(10)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                            AxisGridLine().foregroundStyle(.tertiary)
                            AxisValueLabel(format: .dateTime.day(), centered: true).font(.system(size: 8))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { v in
                            AxisGridLine().foregroundStyle(.quaternary)
                            if let y = v.as(Double.self) {
                                AxisValueLabel(String(format: "%.0f%%", y)).font(.system(size: 8))
                            }
                        }
                    }
                    .frame(height: 44)
                    // 用件正規化した「差し戻し/用件」は撤去したが、生の件数は
                    // 定義に依存しない。実測: 機能追加直後(8/14-17)は0-2で計測
                    // できていなかっただけで、8/18以降は37-127と実際に動く。
                    Text("差し戻し件数").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Chart(snap.attentionSeries) { p in
                        LineMark(x: .value("日付", p.date, unit: .day), y: .value("差し戻し", p.blocksRaw))
                            .foregroundStyle(Viz.accentRed).interpolationMethod(.monotone)
                        PointMark(x: .value("日付", p.date, unit: .day), y: .value("差し戻し", p.blocksRaw))
                            .foregroundStyle(Viz.accentRed).symbolSize(10)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                            AxisGridLine().foregroundStyle(.tertiary)
                            AxisValueLabel(format: .dateTime.day(), centered: true).font(.system(size: 8))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { v in
                            AxisGridLine().foregroundStyle(.quaternary)
                            if let y = v.as(Double.self) {
                                AxisValueLabel(String(format: "%.0f", y)).font(.system(size: 8))
                            }
                        }
                    }
                    .frame(height: 44)
                }
            }
        }
    }

    @ViewBuilder
    private var contextTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 「コンテキストの中身」タブ: 単価・量・内訳・固定費・使用率など、
            // トークンの中身に関する指標をまとめる。トークン単価($/Mtok)と
            // トークン数は尺度が全く違う(0-2 vs 数千万)ので2y軸で重ねず
            // (dataviz スキル)、別チャートに分ける。

            // 固定費(baseline)とその内訳(メモリ蓄積、種別別)を1枚のカードに
            // 積み上げで統合した。memory由来で説明できない残りは「other」
            // (system prompt・CLAUDE.md本体・ツール定義など、transcriptに
            // 残らず内訳を追えない分)としてそのまま見せる — 消さずに
            // 「不明」であることを示す。
            if !baselineBreakdownSeries.isEmpty {
                let baseCategories = ["feedback", "project", "user", "reference", "other"]
                let baseColors = [Viz.accentOrange, Viz.accentCyan, Viz.accentPurple, Viz.accentBlue, Color.secondary]
                Card {
                    // 「初期トークン数(会話前)」は分かりにくいとの指摘(「これ改めて
                    // なんだっけ？」)。会話の中身によらず毎回自動で乗る分、という
                    // 性質そのものを名前にする。
                    SectionLabel(text: "固定トークン")
                    // 説明文を「これが何か」+「色分けは何を表すか」の1文に統合
                    // (副題が凡例と一致していなかった過去の指摘: 「system prompt+
                    // CLAUDE.md+メモリ+ツール定義」と4つ並列に書いていたが、実際に
                    // 色分けされているのはメモリの内訳(feedback/project/user/
                    // reference)だけ — 残り3つはtranscriptに残らず分解できないため
                    // "other"に一括りにしている)。
                    Text("セッションの中身によらず毎回自動で送られる分。内訳はメモリ + その他(system prompt・CLAUDE.md・ツール定義)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Chart(baselineBreakdownSeries) { p in
                        AreaMark(x: .value("日付", p.date, unit: .day), y: .value("トークン", p.tokens), stacking: .standard)
                            .foregroundStyle(by: .value("種別", p.category))
                    }
                    .chartForegroundStyleScale(domain: baseCategories, range: baseColors)
                    .chartLegend(.hidden)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                            AxisGridLine().foregroundStyle(.tertiary)
                            AxisValueLabel(format: .dateTime.day(), centered: true).font(.system(size: 8))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { v in
                            AxisGridLine().foregroundStyle(.quaternary)
                            if let y = v.as(Double.self) {
                                AxisValueLabel(tokFmt(y)).font(.system(size: 8))
                            }
                        }
                    }
                    .frame(height: 56)
                    HStack(spacing: 8) {
                        ForEach(Array(zip(baseCategories, baseColors)), id: \.0) { name, color in
                            HStack(spacing: 4) {
                                Circle().fill(color).frame(width: 6, height: 6)
                                Text(name).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            // 入力の内訳(課金レート別)カードは削除した — 実データで96〜99%が
            // 常にcache-readで占められ、日によってほぼ動かず示唆が無かった
            // (指摘: 「示唆なさそうだから消そう」)。計算ロジック自体
            // (refreshCacheMix/cacheMixSeries)は他で使う可能性があるため
            // Data.swift側は残し、表示だけ外す。

            // 配置指示: 右の1番下へ移動。実行中に次のプロンプトを送った割合
            // (ccsendstats --daily --interrupt)。実測30日で0%→100%まで明確な
            // 上昇トレンド — 待たずに次を投げるスタイルへ変化していることを
            // 日次でも捉えられる。
            if !snap.interruptSeries.isEmpty {
                Card {
                    SectionLabel(text: "実行中の割り込み率")
                    Chart(snap.interruptSeries) { p in
                        LineMark(x: .value("日付", p.date, unit: .day), y: .value("割り込み率", p.interruptRate))
                            .foregroundStyle(Viz.accentPurple)
                            .interpolationMethod(.monotone)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                            AxisGridLine().foregroundStyle(.tertiary)
                            AxisValueLabel(format: .dateTime.day(), centered: true).font(.system(size: 8))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { v in
                            AxisGridLine().foregroundStyle(.quaternary)
                            if let y = v.as(Double.self) {
                                AxisValueLabel(String(format: "%.0f%%", y)).font(.system(size: 8))
                            }
                        }
                    }
                    .frame(height: 44)
                    Text("実行中(前のターン継続中)に次を送った割合").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // ScrollViewでImageRendererに渡すと中身が空で描画される既知の制約が
    // あるため、実コンテンツ(スクロールなし版)を独立したViewとして切り出す。
    // 実行時の body はこれを ScrollView で包み、--render-preview はこちらを
    // 直接ImageRendererに渡して自然な全高で描く。
    @ViewBuilder
    var panelContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.tint)
                Text("ccwatch").font(.system(size: 13, weight: .semibold))
                // 公開前提(GitHub)で、各カードの計算ロジックをまとめた
                // METRICS.mdへのリンクをアプリ上に置く(ユーザー指摘)。
                // SwiftUIのLinkはNSButton系のブリッジで、segmentedピッカーと
                // 同種のImageRenderer描画不具合を踏む可能性があるため避け、
                // 自前のtap gestureでNSWorkspace.shared.openを呼ぶ。
                Text("計算ロジック")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .underline()
                    .onTapGesture {
                        if let url = URL(string: "https://github.com/sue738/ccwatch/blob/main/METRICS.md") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                Spacer()
                if let ind = snap.claudeStatusIndicator {
                    let ok = ind == "none"
                    HStack(spacing: 4) {
                        Text("claude status:").font(.system(size: 10)).foregroundStyle(.tertiary)
                        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(ok ? .green : .red)
                    }
                }
            }

            if !anyCLIFound {
                Card {
                    SectionLabel(text: "コマンドが見つかりません")
                    // 依存CLIの一覧はREADMEのinstall行と同じ6本にする。ここが4本
                    // だったので、バナーに従って入れた人は ccattention と
                    // ccsendstats のカードが無言で出ないままになっていた。
                    Text("cchours・ccusage・ccattention・ccflaky・ccskillstats・ccsendstats のいずれもPATH上に見つかりませんでした。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("npm install -g cchours ccusage ccattention ccflaky ccskillstats ccsendstats")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .padding(6).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            // タブ切り替えは撤回(ユーザー指摘: 「みなくなるから。全部の
            // チャート出せると思うよ」)。左右の高さバランスを取るため、
            // 元の「使用状況/コスト系(左) vs 品質系(右)」の分け方を踏襲し
            // つつ改善分(統合カード・大きいheatmap・重複削除)だけ残す。
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    tier1
                    activityTab
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 10) {
                    qualityTab
                    contextTab
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
    }

    // ScrollViewは「中身を測って自分から育つ」ことをしない — .frame(maxHeight:)を
    // 外側につけても、MenuBarExtra(.window)側は中身の実寸を知らないので既定の
    // 小さいウィンドウ高さ(実測354pt)のまま確定してしまい、実際には740pt超ある
    // 中身の大半が無言で隠れていた。--render-previewはScrollViewを介さず
    // panelContentを直接描くのでこの問題自体が起きず、確認をすり抜けていた
    // (実機のウィンドウ枠サイズをCGWindowListCopyWindowInfoで実測して発覚)。
    // 対策: GeometryReaderで自前に測ろうとする2案(素朴な版・fixedSizeで
    // 隠しコピーを別立てする版)はどちらも実機で0×0に潰れた(高さがまだ
    // 決まっていない段階で中身に「利用可能な高さ」を尋ねる循環にSwiftUIが
    // 巻き込まれ、両方0で手を打つ)。CGWindowListCopyWindowInfoで実際の
    // ウィンドウ枠サイズを測って確認した。
    // 対策: 自作の測定をやめ、ScrollViewに .fixedSize(vertical: true) を
    // 付けて「中身の自然な高さ」をそのまま外側へ申告させ、その外側に
    // .frame(maxHeight:) で上限を掛ける定石の順序にする。中身が上限以下
    // なら fixedSize の申告どおりの高さで確定し、上限を超える時だけ
    // frame 側の制約が勝ってScrollViewが本来のスクロールに戻る。
    var body: some View {
        // 元々 .frame(maxHeight:) だけで高さを打ち切っており、画面が小さいと
        // 下のカードに到達する手段が無いままはみ出た分が無言で消えていた
        // (レビューで発見)。ScrollViewで包み、はみ出た時はスクロールで
        // 見えるようにする。
        ScrollView(.vertical) {
            panelContent
        }
        .frame(width: 660)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: maxPanelHeight, alignment: .top)
        .onAppear { Task { await snap.refresh() } }
    }
}

/// PanelView を実機の画面を一切使わずPNGに描き出す。ImageRenderer は
/// オフスクリーン描画なので CGDisplayIsAsleep / 蓋閉じ状態に依存しない。
/// snap.refresh() の完了を待つ必要があるが、init() は同期文脈なので
/// semaphoreで単純ブロックすると MainActor の実行キューごと止まり
/// デッドロックする — 代わりにRunLoopを回し続けて完了フラグを待つ。
@MainActor
func writePNG(_ view: some View, to path: String, scale: CGFloat = 2.0) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    if let img = renderer.nsImage,
       let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
        FileHandle.standardError.write("rendered to \(path)\n".data(using: .utf8)!)
    } else {
        FileHandle.standardError.write("render failed: \(path)\n".data(using: .utf8)!)
    }
}

/// コンパクトなメニューバー表示("h5% w75%..."のラベル部分)は
/// screencaptureに頼らないと確認できなかった(実測: 画面が起こせない
/// ことがある — 蓋を閉じている・深いスリープ等)。panelContentと同じ
/// 理由でこちらもオフスクリーン描画で確認できるようにする。
/// 出力パスの拡張子の前に "-menubar" を付けたファイルにも書き出す。
func renderPreviewAndExit(to path: String) -> Never {
    var done = false
    Task { @MainActor in
        let snap = Snapshot()
        await snap.refresh()
        writePNG(PanelView(snap: snap).panelContent.frame(width: 660), to: path)
        let menubarPath = path.hasSuffix(".png")
            ? String(path.dropLast(4)) + "-menubar.png"
            : path + "-menubar.png"
        writePNG(
            MenuBarLabel(snap: snap)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color(light: "#fcfcfb", dark: "#1a1a19")),
            to: menubarPath
        )
        done = true
    }
    // snap.refresh()の中の重いCLI呼び出しが何かの理由で返らないと、
    // これも無期限に待ち続けてしまう(レビューで指摘)。上限を設けて
    // 越えたら諦める — 個々のCLI呼び出し自体にもrunJSON側でタイムアウトが
    // あるので通常はここに到達しないはずだが、多重の防御として置く。
    let deadline = Date().addingTimeInterval(90)
    while !done && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    if !done {
        FileHandle.standardError.write("render timed out after 90s\n".data(using: .utf8)!)
        exit(1)
    }
    exit(0)
}

@main
struct CCWatchApp: App {
    @StateObject var snap = Snapshot()
    let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    init() {
        // 診断用: `ccwatch --render-preview <path.png>` でパネルをPNGに直接
        // レンダリングして終了する。物理ディスプレイの状態(スリープ中・
        // 蓋が閉じている等)に一切依存しない — screencaptureが構造的に
        // 使えない状況での見た目確認手段として追加。多重起動ガードより先に
        // 判定する — 常駐インスタンスが既に動いている時にこそ使いたい機能
        // なのに、ガードが先だと無言でexit(0)されて機能しなかった(実測)。
        if let idx = CommandLine.arguments.firstIndex(of: "--render-preview"),
           idx + 1 < CommandLine.arguments.count {
            renderPreviewAndExit(to: CommandLine.arguments[idx + 1])
        }

        // 多重起動は同じレート制限エンドポイントを二重に叩く原因になる
        // (実測で起きた)。既に自分と同じbundle IDのプロセスがいたら
        // 先発を前面に出して自分は即終了する。
        let bundleID = Bundle.main.bundleIdentifier ?? "com.sue738.ccwatch"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            others.forEach { $0.activate() }
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(snap: snap)
        } label: {
            MenuBarLabel(snap: snap)
                .onAppear { Task { await snap.refresh() } }
                .onReceive(timer) { _ in Task { await snap.refresh() } }
        }
        .menuBarExtraStyle(.window)
    }
}
