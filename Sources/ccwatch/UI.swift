import SwiftUI
import Charts
import AppKit

// Palette values below are validated per-mode by the dataviz skill (references/palette.md), not derived by darkening.
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

/// Categorical palette — always used in this fixed order (series-1+), which is
/// CVD-safety-validated; never recolor by rank or appearance order.
enum Viz {
    // Desaturated Nord-style colors FAILed dataviz validation (#5e81ac reads as gray,
    // adjacent ΔE < 15) — reverted; recoloring by eye is disallowed. accentX below is
    // a separate palette since those charts need trend, not identification.
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
    // Light-mode contrast (1.79:1) is intentionally low, by design — mitigated by
    // using status color only on icons, never text (already true in this file).
    static let statusWarning = Color(light: "#fab219", dark: "#fab219")
    static let statusCritical = Color(light: "#d03b3b", dark: "#d03b3b")
    /// Don't use categorical series colors for single-series graphs — nothing to
    /// distinguish, so it just looks gratuitously bright; reserve series for multi-series.
    static let ink = Color(light: "#52514e", dark: "#c3c2b7")

    /// Pulled from the Nord theme rather than plain gray — a light color cue for
    /// single-series charts without the vividness of the categorical palette.
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

/// Shown while a found CLI hasn't returned yet — some CLIs take 60+ seconds.
/// Height matches the real card so layout doesn't jump when data arrives.
struct LoadingCard: View {
    let title: String
    var height: CGFloat = 64
    var body: some View {
        Card {
            SectionLabel(text: title)
            VStack(alignment: .leading, spacing: 6) {
                ForEach([0.9, 0.65, 0.8, 0.5], id: \.self) { w in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.07))
                        .frame(height: 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .scaleEffect(x: w, y: 1, anchor: .leading)
                }
                Text(T("Counting…")).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
        }
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
            Text(T("30d ") + (range ?? "–")).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

func elapsedPercent(resetsAt: Date, windowHours: Double) -> Double {
    let now = Date()
    let windowStart = resetsAt.addingTimeInterval(-windowHours * 3600)
    let elapsed = now.timeIntervalSince(windowStart)
    return max(0.1, min(100, elapsed / (windowHours * 3600) * 100))
}

// Under 10% elapsed the ratio spikes on light usage right after a reset and fires a
// false alert, so don't judge (nil) below that.
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

/// Same green ramp as GitHub's contribution graph, so darker-is-more-active reads for free.
struct HoursHeatmap: View {
    let grid: [[Double]] // grid[dayIndex][hour], hour 0-23

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
                // Ticks every 6 hours — previously only 0:00/23:00 were labeled and the
                // middle rows were unreadable.
                let rowH = cellH + gap
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(Array(stride(from: 0, to: hourCount, by: 6)), id: \.self) { h in
                        Text(tHour(h))
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
                    // .primary, not .black — .black disappears against the dark-mode panel background.
                    Rectangle().fill(Color.primary.opacity(0.7))
                        .frame(width: 1.5, height: 10)
                        .offset(x: geo.size.width * min(1, elapsed / 100))
                }
            }
            .frame(height: 10)
        }
    }
}

/// SF Symbols dot + recolored digits, not emoji — emoji stands out next to other apps' icons.
struct MenuBarLabel: View {
    @ObservedObject var snap: Snapshot

    private func ratioColor(_ ratio: Double?) -> Color? {
        guard let ratio else { return nil }
        if ratio <= 1.0 { return nil } // On-pace stays colorless — no noise in the normal case
        return ratio <= 1.15 ? Viz.statusWarning : Viz.statusCritical
    }

    // NSStatusItem stops redrawing if the label's child view count changes via if let —
    // title froze at its old value even though Snapshot updated correctly (measured).
    // Always emit one concrete Text; use an empty string instead of omitting a segment.
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

