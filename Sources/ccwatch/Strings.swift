import Foundation

/// Display strings: English by default, Japanese when the system language is.
///
/// Keys are English so a missing entry degrades to English, which an English
/// reader can still use; keying on Japanese would leave untranslated Japanese
/// in an English window.
///
/// Two languages do not justify a resource bundle or a string catalog — .lproj
/// directories would add steps to the build and to packaging.
func T(_ en: String) -> String {
    guard isJapanese else { return en }
    return ja[en] ?? en
}

/// Resolved once: the menu bar redraws every minute.
let isJapanese: Bool = {
    // Read through UserDefaults so a launch argument such as
    // -AppleLanguages "(en)" overrides it, which is how this gets tested.
    let langs = UserDefaults.standard.stringArray(forKey: "AppleLanguages")
        ?? Locale.preferredLanguages
    guard let first = langs.first else { return false }
    return first.hasPrefix("ja")
}()

private let ja: [String: String] = [
    // — summary tiles
    "Hours": "稼働時間",
    "Cost": "コスト",
    "Tokens": "トークン",
    "30d ": "30日 ",

    // — rate limits
    "Rate limits": "レート制限",
    "5-hour": "5時間枠",
    "Weekly": "週次枠",
    "Fetching…": "取得中…",

    // — cost
    "Cost trend": "コスト推移",
    "Date": "日付",
    "Model": "モデル",
    "Token cost ($/Mtok)": "トークンコスト($/Mtok)",

    // — hours
    "Hours / longest run": "稼働時間 / 最長連続稼働",
    "Longest run": "最長連続稼働",
    "Time": "時間",
    "Kind": "種別",
    "Parallelism / delegation": "並列度 / 委譲率",
    "Parallelism": "並列度",
    "Delegation": "委譲率",
    "Parallelism (concurrent agents)": "並列度(同時実行の倍率)",
    "Delegation (share of subagent time)": "委譲率(サブエージェント時間の割合)",
    "Value": "値",

    // — context
    "Context usage (distribution)": "コンテキスト使用率(分布)",
    "band = p25–p75, line = median (p50)": "帯 = p25-p75、線 = 中央値(p50)",

    // — activity
    "Activity": "アクティビティ",
    "older → newer (across) / fewer": "古い日→新しい日 (横) / 少ない",
    "more": "多い",

    // — tools
    "Tool failure rate": "ツール失敗率",
    "Failure rate": "失敗率",

    // — skills
    "Skills fired": "スキル発火",
    "Count": "回数",

    // — attention
    "Turns per session": "セッションあたり発話数",
    "turns/session": "発話/セッション",
    "how many round trips an average session took":
        "1セッションが平均何往復か。長い=1本で色々やった or 手間取った",
    "Self-correction / bounces": "自己訂正率 / 差し戻し",
    "Self-correction": "自己訂正率",
    "Bounces": "差し戻し",
    "Bounce count": "差し戻し件数",
    "share of turns that walked back the previous one": "直前の自分の発言を訂正した割合",

    // — baseline
    "Fixed tokens": "固定トークン",
    "Sent automatically every session regardless of what it contains. Memory plus everything else (system prompt, CLAUDE.md, tool definitions).":
        "セッションの中身によらず毎回自動で送られる分。内訳はメモリ + その他(system prompt・CLAUDE.md・ツール定義)",

    // — interrupt
    "Interrupt rate while running": "実行中の割り込み率",
    "Interrupt rate": "割り込み率",
    "share of prompts sent while the previous turn was still running":
        "実行中(前のターン継続中)に次を送った割合",

    // — chrome
    "how it is calculated": "計算ロジック",
    "Counting…": "集計中…",
    "Commands not found": "コマンドが見つかりません",
    "None of cchours, ccusage, ccattention, ccflaky, ccskillstats or ccsendstats is on PATH.":
        "cchours・ccusage・ccattention・ccflaky・ccskillstats・ccsendstats のいずれもPATH上に見つかりませんでした。",

    // — rate limit errors (Data.swift)
    "Not signed in (run claude to log in)": "ログイン情報が見つかりません(claude でログインしてください)",
    "Login expired (run claude once)": "ログインの有効期限が切れています(claude を一度実行してください)",
    "Rate limited (will retry on the next refresh)": "レート制限に達しました(次回更新時に再試行します)",
    "Could not fetch rate limits": "レート制限を取得できませんでした",
]

// Strings that wrap a value are functions, not table entries: word order
// differs by language, so concatenating fragments reads wrong in one of them.
func tHour(_ h: Int) -> String { isJapanese ? "\(h)時" : "\(h):00" }
func tCalls(_ n: Int) -> String { isJapanese ? "\(n)回" : "\(n)×" }
func tWindow(_ name: String) -> String { isJapanese ? "\(name)枠" : "\(name)" }
func tFired(_ fired: Int, _ total: Int) -> String {
    isJapanese ? "\(fired) / \(total) 発火" : "\(fired) / \(total) fired"
}
func tToday(_ pct: Double) -> String {
    isJapanese ? String(format: "今日 %.1f%%", pct) : String(format: "today %.1f%%", pct)
}
func tTodayTurns(_ v: Double) -> String {
    isJapanese ? String(format: "今日 %.1f 発話/セッション", v)
               : String(format: "today %.1f turns/session", v)
}