    // MenuBarExtra's label renders as a template image, discarding `.foregroundStyle`
    // color (measured: 117 colored columns via ImageRenderer, 0 on the real bar).
    // Fix: bake to NSImage with isTemplate = false.
    /// `--render-preview` must not nest another ImageRenderer here — that crashed
    /// sporadically with SIGTRAP (exit 133). Returns the plain view instead.
    var bakeToImage: Bool = true

    var body: some View {
        if bakeToImage, let img = rendered() {
            Image(nsImage: img)
        } else {
            content   // Fallback: no color, but numbers still show
        }
    }

    /// Color.primary bakes black per app appearance, invisible on a dark menu bar
    /// (measured: rgb(68,68,58) while appearance was still Light). Reads
    /// effectiveAppearance from MenuBarExtra's status window instead of the app.
    @MainActor
    private func menuBarIsDark() -> Bool {
        let names: [NSAppearance.Name] = [.aqua, .darkAqua, .vibrantLight, .vibrantDark]
        let statusWindow = NSApp.windows.first { w in
            let n = String(describing: type(of: w))
            return n.contains("StatusBar") || n.contains("MenuBarExtra")
        }
        let appearance = statusWindow?.effectiveAppearance ?? NSApp.effectiveAppearance
        let match = appearance.bestMatch(from: names)
        return match == .darkAqua || match == .vibrantDark
    }

    @MainActor
    private func rendered() -> NSImage? {
        let dark = menuBarIsDark()
        let r = ImageRenderer(content: content
            .environment(\.colorScheme, dark ? .dark : .light)
            .foregroundStyle(dark ? Color.white : Color.black))
        r.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let img = r.nsImage else { return nil }
        img.isTemplate = false
        return img
    }

    @ViewBuilder
    private var content: some View {
        let hasAlert = snap.claudeStatusIndicator.map { $0 != "none" } ?? false
        HStack(spacing: 4) {
            // Permanent brand icon so ccwatch is identifiable among other menu bar items.
            // Kept unconditional to preserve fixed view topology (see redraw issue above).
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 12, weight: .semibold))
            // Kept always present; hidden state is width-0 + transparent, not removed — same fixed-topology reason.
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Viz.statusCritical)
                .opacity(hasAlert ? 1 : 0)
                .frame(width: hasAlert ? nil : 0)
            // Reuses the panel's ≥10% tool-failure-rate threshold — same danger signal without opening the panel.
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

/// Ordered by family (fable→opus→sonnet→haiku) — alphabetical order ignores capability.
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
        // Within a family, higher version first (between 4-8 and 5, 5 comes first).
        return modelVersionNumbers(a).lexicographicallyPrecedes(modelVersionNumbers(b)) == false
    }
}

func colorFor(model: String, in models: [String]) -> Color {
    let sorted = sortedModels(models)
    guard let idx = sorted.firstIndex(of: model) else { return .gray }
    return Viz.series[idx % Viz.series.count]
}

/// Keeps the version (not just "Opus") — opus-4 and opus-5 previously both showed as "Opus" in the legend.
func shortModelName(_ model: String) -> String {
    let parts = model.split(separator: "-")
    guard let family = parts.first else { return model }
    // Drops 5+ digit build-date suffixes (e.g. 20251001 in haiku-4-5-20251001) — not
    // part of the version; was rendering as "Haiku 4.5.20251001" in the legend.
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

    // Must check all 6 dependency CLIs, matching the guidance banner — checking only 4
    // let someone with just ccsendstats installed see "not found" plus its data card.
    var anyCLIFound: Bool {
        snap.hasCchours || snap.hasCcusage || snap.hasCcflaky
            || snap.hasCcskillstats || snap.hasAttention || snap.hasCcsendstats
    }

    var maxPanelHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 900) - 80
    }

    // Two LineMarks with a static color and no foregroundStyle(by:) silently drop the
    // second line on-device (measured) — always use long format + foregroundStyle(by:).
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

    // Merges the fixed-cost baseline with memory's cumulative-by-category series,
    // forward-filling memory (cumulative never decreases). Unexplained remainder
    // becomes "other" (system prompt, CLAUDE.md, tool defs, etc).
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

    // Left column = "right now" (changes minute to minute); right column = 30-day
    // trends, shown in full — tab switching was tried and reverted.
    @ViewBuilder
    private var tier1: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snap.hasCchours || snap.hasCcusage {
                Card {
                    HStack(alignment: .top, spacing: 0) {
                        if snap.hasCchours {
                            DashStat(icon: "clock.fill", color: Viz.accentBlue, label: T("Hours"),
                                     today: snap.agentHoursToday.map { String(format: "%.1fh", $0) },
                                     range: snap.agentHours30.map { String(format: "%.0fh", $0) })
                        }
                        if snap.hasCcusage {
                            DashStat(icon: "dollarsign.circle.fill", color: Viz.accentOrange, label: T("Cost"),
                                     today: snap.costToday.map(moneyFmt),
                                     range: snap.cost30.map(moneyFmt))
                            DashStat(icon: "circle.hexagongrid.fill", color: Viz.accentPurple, label: T("Tokens"),
                                     today: snap.tokensToday.map(tokFmt),
                                     range: snap.tokens30.map(tokFmt))
                        }
                    }
                }
            }

            Card {
                SectionLabel(text: T("Rate limits"))
                if snap.pending.contains("rate") && snap.rateLimitError == nil
                    && snap.fiveHour == nil && snap.sevenDay == nil {
                    Text(T("Fetching…")).font(.system(size: 11)).foregroundStyle(.tertiary)
                } else if let err = snap.rateLimitError {
                    // Status color stays on the icon only, never body text — palette.md's
                    // warning contrast assumes icon+normal-text pairing; as text it lost contrast.
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(Viz.statusWarning)
                        Text(err).font(.system(size: 11)).foregroundStyle(.primary)
                    }
                } else {
                    if let fh = snap.fiveHour { RateRow(label: T("5-hour"), window: fh, windowHours: 5) }
                    if let sd = snap.sevenDay { RateRow(label: T("Weekly"), window: sd, windowHours: 24 * 7) }
                    ForEach(snap.scopedLimits) { s in
                        RateRow(label: tWindow(s.name), window: RateWindow(usedPct: s.pct, resetsAt: s.resetsAt),
                                 windowHours: 24 * 7)
                    }
                }
            }

            if snap.pending.contains("cost") && snap.costSeries.isEmpty {
                LoadingCard(title: T("Cost trend"), height: 84)
            }
            if snap.hasCcusage && !snap.costSeries.isEmpty {
                Card {
                    SectionLabel(text: T("Cost trend"))
                    let models = Array(Set(snap.costSeries.map(\.model)))
                    Chart(snap.costSeries) { p in
                        AreaMark(x: .value(T("Date"), p.date, unit: .day), y: .value("$", p.cost), stacking: .standard)
                            .foregroundStyle(by: .value(T("Model"), p.model))
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
                    .frame(height: 40)
                    ModelLegend(models: sortedModels(models))
                }
            }

            if snap.pending.contains("cost") && snap.efficiencySeries.isEmpty {
                LoadingCard(title: T("Token cost ($/Mtok)"))
            }
            if snap.hasCcusage && !snap.efficiencySeries.isEmpty {
                Card {
                    SectionLabel(text: T("Token cost ($/Mtok)"))
                    Chart(snap.efficiencySeries) { p in
                        LineMark(x: .value(T("Date"), p.date, unit: .day), y: .value("$/Mtok", p.perMtok))
                            .foregroundStyle(Viz.accentBlue).interpolationMethod(.monotone)
                        PointMark(x: .value(T("Date"), p.date, unit: .day), y: .value("$/Mtok", p.perMtok))
                            .foregroundStyle(Viz.accentBlue).symbolSize(10)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 3)) { _ in
                            AxisGridLine().foregroundStyle(.tertiary)
                            AxisValueLabel(format: .dateTime.day(), centered: true).font(.system(size: 8))
                        }
                    }
                    // Default tick count overlaps labels at 34pt height — thinned to 3 ticks.
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) { v in
                            AxisGridLine().foregroundStyle(.quaternary)
                            if let y = v.as(Double.self) {
                                AxisValueLabel(String(format: "$%.1f", y)).font(.system(size: 8))
                            }
                        }
                    }
                    .frame(height: 44)
                    // Input/output token count chart removed — the two move almost identically
                    // in real data; even min-max normalized, the lines nearly overlap.
                }
            }


        }
    }

    @ViewBuilder
    private var activityTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snap.pending.contains("hours") && snap.dailyHours.isEmpty {
                LoadingCard(title: T("Hours / longest run"), height: 84)
            }
            if snap.hasCchours && !snap.dailyHours.isEmpty {
                Card {
                    SectionLabel(text: T("Hours / longest run"))
                    // Same foregroundStyle(by:) rendering bug as DualLineRow above.
                    let hoursVals = snap.dailyHours.map(\.agentHours)
                    let longestVals = snap.dailyHours.map(\.longestRunHours)
                    let hMin = hoursVals.min() ?? 0, hMax = max(hoursVals.max() ?? 1, hMin + 0.001)
                    let lMin = longestVals.min() ?? 0, lMax = max(longestVals.max() ?? 1, lMin + 0.001)
                    let longestToHoursScale: (Double) -> Double = { (($0 - lMin) / (lMax - lMin)) * (hMax - hMin) + hMin }
                    let hoursScaleToLongest: (Double) -> Double = { (($0 - hMin) / (hMax - hMin)) * (lMax - lMin) + lMin }
                    let hoursRows: [DualLineRow] = snap.dailyHours.flatMap { row in
                        [
                            DualLineRow(date: row.date, series: T("Hours"), value: row.agentHours),
                            DualLineRow(date: row.date, series: T("Longest run"), value: longestToHoursScale(row.longestRunHours)),
                        ]
                    }
                    Chart(hoursRows) { r in
                        LineMark(x: .value(T("Date"), r.date, unit: .day), y: .value(T("Time"), r.value))
                            .foregroundStyle(by: .value(T("Kind"), r.series))
                            .interpolationMethod(.monotone)
                    }
                    // Domain fixed to real [hMin,hMax] — otherwise Swift Charts auto-expands
                    // ticks and the right axis's inverse transform shows out-of-range values (measured: -33%).
                    .chartYScale(domain: hMin...hMax)
                    .chartForegroundStyleScale(domain: [T("Hours"), T("Longest run")], range: [Viz.accentCyan, Viz.accentPurple])
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
                        HStack(spacing: 3) { Circle().fill(Viz.accentCyan).frame(width: 6, height: 6); Text(T("Hours")).font(.system(size: 9)).foregroundStyle(.secondary) }
                        HStack(spacing: 3) { Circle().fill(Viz.accentPurple).frame(width: 6, height: 6); Text(T("Longest run")).font(.system(size: 9)).foregroundStyle(.secondary) }
                    }

                    Divider().padding(.vertical, 2)

                    // Same data source as hours (cchours --daily) — kept in one card rather than split.
                    SectionLabel(text: T("Parallelism / delegation"))
                    let parVals = snap.dailyHours.map(\.parallelism)
                    let subVals = snap.dailyHours.map { $0.subShare * 100 }
                    let pMin = parVals.min() ?? 0, pMax = max(parVals.max() ?? 1, pMin + 0.001)
                    let sMin = subVals.min() ?? 0, sMax = max(subVals.max() ?? 1, sMin + 0.001)
                    let subToParScale: (Double) -> Double = { (($0 - sMin) / (sMax - sMin)) * (pMax - pMin) + pMin }
                    let parScaleToSub: (Double) -> Double = { (($0 - pMin) / (pMax - pMin)) * (sMax - sMin) + sMin }
                    let rows: [DualLineRow] = snap.dailyHours.flatMap { row in
                        [
                            DualLineRow(date: row.date, series: T("Parallelism"), value: row.parallelism),
                            DualLineRow(date: row.date, series: T("Delegation"), value: subToParScale(row.subShare * 100)),
                        ]
                    }
                    Chart(rows) { r in
                        LineMark(x: .value(T("Date"), r.date, unit: .day), y: .value(T("Value"), r.value))
                            .foregroundStyle(by: .value(T("Kind"), r.series))
                            .interpolationMethod(.monotone)
                    }
                    // Domain fixed for the same reason as above (avoids negative-value axis labels).
                    .chartYScale(domain: pMin...pMax)
                    .chartForegroundStyleScale(domain: [T("Parallelism"), T("Delegation")], range: [Viz.accentCyan, Viz.accentOrange])
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
                        HStack(spacing: 3) { Circle().fill(Viz.accentCyan).frame(width: 6, height: 6); Text(T("Parallelism (concurrent agents)")).font(.system(size: 9)).foregroundStyle(.secondary) }
                        HStack(spacing: 3) { Circle().fill(Viz.accentOrange).frame(width: 6, height: 6); Text(T("Delegation (share of subagent time)")).font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
                }
            }

            if snap.pending.contains("context") && snap.contextUsageSeries.isEmpty {
                LoadingCard(title: T("Context usage (distribution)"))
            }
            if snap.hasCcsendstats, !snap.contextUsageSeries.isEmpty {
                Card {
                    SectionLabel(text: T("Context usage (distribution)"))
                    // Fan chart (p25-p75 + p50) rather than p50 alone — p25/p75 vary day to day too (measured: p75 ranged 46%-78%).
                    Text(T("band = p25–p75, line = median (p50)")).font(.system(size: 10)).foregroundStyle(.secondary)
                    Chart(snap.contextUsageSeries) { p in
                        AreaMark(x: .value(T("Date"), p.date, unit: .day), yStart: .value("p25", p.p25Pct), yEnd: .value("p75", p.p75Pct))
                            .foregroundStyle(Viz.accentPurple.opacity(0.2)).interpolationMethod(.monotone)
                        LineMark(x: .value(T("Date"), p.date, unit: .day), y: .value("p50", p.p50Pct))
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
                    SectionLabel(text: T("Activity"))
                    // Enlarged 56pt → 104pt — at 56pt each cell was ~2.3pt tall; 104pt gives ~4.3pt.
                    HoursHeatmap(grid: snap.hourlyHeatmap).frame(height: 104)
                    HStack(spacing: 4) {
                        Text(T("older → newer (across) / fewer")).font(.system(size: 8)).foregroundStyle(.tertiary)
                        ForEach(0..<5) { i in
                            Rectangle().fill(HoursHeatmap.legendColor(i)).frame(width: 8, height: 8)
                        }
                        Text(T("more")).font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var qualityTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snap.pending.contains("tool") && snap.toolErrorRate == nil {
                LoadingCard(title: T("Tool failure rate"), height: 40)
            }
            if snap.hasCcflaky, let rate = snap.toolErrorRate {
                Card {
                    SectionLabel(text: T("Tool failure rate"))
                    HStack {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .foregroundStyle(rate >= 10 ? Viz.statusCritical : rate >= 5 ? Viz.statusWarning : .secondary)
                        Text(tToday(rate)).font(.system(size: 12, weight: .medium))
                        Spacer()
                        if let n = snap.toolCallsToday {
                            Text(tCalls(n)).font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                    }
                    if !snap.errorRateSeries.isEmpty {
                        Chart(snap.errorRateSeries) { p in
                            LineMark(x: .value(T("Date"), p.date, unit: .day), y: .value(T("Failure rate"), p.errorRate))
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

            if snap.pending.contains("skills") && snap.skillsTotal == nil {
                LoadingCard(title: T("Skills fired"), height: 64)
            }
            if snap.hasCcskillstats, let fired = snap.skillsFired, let total = snap.skillsTotal, total > 0 {
                Card {
                    SectionLabel(text: T("Skills fired"))
                    HStack {
                        Image(systemName: "sparkles").foregroundStyle(fired == total ? Viz.statusGood : Viz.statusWarning)
                        Text(tFired(fired, total)).font(.system(size: 12, weight: .medium))
                    }
                    // tool = Claude invoked it itself, typed = user typed /name, auto = cron etc.
                    // Measured: auto 63%, tool only 17% — descriptions are barely picked up in conversation.
                    if !snap.skillFireKindSeries.isEmpty {
                        let kindCategories = ["tool", "typed", "auto"]
                        let kindColors = [Viz.accentCyan, Viz.accentOrange, Color.secondary]
                        Chart(snap.skillFireKindSeries) { r in
                            AreaMark(x: .value(T("Date"), r.date, unit: .day), y: .value(T("Count"), r.count), stacking: .standard)
                                .foregroundStyle(by: .value(T("Kind"), r.kind))
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
                            Text(tCalls(s.total))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Viz.accentPurple).fixedSize()
                        }
                    }
                }
            }

            // "Task" = one session (no gap threshold) — a prior 90-min-gap definition made
            // values unreliable (e.g. 239 utterances / 1 task on a busy day); switching
            // dropped measured CV from 1.15 to 0.56. Self-correction rate below doesn't depend on this.
            if snap.pending.contains("attention") && snap.attentionSeries.isEmpty {
                LoadingCard(title: T("Turns per session"))
            }
            if snap.hasAttention, !snap.attentionSeries.isEmpty {
                Card {
                    SectionLabel(text: T("Turns per session"))
                    if let today = snap.attentionPerThreadToday {
                        HStack {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .foregroundStyle(Viz.accentCyan)
                            Text(tTodayTurns(today))
                                .font(.system(size: 12, weight: .medium))
                        }
                    }
                    Text(T("how many round trips an average session took"))
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                    Chart(snap.attentionSeries) { p in
                        LineMark(x: .value(T("Date"), p.date, unit: .day), y: .value(T("turns/session"), p.perThread))
                            .foregroundStyle(Viz.accentCyan).interpolationMethod(.monotone)
                        PointMark(x: .value(T("Date"), p.date, unit: .day), y: .value(T("turns/session"), p.perThread))
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

            if snap.pending.contains("attention") && snap.attentionSeries.isEmpty {
                LoadingCard(title: T("Self-correction / bounces"))
            }
            if snap.hasAttention, !snap.attentionSeries.isEmpty {
                Card {
                    SectionLabel(text: T("Self-correction / bounces"))
                    Text(T("share of turns that walked back the previous one")).font(.system(size: 9)).foregroundStyle(.tertiary)
                    Chart(snap.attentionSeries) { p in
                        LineMark(x: .value(T("Date"), p.date, unit: .day), y: .value(T("Self-correction"), p.selffixRate))
                            .foregroundStyle(Viz.accentOrange).interpolationMethod(.monotone)
                        PointMark(x: .value(T("Date"), p.date, unit: .day), y: .value(T("Self-correction"), p.selffixRate))
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
                    // Raw bounce count doesn't depend on the task definition above. Measured:
                    // 0-2 right after shipping (8/14-8/17) was measurement not working yet; 37-127 from 8/18 on.
                    Text(T("Bounce count")).font(.system(size: 9)).foregroundStyle(.tertiary)
                    Chart(snap.attentionSeries) { p in
                        LineMark(x: .value(T("Date"), p.date, unit: .day), y: .value(T("Bounces"), p.blocksRaw))
                            .foregroundStyle(Viz.accentRed).interpolationMethod(.monotone)
                        PointMark(x: .value(T("Date"), p.date, unit: .day), y: .value(T("Bounces"), p.blocksRaw))
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
            // $/Mtok and token count are on very different scales (0-2 vs tens of
            // millions) — kept as separate charts rather than dual y-axis.

            // Combined fixed-cost baseline + memory breakdown into one stacked card —
            // "other" is the part not explained by memory (system prompt, CLAUDE.md, tool defs, etc).
            if !baselineBreakdownSeries.isEmpty {
                let baseCategories = ["feedback", "project", "user", "reference", "other"]
                let baseColors = [Viz.accentOrange, Viz.accentCyan, Viz.accentPurple, Viz.accentBlue, Color.secondary]
                Card {
                    SectionLabel(text: T("Fixed tokens"))
                    // Only memory subcategories (feedback/project/user/reference) are actually
                    // color-coded — system prompt/CLAUDE.md/tool defs are lumped into "other" below.
                    Text(T("Sent automatically every session regardless of what it contains. Memory plus everything else (system prompt, CLAUDE.md, tool definitions)."))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Chart(baselineBreakdownSeries) { p in
                        AreaMark(x: .value(T("Date"), p.date, unit: .day), y: .value(T("Tokens"), p.tokens), stacking: .standard)
                            .foregroundStyle(by: .value(T("Kind"), p.category))
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

            // Removed the input-breakdown-by-billing-rate card — real data showed 96-99%
            // was always cache-read, barely moving. Calc logic stays in Data.swift for reuse.

            // Measured over 30 days: interrupt rate rose from 0% to 100%.
            if !snap.interruptSeries.isEmpty {
                Card {
                    SectionLabel(text: T("Interrupt rate while running"))
                    Chart(snap.interruptSeries) { p in
                        LineMark(x: .value(T("Date"), p.date, unit: .day), y: .value(T("Interrupt rate"), p.interruptRate))
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
                    Text(T("share of prompts sent while the previous turn was still running")).font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // ImageRenderer draws a ScrollView's content as empty (SwiftUI limitation) — real
    // content is factored out; --render-preview draws it directly at full height.
    @ViewBuilder
    var panelContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.tint)
                Text("ccwatch").font(.system(size: 13, weight: .semibold))
                // Custom tap gesture + NSWorkspace.shared.open instead of Link — Link bridges
                // through NSButton and risks the same ImageRenderer bug as the segmented picker.
                Text(T("how it is calculated"))
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
                    SectionLabel(text: T("Commands not found"))
                    // Must match the same 6 CLIs as anyCLIFound above — this was 4, silently hiding two cards.
                    Text(T("None of cchours, ccusage, ccattention, ccflaky, ccskillstats or ccsendstats is on PATH."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("npm install -g cchours ccusage ccattention ccflaky ccskillstats ccsendstats")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .padding(6).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            // Tab switching was reverted — users wanted all charts visible at once, not
            // hidden behind tabs. Kept the original left/right split with the merge improvements.
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

    // ScrollView doesn't report its size to MenuBarExtra(.window) — settled at a
    // default 354pt even though content was 740pt+ (measured). Manual GeometryReader
    // measurement collapsed to 0×0 instead. Fix: .fixedSize(vertical: true) + outer .frame(maxHeight:).
    var body: some View {
        // Originally .frame(maxHeight:) alone truncated overflow with no way to reach it on small screens.
        ScrollView(.vertical) {
            panelContent
        }
        .frame(width: 660)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: maxPanelHeight, alignment: .top)
        .onAppear { Task { await snap.refresh() } }
    }
}

/// Renders offscreen via ImageRenderer, independent of display sleep/lid state.
/// Spins the RunLoop while waiting for snap.refresh() — a semaphore would deadlock MainActor.
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

/// Also renders the compact menu bar label to PNG — screencapture can't always wake
/// the display (lid closed / deep sleep). Writes to "<path>-menubar.png".
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
            MenuBarLabel(snap: snap, bakeToImage: false)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color(light: "#fcfcfb", dark: "#1a1a19")),
            to: menubarPath
        )
        done = true
    }
    // Deadline guards against snap.refresh() never returning — CLI calls already
    // have their own timeout in runJSON; this is defense in depth.
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
        // Checked before the multi-instance guard below — meant to run while a resident
        // instance is active; the guard would otherwise silently exit(0) here first.
        if let idx = CommandLine.arguments.firstIndex(of: "--render-preview"),
           idx + 1 < CommandLine.arguments.count {
            renderPreviewAndExit(to: CommandLine.arguments[idx + 1])
        }

        // Guards against multiple instances double-hitting the same rate-limit endpoint (measured).
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
