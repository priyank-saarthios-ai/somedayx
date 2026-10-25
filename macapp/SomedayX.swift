// SomedayX: search everything you've saved on X, from the menu bar.
//
// Double-tap ⌥, ⌥⌘X or a click on the menu bar icon opens a Spotlight-style
// panel. Type to search; X-style operators work: from:handle is:bookmark
// is:like has:image has:video has:link year:2025 since:2025-03 until:2025-06.
// With nothing typed, the panel is a home screen: topics, a forgotten gem and
// ⌘R for a surprise. ⌘Y opens SomedayX Wrapped, a shareable card.
// First launch runs a short onboarding; right-click the icon for the rest.
//
// The app owns everything that needs a permission: it runs the local search
// server and syncs as child processes, posts its own notifications,
// schedules the nightly sync, and registers itself as a login item.

import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI
import UserNotifications

let info = Bundle.main.infoDictionary ?? [:]
let projectDir = URL(fileURLWithPath: info["SDXProjectDir"] as? String ?? "")  // the code
let uvPath = info["SDXUvPath"] as? String ?? "/opt/homebrew/bin/uv"
/// Your data, kept out of the code folder (the same place the Python side uses).
let dataDir = ProcessInfo.processInfo.environment["SOMEDAYX_HOME"].map { URL(fileURLWithPath: $0) }
    ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SomedayX")
let logDir = dataDir.appendingPathComponent("logs")

/// The search server only answers requests carrying this; it lives in a
/// file only you can read, shared with the server.
let accessToken: String = {
    let file = dataDir.appendingPathComponent("token")
    if let t = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
        return t
    }
    try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    var bytes = [UInt8](repeating: 0, count: 24)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    let t = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    FileManager.default.createFile(atPath: file.path, contents: Data(t.utf8), attributes: [.posixPermissions: 0o600])
    return t
}()

/// A local URL (images) with the access token attached.
func serverURL(_ path: String) -> URL? {
    URL(string: serverBase + path + (path.contains("?") ? "&" : "?") + "t=" + accessToken)
}
let port = 8765
let serverBase = "http://127.0.0.1:\(port)"
let nightlyHour = 3
let toolPath = [
    "\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
].joined(separator: ":")

// MARK: - X look

extension Color {
    static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }

    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

enum X {
    static let bg = Color.dynamic(dark: NSColor(hex: 0x000000), light: NSColor(hex: 0xFFFFFF))
    static let raised = Color.dynamic(dark: NSColor(hex: 0x16181C), light: NSColor(hex: 0xF7F9F9))
    static let field = Color.dynamic(dark: NSColor(hex: 0x202327), light: NSColor(hex: 0xEFF3F4))
    static let line = Color.dynamic(dark: NSColor(hex: 0x2F3336), light: NSColor(hex: 0xEFF3F4))
    static let text = Color.dynamic(dark: NSColor(hex: 0xE7E9EA), light: NSColor(hex: 0x0F1419))
    static let muted = Color.dynamic(dark: NSColor(hex: 0x71767B), light: NSColor(hex: 0x536471))
    static let blue = Color(hex: 0x1D9BF0)
    static let pink = Color(hex: 0xF91880)
    static let green = Color(hex: 0x00BA7C)
}

// MARK: - Motion

/// Quick, springy, and off entirely under Reduce motion.
enum Motion {
    static var reduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || snapshotting
    }

    /// Snapshots (SOMEDAYX_SNAPSHOT) render a still frame.
    static let snapshotting = ProcessInfo.processInfo.environment["SOMEDAYX_SNAPSHOT"] != nil

    static func spring(_ response: Double = 0.3, _ damping: Double = 0.82) -> Animation? {
        reduced ? nil : .spring(response: response, dampingFraction: damping)
    }

    static func ease(_ duration: Double = 0.18) -> Animation? { reduced ? nil : .easeOut(duration: duration) }
}

// MARK: - Data

struct Post: Decodable, Identifiable, Hashable {
    struct Media: Decodable, Hashable {
        let type: String?
        let src: String?
        let original: String?
    }

    struct Link: Decodable, Hashable {
        let url: String
        let title: String?
    }

    let id: String
    let url: String
    let screen_name: String
    let name: String?
    let profile_image: String?
    let created_at: String?
    let full_text: String?
    let is_bookmark: Int
    let is_like: Int
    let favorite_count: Int?
    let repost_count: Int?
    let reply_count: Int?
    let views_count: Int?
    let summary: String?
    let tags: [String]
    let q_author: String?
    let q_name: String?
    let q_text: String?
    let media: [Media]
    let links: [String: Link]
    let matched_by: [String]?
    let article_title: String?
    let article_preview: String?
    let article_words: Int?

    var isArticle: Bool { article_title != nil || article_preview != nil }

    /// "6 min read" once the article's full text has been read.
    var readingTime: String? {
        guard let w = article_words, w > 50 else { return nil }
        return "\(max(1, w / 230)) min read"
    }

    var date: Date? { created_at.flatMap { ISO8601DateFormatter().date(from: $0) } }

    var avatarURL: URL? { biggerAvatar(profile_image) }

    /// Links that leave X (articles, repos…), with page titles when known.
    var outboundLinks: [Link] {
        links.values
            .filter { !$0.url.contains("://x.com/") && !$0.url.contains("://twitter.com/") }
            .sorted { $0.url < $1.url }
    }
}

func biggerAvatar(_ url: String?) -> URL? {
    url.flatMap { URL(string: $0.replacingOccurrences(of: "_normal.", with: "_bigger.")) }
}

struct SearchResponse: Decodable {
    let results: [Post]
    let filters: [String: String]
    let terms: [String]
    let semantic: Bool?
}

/// The local models (EmbeddingGemma for search, optional Gemma 4 for
/// tl;drs) and the index, as the search server reports them.
struct Brain: Decodable, Equatable {
    struct Part: Decodable, Equatable {
        let state: String
        let done: Int?
        let total: Int?
        let source: String?
        let error: String?
        let stage: String?
        let running: Bool?

        var busy: Bool { ["finding", "verifying", "copying", "downloading", "starting", "indexing"].contains(state) }
        var percent: Int {
            guard let t = total, t > 0 else { return 0 }
            return min(100, Int(Double(done ?? 0) / Double(t) * 100))
        }
    }

    let embed: Part
    let writer: Part
    let index: Part
    let writer_on: Bool
    let found_on_mac: Bool
    let embed_size: Int
    let writer_size: Int
    let free_space: Int
    let llama: Bool
    let counts: Counts?

    struct Counts: Decodable, Equatable {
        let posts: Int?
        let posts_total: Int?
        let images: Int?
        let images_total: Int?
        let articles: Int?
        let indexed_at: String?  // UTC, "yyyy-MM-dd HH:mm:ss"

        var indexedDate: Date? {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            f.timeZone = TimeZone(identifier: "UTC")
            return indexed_at.flatMap { f.date(from: $0) }
        }
    }

    var busy: Bool { embed.busy || writer.busy || index.busy }

    /// 0…1 for whatever is running, for progress bars.
    var fraction: Double {
        let p = embed.busy ? embed : writer.busy ? writer : index
        guard let t = p.total, t > 0 else { return 0 }
        return min(1, Double(p.done ?? 0) / Double(t))
    }

    var step: String? {
        guard index.busy else { return nil }
        let n = ["posts": 1, "ocr": 2, "images": 3][index.stage ?? ""] ?? 1
        return "step \(n) of 3"
    }

    /// One line about whatever the brain is doing, or nil when it's idle.
    var activity: String? {
        if embed.busy { return embed.state == "starting" ? "waking gemma up…" : "getting gemma ready… \(embed.percent)%" }
        if writer.busy { return "getting gemma 4 ready… \(writer.percent)%" }
        if index.busy, let t = index.total, t > 0 {
            let n = "\((index.done ?? 0).formatted())/\(t.formatted())"
            switch index.stage {
            case "ocr": return "reading text in images… \(n)"
            case "images": return "gemma is looking at your images… \(n)"
            default: return "gemma is reading your posts… \(n)"
            }
        }
        if index.busy { return "gemma is indexing…" }
        if embed.state == "error" { return "gemma couldn't start. right-click → show sync log" }
        return nil
    }
}

struct SyncProgress: Decodable, Equatable {
    let phase: String?
    let seen: Int?
    let new: Int?
    let avatars: [String]?
    let paused: Bool?
    let done: Int?
    let total: Int?
}

struct Stats: Decodable {
    struct LastSync: Decodable {
        let at: String?
        let state: String?
        let message: String?
        let bookmark: Int?
        let like: Int?
    }

    let total: Int
    let bookmarks: Int
    let likes: Int
    let last_sync: LastSync?
    let progress: SyncProgress?
    let handle: String?
    let brain: Brain?
}

struct Topic: Decodable, Hashable {
    let tag: String
    let count: Int
}

struct Home: Decodable {
    let topics: [Topic]
    let gem: Post?
    let throwback: Post?
    let hints: [String]
}

struct Wrapped: Decodable, Equatable {
    struct Author: Decodable, Hashable, Equatable {
        let screen_name: String
        let name: String?
        let profile_image: String?
        let count: Int
    }

    let handle: String?
    let source: String?
    let total: Int
    let bookmarks: Int
    let likes: Int
    let people: Int
    let videos: Int
    let articles: Int?
    let topics: [Topic]
    let authors: [Author]
    let by_year: [String: Int]
    let viral: Post?
    let oldest: Post?
    // Material for the random cards.
    let underdog: Underdog?
    let one_hit: Int?
    let threads: Int?
    let reading_hours: Double?
    let double_tapped: Int?
    let median_likes: Int?
    let replies: Int?

    struct Underdog: Decodable, Equatable {
        let screen_name: String
        let likes: Int
        let text: String
    }

    var noun: String { source == "bookmark" ? "bookmarks" : source == "like" ? "likes" : "posts saved" }
    var firstYear: String? { by_year.keys.min() }
    var peak: (year: String, count: Int)? { by_year.max { $0.value < $1.value }.map { ($0.key, $0.value) } }

    /// "one save every 1.4 days", since the oldest save.
    var pace: String? {
        guard let start = oldest?.date, total > 1 else { return nil }
        let days = Date().timeIntervalSince(start) / 86400 / Double(total)
        if days < 1 { return "\(String(format: "%.0f", 1 / days)) saves a day" }
        return "one save every \(String(format: days < 10 ? "%.1f" : "%.0f", days)) days"
    }

    /// A label for what someone saves, from their top topics.
    var persona: String {
        let archetypes: [([String], String)] = [
            (["agent", "llm", "claude", "gpt", "openai", "vibe coding", "prompt", " ai", "ai "], "🤖 AI agent maximalist"),
            (["startup", "founder", "venture", "fundrais", "saas"], "🚀 founder brain, unemployed thumbs"),
            (["design", "figma", "typography"], "🎨 certified design snob"),
            (["open source", "github", "developer", "coding", "engineering"], "🧑‍💻 professional repo hoarder"),
            (["product"], "🧩 PM in denial"),
            (["marketing", "growth", "seo"], "📈 growth goblin"),
            (["humor", "meme", "comedy"], "🤡 meme archivist"),
            (["cricket", "football", "sport"], "🏏 armchair selector"),
        ]
        let top = topics.prefix(5).map { " \($0.tag) " }
        for (keys, label) in archetypes where top.contains(where: { t in keys.contains { t.contains($0) } }) {
            return label
        }
        return "🗂️ chief curator of the timeline"
    }

    /// One-liners for the home card, a little roast-y.
    var facts: [String] {
        var f: [String] = []
        if videos > 0 { f.append("\(videos.formatted()) videos saved to watch later. you've watched maybe 3 🙃") }
        if let a = authors.first, a.count > 2 {
            f.append("you've saved @\(a.screen_name) \(a.count) times. just turn on their notifications 🔔")
        }
        if let p = peak { f.append("\(p.year) was peak hoarding: \(p.count.formatted()) saves. you good? 📈") }
        if let n = articles, n > 0 { f.append("\(n) articles saved ≈ \(max(1, n * 8 / 60)) hours of reading. someday™ 📚") }
        if let v = viral, let likes = v.favorite_count, likes > 10_000 {
            f.append("most viral thing you saved: @\(v.screen_name), \(Fmt.count(likes)) likes. very underground of you")
        }
        if let o = oldest, let d = o.date {
            let text = Fmt.plain(o)
            let snippet = text.count > 48 ? String(text.prefix(46)) + "…" : text
            f.append("your oldest save is from \(Calendar.current.component(.year, from: d)): “\(snippet)” 🦕")
        }
        if source == nil && likes > bookmarks * 2 && bookmarks > 0 {
            f.append("you like \(String(format: "%.1f", Double(likes) / Double(bookmarks)))× more than you bookmark. generous thumb ❤️")
        }
        if people > 50 { f.append("\(people.formatted()) different people made it into your someday pile. a whole city 🏙️") }
        if let u = underdog { f.append("you saved a post with \(u.likes) likes. @\(u.screen_name) owes you one 🐣") }
        if let n = one_hit, n > 0 { f.append("\(n.formatted()) accounts you saved exactly once. commitment issues? 🎯") }
        if let n = threads, n > 0 { f.append("\(n.formatted()) threads saved. you've finished maybe 2 🧵") }
        if let n = double_tapped, n > 0, source == nil { f.append("\(n.formatted()) posts you liked AND bookmarked. they really got you 💘") }
        if let m = median_likes { f.append("your median save has \(Fmt.count(m)) likes. taste over clout 🍷") }
        if let n = replies, n > 10 { f.append("\(n.formatted()) replies saved. you read the comments 💬") }
        return f
    }

    /// Everything a random card can show. Lines for the post never @mention
    /// anyone, so sharing doesn't tag strangers.
    var stats: [WrapStat] {
        var s: [WrapStat] = []
        if let u = underdog {
            s.append(WrapStat(emoji: "🐣", title: "certified early fan", value: "\(u.likes) likes",
                              detail: "on a post i saved. day one fan", line: "saved a post with \(u.likes) likes. early supporter energy"))
        }
        if let v = viral, let l = v.favorite_count, l > 10_000 {
            s.append(WrapStat(emoji: "📣", title: "mainstream moment", value: "\(Fmt.count(l)) likes",
                              detail: "my most viral save", line: "my most viral save has \(Fmt.count(l)) likes. very underground"))
        }
        if let n = one_hit, n > 0 {
            s.append(WrapStat(emoji: "🎯", title: "one-hit wonders", value: "\(n.formatted()) accounts",
                              detail: "saved exactly once", line: "\(n.formatted()) accounts i saved exactly once. no favourites"))
        }
        if let n = threads, n > 0 {
            s.append(WrapStat(emoji: "🧵", title: "threads to finish", value: "\(n.formatted()) threads",
                              detail: "someday. probably", line: "\(n.formatted()) threads i'll finish someday 🧵"))
        }
        if let h = reading_hours, h >= 1 {
            let hours = h < 10 ? String(format: "%.1f", h) : String(Int(h))
            s.append(WrapStat(emoji: "📚", title: "reading backlog", value: "\(hours) hours",
                              detail: "of articles, unread", line: "\(hours) hours of articles in read later"))
        }
        if let n = double_tapped, n > 0, source == nil {
            s.append(WrapStat(emoji: "💘", title: "double tapped", value: "\(n.formatted()) posts",
                              detail: "liked AND bookmarked", line: "\(n.formatted()) posts i liked AND bookmarked. they hit different"))
        }
        if let m = median_likes {
            s.append(WrapStat(emoji: "🍷", title: "taste profile", value: "\(Fmt.count(m)) likes",
                              detail: "on my median save", line: "my median save has \(Fmt.count(m)) likes. taste > clout"))
        }
        if let n = replies, n > 10 {
            s.append(WrapStat(emoji: "💬", title: "reply guy energy", value: "\(n.formatted()) replies",
                              detail: "i read the comments", line: "\(n.formatted()) replies saved. i read the comments"))
        }
        if videos > 0 {
            s.append(WrapStat(emoji: "🙃", title: "watch later, sure", value: "\(videos.formatted()) videos",
                              detail: "i will not watch them", line: "\(videos.formatted()) videos in watch later. i will not watch them"))
        }
        if let t = topics.first {
            s.append(WrapStat(emoji: "🔥", title: "top obsession", value: t.tag, detail: nil, line: "top obsession: \(t.tag)"))
        }
        return s
    }
}

/// A stat as it reads on a card, and as a line in the shared post.
struct WrapStat: Equatable {
    let emoji: String
    let title: String
    let value: String
    let detail: String?
    let line: String
}

/// Shared posts end with this, so a share can turn into an install.
let somedayxLink: String? = "https://somedayx.com"

/// Deterministic randomness, so one seed always gives the same card.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// One random Wrapped card: the seed picks a headline, a colour theme and
/// three stats, so the preview, the shared image and the caption all match.
struct WrapCard {
    let headline: String
    let colors: [Color]
    let stats: [WrapStat]
    let caption: String

    static let headlines = ["my someday pile, wrapped", "the receipts 🧾", "my X saves, exposed", "certified hoarder report",
                            "what my bookmarks say about me", "a timeline autopsy 🔍", "saved, never read"]
    static let themes: [[Color]] = [
        [X.blue, X.pink], [Color(hex: 0x00BA7C), X.blue], [Color(hex: 0x7856FF), X.pink],
        [Color(hex: 0xFF7A00), X.pink], [X.blue, Color(hex: 0x7856FF)], [Color(hex: 0xFFD400), Color(hex: 0xFF7A00)],
    ]

    init(_ w: Wrapped, seed: UInt64) {
        var rng = SeededRNG(state: seed)
        headline = Self.headlines.randomElement(using: &rng)!
        colors = Self.themes.randomElement(using: &rng)!
        stats = Array(w.stats.shuffled(using: &rng).prefix(3))
        caption = Self.caption(w, stats: stats, rng: &rng)
    }

    /// A post with a point of view and a reason for others to try it,
    /// kept well under X's 280 (emoji count double there).
    static func caption(_ w: Wrapped, stats: [WrapStat], rng: inout SeededRNG) -> String {
        let persona = String(w.persona.drop { !$0.isLetter })
        let a = "aeiou".contains(persona.lowercased().first ?? "x") ? "an" : "a"
        let total = w.total.formatted()
        let since = w.firstYear.map { " since \($0)" } ?? ""
        let cta = somedayxLink.map { "get your own wrapped (free, runs on your mac) → \($0)" }
            ?? "made with somedayx. free, open source, 100% on your mac"
        func lines(_ n: Int) -> String { stats.prefix(n).map { "→ \($0.line)" }.joined(separator: "\n") }
        let templates: [(Int) -> String] = [
            { "an app read all \(total) of my X saves and decided i'm \(a) \(persona.lowercased()) 💀\n\n\(lines($0))\n\nwhat would yours say about you? 👀\n\(cta)" },
            { "my X bookmarks just roasted me 🫠\n\n\(lines($0))\n\nverdict: \(w.persona)\n\nyour turn. \(cta)" },
            { "\(total) saves\(since). the receipts 🧾\n\n\(lines($0))\n\napparently that makes me \(a) \(persona.lowercased()).\n\(cta)" },
            { "POV: you finally open your X saves 👀\n\n\(lines($0))\n\n\(w.persona). no notes.\n\(cta)" },
        ]
        let pick = templates.randomElement(using: &rng)!
        // Drop a stat line if it runs long.
        for n in stride(from: 3, through: 1, by: -1) {
            let text = pick(n)
            if text.count + text.unicodeScalars.filter(\.properties.isEmojiPresentation).count <= 270 { return text }
        }
        return pick(1)
    }
}

enum Scope: String, CaseIterable {
    case both = "Both", bookmarks = "Bookmarks", likes = "Likes"

    var icon: String? { self == .bookmarks ? "bookmark.fill" : self == .likes ? "heart.fill" : nil }
    var tint: Color { self == .likes ? X.pink : X.blue }

    /// What a number of these is called: "2,926 saves", "965 bookmarks".
    var noun: String { self == .bookmarks ? "bookmarks" : self == .likes ? "likes" : "saves" }
    var param: String? { self == .bookmarks ? "bookmark" : self == .likes ? "like" : nil }
}

// MARK: - Formatting, the way X does it

enum Fmt {
    static func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        let s = Date().timeIntervalSince(date)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return "\(Int(s / 3600))h" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
        return f.string(from: date)
    }

    static func full(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.dateFormat = "h:mm a · MMM d, yyyy"
        return f.string(from: date)
    }

    static func count(_ n: Int?) -> String {
        guard let n, n > 0 else { return "" }
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return trim(Double(n) / 1_000) + "K"
        default: return trim(Double(n) / 1_000_000) + "M"
        }
    }

    private static func trim(_ v: Double) -> String {
        v >= 100 ? String(Int(v)) : String(format: "%.1f", v).replacingOccurrences(of: ".0", with: "")
    }

    static func host(_ url: String) -> String {
        URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url
    }

    private static let tco = try! NSRegularExpression(pattern: #"https://t\.co/\w+"#)

    private static func dropMediaLink(_ post: Post) -> String {
        // Older exports keep X's HTML escapes.
        var text = (post.full_text ?? "").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        if !post.media.isEmpty, let r = text.range(of: #"\s*https://t\.co/\w+\s*$"#, options: .regularExpression) {
            text.removeSubrange(r)  // the trailing link to the post's own media
        }
        return text
    }

    /// Post text for list rows: t.co links become their domains and
    /// whitespace collapses, so two lines show as much as possible.
    static func plain(_ post: Post) -> String {
        let text = dropMediaLink(post)
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for m in tco.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let target = post.links[ns.substring(with: m.range)]?.url ?? "link"
            out += target.contains("/article/") ? "" : host(target)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// `text` with the words the search matched in bold, like X does.
    static func highlighted(_ text: String, terms: [String], size: CGFloat = 13) -> AttributedString {
        var out = AttributedString(text)
        guard !terms.isEmpty else { return out }
        let alternatives = terms.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        guard let re = try? NSRegularExpression(pattern: "(?i)(?<![\\w])(?:\(alternatives))\\w*") else { return out }
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text), let ar = Range(r, in: out) else { continue }
            out[ar].font = .system(size: size, weight: .bold)
            out[ar].foregroundColor = X.text
        }
        return out
    }

    /// Post text with t.co links replaced by real titles/domains and
    /// @mentions / #hashtags in X blue, all clickable.
    static func rich(_ post: Post) -> AttributedString {
        let text = dropMediaLink(post)
        var out = AttributedString()
        let pattern = try! NSRegularExpression(pattern: #"https://t\.co/\w+|(?<![\w@])@\w{1,15}|(?<![\w#&])#\w+"#)
        let ns = text as NSString
        var cursor = 0
        for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += AttributedString(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            let token = ns.substring(with: m.range)
            var piece: AttributedString
            if token.hasPrefix("https://t.co/") {
                let link = post.links[token]
                let target = link?.url ?? token
                let label = target.contains("/article/") ? "📰 " + (post.article_title ?? "X Article")
                    : link?.title.map { $0.count > 60 ? String($0.prefix(57)) + "…" : $0 }
                    ?? host(target) + (URL(string: target)?.path.prefix(24).description ?? "")
                piece = AttributedString(label)
                piece.link = URL(string: target)
            } else if token.hasPrefix("@") {
                piece = AttributedString(token)
                piece.link = URL(string: "https://x.com/\(token.dropFirst())")
            } else {
                piece = AttributedString(token)
                piece.link = URL(string: "https://x.com/hashtag/\(token.dropFirst())")
            }
            piece.foregroundColor = X.blue
            out += piece
            cursor = m.range.location + m.range.length
        }
        out += AttributedString(ns.substring(from: cursor))
        return out
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    enum Phase: Equatable { case starting, ready, failed(String) }
    enum Step: Int, CaseIterable { case welcome, connect, brain, syncing, shortcut }

    @Published var query = "" { didSet { if query != oldValue { queryChanged() } } }
    @Published var scope: Scope = .both { didSet { if scope != oldValue { home = nil; scheduleSearch(delay: 0) } } }
    /// With nothing typed, the panel opens on the home dashboard; this
    /// switches to the list of recent saves instead.
    @Published var browsing = false
    /// Stats for the home dashboard, for the selected tab.
    @Published var homeStats: Wrapped?
    @Published var results: [Post] = []
    @Published var labels: [String: String] = [:]  // home extras: "💎 forgotten gem"…
    @Published var terms: [String] = []
    @Published var filters: [String: String] = [:]
    @Published var selectedID: String?
    @Published var phase: Phase = .starting
    @Published var stats: Stats?
    @Published var home: Home?
    @Published var syncing = false { didSet { if syncing != oldValue { syncingChanged() } } }
    @Published var justSynced = false
    @Published var loading = false
    @Published var focusToken = UUID()
    @Published var appeared = false
    @Published var toast: String?
    @Published var confetti = 0
    @Published var newSaves = 0

    @Published var wrapped: Wrapped?
    @Published var showWrapped = false
    @Published var sharing = false
    /// Which random card is showing; the same seed is what gets shared.
    @Published var cardSeed = UInt64.random(in: 0...UInt64.max)
    private var shareCaption = ""
    var onShare: (String, String) -> Void = { _, _ in }

    @Published var step: Step? = UserDefaults.standard.bool(forKey: "onboarded") ? nil : .welcome
    @Published var optionTaps = 0
    @Published var practiced = false
    @Published var trusted = AXIsProcessTrusted()
    @Published var notificationsOn = false
    @Published var openAtLogin = true
    /// Posts found in lists already finished during this sync (onboarding counter).
    @Published var earlierFound = 0
    /// Onboarding choice: also write tl;drs with Gemma 4.
    @Published var useWriter = false
    /// Search ran on words only because the model isn't ready yet.
    @Published var wordsOnly = false
    /// Already onboarded, only the brain needs setting up (after an update).
    var brainOnly = false

    var onSync: () -> Void = {}
    var onWantsPanel: () -> Void = {}
    var onBrainDone: () -> Void = {}
    var onLoggedIn: () -> Void = {}
    var onMilestone: (String) -> Void = { _ in }
    var onAskNotifications: () -> Void = {}
    var onAskAccessibility: () -> Void = {}
    var onFinishOnboarding: (Bool) -> Void = { _ in }

    private var task: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var poll: Timer?
    private var brainPolling = false
    private var etaSample: (stage: String, at: Date, done: Int)?
    /// "about 12 min left" for the indexing step that's running.
    @Published var eta: String?

    var selected: Post? { results.first { $0.id == selectedID } ?? results.first }
    var onHome: Bool { query.isEmpty && !browsing }

    private func queryChanged() {
        if query.isEmpty { browsing = false }
        scheduleSearch()
    }

    func browseRecent() {
        withAnimation(Motion.spring()) { browsing = true }
        scheduleSearch(delay: 0)
    }

    func goHome() {
        withAnimation(Motion.spring()) { browsing = false; query = "" }
        scheduleSearch(delay: 0)
    }
    var progress: SyncProgress? { syncing ? stats?.progress : nil }
    var foundThisSync: Int { earlierFound + (progress?.new ?? 0) }
    var loggedOut: Bool { !syncing && stats?.last_sync?.state == "login" }
    var brain: Brain? { stats?.brain }

    func serverReady() {
        phase = .ready
        scheduleSearch(delay: 0)
        Task {
            await loadStats()
            if step == nil, !hasData, stats?.last_sync == nil {
                // Nothing saved and never synced (say, the data folder was
                // reset): the full onboarding, whatever the settings say.
                step = .welcome
                onWantsPanel()
            } else if step == nil, let b = brain, b.embed.state == "missing" {
                // Updated from a version without local models: just set those up.
                brainOnly = true
                useWriter = b.writer_on
                step = .brain
                onWantsPanel()
            }
            if brain?.busy == true { pollBrain() }
        }
    }

    func panelOpened() {
        focusToken = UUID()
        refreshStats()
        if query.isEmpty && step == nil && !showWrapped {
            browsing = false  // open on the dashboard
            home = nil  // a fresh gem every time
            scheduleSearch(delay: 0)
        }
    }

    // MARK: Network

    func post<T: Decodable>(_ path: String, _ body: [String: Any]) async throws -> T {
        var req = URLRequest(url: URL(string: serverBase + path)!)
        req.setValue(accessToken, forHTTPHeaderField: "X-SomedayX-Token")
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func get<T: Decodable>(_ path: String, _ items: [URLQueryItem] = []) async throws -> T {
        var c = URLComponents(string: serverBase + path)!
        if !items.isEmpty { c.queryItems = items }
        var req = URLRequest(url: c.url!)
        req.setValue(accessToken, forHTTPHeaderField: "X-SomedayX-Token")
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private var scopeItems: [URLQueryItem] { scope.param.map { [URLQueryItem(name: "source", value: $0)] } ?? [] }

    func scheduleSearch(delay: UInt64 = 120) {
        guard phase == .ready else { return }
        task?.cancel()
        task = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000) }
            guard !Task.isCancelled else { return }
            await fetch()
        }
    }

    private func fetch() async {
        if onHome { return await fetchHome() }
        loading = true
        defer { loading = false }
        do {
            let r: SearchResponse = try await get(
                "/api/search", [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "60")] + scopeItems)
            guard !Task.isCancelled else { return }
            var posts = r.results
            var labels: [String: String] = [:]
            if query.isEmpty {
                if home == nil { home = try? await get("/api/home", scopeItems) }
                guard !Task.isCancelled else { return }
                var extras: [Post] = []
                if let t = home?.throwback, let d = t.date {
                    labels[t.id] = "📅 this week in \(Calendar.current.component(.year, from: d))"
                    extras.append(t)
                }
                if let g = home?.gem, labels[g.id] == nil {
                    labels[g.id] = "💎 forgotten gem"
                    extras.append(g)
                }
                posts = extras + posts.filter { labels[$0.id] == nil }
            }
            withAnimation(Motion.ease()) {
                results = posts
                self.labels = labels
                terms = r.terms
                filters = r.filters
                wordsOnly = !query.isEmpty && r.semantic == false
                selectedID = posts.first?.id
            }
        } catch {
            if !Task.isCancelled && (error as? URLError)?.code != .cancelled {
                appLog("search failed: \(error)")
                results = []
            }
        }
    }

    /// The dashboard: stats for the tab, and topics for the chips.
    private func fetchHome() async {
        async let stats: Wrapped? = try? get("/api/wrapped", scopeItems)
        async let topics: Home? = home == nil ? try? get("/api/home", scopeItems) : nil
        let (w, h) = await (stats, topics)
        guard !Task.isCancelled, onHome else { return }
        withAnimation(Motion.ease()) {
            if let w { homeStats = w }
            if let h { home = h }
            results = []
            filters = [:]
            terms = []
            wordsOnly = false
        }
    }

    func reindex() {
        Task {
            let _: Brain? = try? await post("/api/brain/reindex", [:])
            try? await Task.sleep(for: .seconds(1))
            await loadStats()
            pollBrain()
            show(toast: "rebuilding the index. search keeps working 🧠")
        }
    }

    func refreshStats() {
        Task { await loadStats() }
    }

    func loadStats() async {
        guard let s: Stats = try? await get("/api/stats") else { return }
        let before = stats
        if before?.progress?.phase == "bookmark" && s.progress?.phase == "like" {
            earlierFound += before?.progress?.new ?? 0
        }
        if before?.progress?.phase == "login" && s.progress?.phase != "login" { onLoggedIn() }
        withAnimation(Motion.spring()) { stats = s }
        checkMilestone(total: s.total)
        updateETA(s.brain?.index)
        if s.brain?.busy == true { pollBrain() }
    }

    private func updateETA(_ index: Brain.Part?) {
        guard let i = index, i.busy, let stage = i.stage, let done = i.done, let total = i.total, total > 0 else {
            etaSample = nil
            eta = nil
            return
        }
        guard let sample = etaSample, sample.stage == stage, done >= sample.done else {
            etaSample = (stage, Date(), done)
            eta = nil
            return
        }
        let elapsed = Date().timeIntervalSince(sample.at)
        guard elapsed > 6, done > sample.done else { return }
        let left = Double(total - done) / (Double(done - sample.done) / elapsed)
        eta = left < 60 ? "under a minute left" : "about \(Int((left / 60).rounded(.up))) min left"
    }

    /// Follow model downloads and indexing until they finish.
    private func pollBrain() {
        guard !brainPolling else { return }
        brainPolling = true
        Task {
            var indexed = false
            while true {
                try? await Task.sleep(for: .seconds(1.5))
                if !syncing { await loadStats() }  // a sync polls already
                if brain?.index.busy == true { indexed = true }
                if brain?.busy != true { break }
            }
            brainPolling = false
            if indexed {
                scheduleSearch(delay: 0)  // the index grew
                show(toast: "gemma's all caught up 🧠")
                onBrainDone()
            }
        }
    }

    func installBrain() {
        Task {
            let _: Brain? = try? await post("/api/brain/install", ["writer": useWriter])
            await loadStats()
            pollBrain()
        }
    }

    func setWriter(_ on: Bool) {
        Task {
            let _: Brain? = try? await post("/api/brain/writer", ["on": on])
            await loadStats()
            pollBrain()
            show(toast: on ? "gemma will write tl;drs from the next sync ✍️" : "tl;drs off. 2.8 GB freed")
        }
    }

    // MARK: Sync

    private func syncingChanged() {
        poll?.invalidate()
        guard syncing else { return }
        earlierFound = 0
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStats() }
        }
    }

    func syncFinished(state: String, added: Int, manual: Bool) {
        syncing = false
        refreshStats()
        scheduleSearch(delay: 0)
        guard state == "ok" else { return }
        withAnimation(Motion.spring()) { justSynced = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(Motion.spring()) { justSynced = false }
        }
        if added > 0 {
            newSaves += 1
            show(toast: "+\(added.formatted()) new save\(added == 1 ? "" : "s") stashed 🔖")
        } else if manual {
            show(toast: "all caught up. go touch grass 🌱")
        }
    }

    static let milestones: [(Int, String)] = [
        (100, "the collection begins"), (500, "you have taste"), (1_000, "certified hoarder"),
        (2_500, "it's a library now"), (5_000, "reading list: never"), (10_000, "legendary"),
        (25_000, "touch grass. please."), (50_000, "you are the archive"),
    ]

    private func checkMilestone(total: Int) {
        let d = UserDefaults.standard
        guard let (n, line) = Self.milestones.last(where: { $0.0 <= total }) else { return }
        guard d.object(forKey: "milestone") != nil else { return d.set(n, forKey: "milestone") }  // no retro party
        guard n > d.integer(forKey: "milestone") else { return }
        d.set(n, forKey: "milestone")
        let text = "🎉 \(n.formatted()) saves. \(line)."
        celebrate(text)
        onMilestone(text)
    }

    // MARK: Moments

    func show(toast text: String) {
        withAnimation(Motion.spring()) { toast = text }
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.ease(0.25)) { toast = nil }
        }
    }

    func celebrate(_ text: String) {
        confetti += 1
        show(toast: text)
    }

    func surprise() {
        Task {
            struct R: Decodable { let post: Post? }
            guard let r: R = try? await get("/api/surprise", scopeItems), let p = r.post else { return }
            if onHome {  // a surprise opens the list, with it on top
                browsing = true
                await fetch()
            }
            withAnimation(Motion.spring()) {
                results = [p] + results.filter { $0.id != p.id }
                labels[p.id] = "🎲 surprise"
                selectedID = p.id
            }
        }
    }

    // MARK: Keyboard

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        let i = results.firstIndex { $0.id == selectedID } ?? 0
        withAnimation(Motion.spring(0.22, 0.9)) {
            selectedID = results[max(0, min(results.count - 1, i + delta))].id
        }
    }

    /// Remove an operator (e.g. from:lenny) from the query.
    func removeFilter(_ key: String) {
        let ops: [String: String] = ["author": "from", "media": "has", "since": "(?:since|year)", "until": "(?:until|year)"]
        guard let op = ops[key] else { return }
        query = query.replacingOccurrences(of: "(?i)\(op):\\S+\\s*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    func openSelected() { if let p = selected, let u = URL(string: p.url) { NSWorkspace.shared.open(u) } }

    func openLink() {
        guard let p = selected else { return }
        if let l = p.outboundLinks.first, let u = URL(string: l.url) { NSWorkspace.shared.open(u) } else { openSelected() }
    }

    func copyLink() {
        guard let p = selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(p.url, forType: .string)
        show(toast: "link copied")
    }

    // MARK: Wrapped

    func openWrapped() {
        guard phase == .ready else { return }
        Task {
            guard await currentWrapped() != nil else { return }
            withAnimation(Motion.spring(0.35, 0.85)) { showWrapped = true }
        }
    }

    func closeWrapped() { withAnimation(Motion.spring()) { showWrapped = false } }

    /// 🎲 a different headline, colours and stats.
    func reroll() { withAnimation(Motion.spring(0.4, 0.8)) { cardSeed = UInt64.random(in: 0...UInt64.max) } }

    /// Wrapped numbers for the selected tab (the home card's, when fresh).
    private func currentWrapped() async -> Wrapped? {
        var w = homeStats?.source == scope.param ? homeStats : nil
        if w == nil { w = try? await get("/api/wrapped", scopeItems) }
        guard let w else { return nil }
        wrapped = w
        return w
    }

    private func wrappedImage() -> NSImage? {
        guard let w = wrapped else { return nil }
        let r = ImageRenderer(content: WrappedCard(w: w, card: WrapCard(w, seed: cardSeed), countUp: false)
            .environment(\.colorScheme, .dark))
        r.scale = 2
        return r.nsImage
    }

    private func wrappedPNG() -> Data? {
        guard let tiff = wrappedImage()?.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    /// Debug aid for screenshots and the website: write the card image.
    func exportCard(to path: String) async {
        guard await currentWrapped() != nil, let png = wrappedPNG() else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    @discardableResult
    func copyWrapped(toast: Bool = true) -> Bool {
        guard let img = wrappedImage() else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        if toast { show(toast: "copied. go flex it 💅") }
        return true
    }

    func saveWrapped() {
        guard let png = wrappedPNG() else { return }
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("somedayx-wrapped.png")
        do {
            try png.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            show(toast: "saved to downloads")
        } catch {
            show(toast: "couldn't save: \(error.localizedDescription)")
        }
    }

    /// One click: X's composer opens with the caption typed and the image
    /// attached; you press Post.
    func shareWrapped() {
        guard !sharing, phase == .ready, !Motion.snapshotting else { return }
        sharing = true
        Task {
            guard let w = await currentWrapped() else { sharing = false; return }
            let url = dataDir.appendingPathComponent("share/somedayx-wrapped.png")
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard let png = wrappedPNG() else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: url)
            } catch {
                sharing = false
                return show(toast: "couldn't make the image: \(error.localizedDescription)")
            }
            shareCaption = WrapCard(w, seed: cardSeed).caption
            show(toast: "opening x with your wrapped attached. just hit post 🚀")
            onShare(url.path, shareCaption)
        }
    }

    /// The composer couldn't open (a sync has the browser, or it failed):
    /// fall back to X's share link with the image on the clipboard.
    func shareFinished(ok: Bool) {
        sharing = false
        defer { if ok { cardSeed = UInt64.random(in: 0...UInt64.max) } }  // something new next time
        guard !ok, copyWrapped(toast: false) else { return }
        var c = URLComponents(string: "https://x.com/intent/post")!
        c.queryItems = [URLQueryItem(name: "text", value: shareCaption)]
        NSWorkspace.shared.open(c.url!)
        show(toast: "image copied. paste it into the post with ⌘V")
    }

    // MARK: Onboarding

    var hasData: Bool { (stats?.total ?? 0) > 0 }

    func next() {
        guard let step else { return }
        switch step {
        case .welcome: go(.connect)
        case .connect: go(.brain)
        case .brain:
            guard brain != nil else { return }  // still starting up
            installBrain()
            if brainOnly {
                brainOnly = false
                withAnimation(Motion.spring(0.4, 0.86)) { self.step = nil }
                show(toast: "gemma is on it 🧠")
                return
            }
            if !hasData { onSync() }
            go(.syncing)
        case .syncing: go(.shortcut)
        case .shortcut: finishOnboarding()
        }
    }

    func go(_ s: Step) { withAnimation(Motion.spring(0.4, 0.86)) { step = s } }

    func restartOnboarding() {
        practiced = false
        brainOnly = false
        useWriter = brain?.writer_on ?? false
        go(.welcome)
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboarded")
        onFinishOnboarding(openAtLogin)
        withAnimation(Motion.spring(0.4, 0.86)) { step = nil }
        query = ""
        home = nil
        scheduleSearch(delay: 0)
        focusToken = UUID()
        celebrate("you're in. hit ⌘R for a surprise 🎲")
    }

    func optionTapped(double: Bool) {
        withAnimation(Motion.spring(0.2, 0.6)) { optionTaps += 1 }
        if double && !practiced {
            withAnimation(Motion.spring()) { practiced = true }
            confetti += 1
        }
    }
}

// MARK: - Small pieces

struct Avatar: View {
    let url: URL?
    var size: CGFloat = 40

    var body: some View {
        AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { X.raised }
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}

struct KeyCap: View {
    let label: String
    var lit = false
    var done = false
    var size: CGFloat = 64

    var body: some View {
        Text(label)
            .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
            .foregroundStyle(lit || done ? .white : X.text)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(done ? X.green : lit ? X.blue : X.raised)
                    .shadow(color: .black.opacity(lit ? 0 : 0.18), radius: 0, y: lit ? 0 : 3)
            )
            .overlay(RoundedRectangle(cornerRadius: size * 0.22).strokeBorder(X.line))
            .scaleEffect(lit ? 0.92 : 1)
            .offset(y: lit ? 2 : 0)
    }
}

struct PrimaryButton: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Text("↵").font(.system(size: 12, weight: .bold)).opacity(0.6)
            }
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(X.bg)
            .padding(.horizontal, 22).padding(.vertical, 11)
            .background(Capsule().fill(X.text))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }
}

struct SecondaryButton: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(X.text)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .overlay(Capsule().strokeBorder(X.line))
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }
}

/// Buttons squish a little when pressed.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.spring(0.2, 0.7), value: configuration.isPressed)
    }
}

struct Chip: View {
    let title: String
    var icon: String?
    var tint: Color = X.muted
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .overlay(Capsule().strokeBorder(X.line))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }
}

/// A shimmering placeholder while results load.
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { g in
                    LinearGradient(colors: [.clear, X.text.opacity(0.08), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.6)
                        .offset(x: phase * g.size.width * 1.4)
                }
                .mask(content)
            )
            .onAppear {
                guard !Motion.reduced else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

struct SkeletonRows: View {
    var count = 6

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(X.field).frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 4).fill(X.field).frame(width: 140, height: 10)
                        RoundedRectangle(cornerRadius: 4).fill(X.field).frame(height: 9)
                        RoundedRectangle(cornerRadius: 4).fill(X.field).frame(width: CGFloat(160 + (i * 37) % 120), height: 9)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
        }
        .modifier(Shimmer())
    }
}

/// Animatable number, so totals count up instead of snapping.
struct CountUp: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View { Text(Int(value).formatted()).monospacedDigit() }
}

struct Confetti: View {
    let trigger: Int
    @State private var start: Date?
    @State private var pieces: [Piece] = []

    struct Piece {
        let x: CGFloat, delay: Double, speed: CGFloat, drift: CGFloat, spin: Double, size: CGFloat
        let color: Color
    }

    static let colors = [X.blue, X.pink, X.green, Color(hex: 0xFFD400), Color(hex: 0x7856FF)]

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { tl in
            Canvas { ctx, size in
                guard let start else { return }
                let t = tl.date.timeIntervalSince(start)
                for p in pieces {
                    let tt = t - p.delay
                    guard tt > 0 else { continue }
                    let y = -16 + p.speed * tt + 260 * tt * tt
                    guard y < size.height + 20 else { continue }
                    var c = ctx
                    c.translateBy(x: p.x * size.width + p.drift * sin(tt * 3 + p.spin), y: y)
                    c.rotate(by: .radians(p.spin * tt * 5))
                    c.fill(Path(CGRect(x: -p.size / 2, y: -p.size / 4, width: p.size, height: p.size / 2)), with: .color(p.color))
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in
            guard !Motion.reduced else { return }
            pieces = (0..<110).map { _ in
                Piece(x: .random(in: 0...1), delay: .random(in: 0...0.5), speed: .random(in: 40...160),
                      drift: .random(in: 10...40), spin: .random(in: 0...6), size: .random(in: 7...12),
                      color: Self.colors.randomElement()!)
            }
            start = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { start = nil }
        }
    }
}

// MARK: - Search

struct SearchBar: View {
    @EnvironmentObject var store: Store
    @FocusState private var focused: Bool
    @State private var hint = 0

    var hints: [String] {
        ["search your saves"] + (store.home?.hints ?? ["that thread about pricing", "has:video", "is:like funny"]).map { "try “\($0)”" }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(focused ? X.blue : X.muted)
            ZStack(alignment: .leading) {
                if store.query.isEmpty {
                    Text(hints[hint % hints.count])
                        .font(.system(size: 16))
                        .foregroundStyle(X.muted)
                        .id(hint)
                        .transition(.push(from: .bottom))
                        .allowsHitTesting(false)
                }
                TextField("", text: $store.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(X.text)
                    .focused($focused)
            }
            .clipped()
            if store.loading { ProgressView().controlSize(.small) }
            if !store.query.isEmpty {
                Button { store.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(X.blue)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }
            ScopePicker()
        }
        .padding(.leading, 16).padding(.trailing, 6)
        .frame(height: 44)
        .background(Capsule().fill(focused ? X.bg : X.field))
        .overlay(Capsule().strokeBorder(focused ? X.blue : .clear, lineWidth: 1))
        .animation(Motion.ease(), value: store.query.isEmpty)
        .onAppear { focused = true }
        .onChange(of: store.focusToken) { _, _ in focused = true }
        .task(id: store.query.isEmpty) {
            while store.query.isEmpty && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3.2))
                guard store.query.isEmpty, !Task.isCancelled else { return }
                withAnimation(Motion.spring(0.45, 0.9)) { hint += 1 }
            }
        }
    }
}

/// Both / Bookmarks / Likes as a small switch inside the search bar: a
/// filter on what you see (stats and results), not separate pages.
struct ScopePicker: View {
    @EnvironmentObject var store: Store
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Scope.allCases, id: \.self) { s in
                let on = store.scope == s
                Button { withAnimation(Motion.spring(0.3, 0.8)) { store.scope = s } } label: {
                    HStack(spacing: 4) {
                        if let icon = s.icon { Image(systemName: icon).font(.system(size: 10.5, weight: .bold)) }
                        Text(s.rawValue)
                    }
                    .font(.system(size: 12, weight: on ? .bold : .semibold))
                    .foregroundStyle(on ? .white : X.muted)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background {
                        if on { Capsule().fill(s.tint).matchedGeometryEffect(id: "scope", in: ns) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(s.rawValue) (⌘\(Scope.allCases.firstIndex(of: s)! + 1))")
            }
        }
        .padding(3)
        .background(Capsule().fill(X.field))
    }
}

struct FilterChips: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let labels: [(String, String)] = [
            ("author", store.filters["author"].map { "From @\($0)" }),
            ("media", store.filters["media"].map { "Has \($0)" }),
            ("since", store.filters["since"].map { "Since \($0)" }),
            ("until", store.filters["until"].map { "Until \($0)" }),
        ].compactMap { k, v in v.map { (k, $0) } }
        if !labels.isEmpty {
            HStack(spacing: 6) {
                ForEach(labels, id: \.0) { key, label in
                    Button { store.removeFilter(key) } label: {
                        HStack(spacing: 4) {
                            Text(label)
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(X.blue)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(X.blue.opacity(0.12)))
                    }
                    .buttonStyle(PressStyle())
                    .transition(.scale.combined(with: .opacity))
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
    }
}

/// Home shortcuts above the list when nothing is typed.
struct TopicChips: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("jump to").font(.system(size: 12, weight: .semibold)).foregroundStyle(X.muted)
                ForEach(store.home?.topics ?? [], id: \.self) { t in
                    Chip(title: t.tag) { store.query = t.tag }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 10)
    }
}

struct LoginBanner: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark").foregroundStyle(X.blue)
            Text("x logged you out, so syncing is paused.").foregroundStyle(X.text)
            Spacer()
            Button { store.onSync() } label: {
                Text("reconnect").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(X.blue))
            }
            .buttonStyle(PressStyle())
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(X.blue.opacity(0.1))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// Shown on the home screen while models download or Gemma indexes.
struct BrainBanner: View {
    @EnvironmentObject var store: Store
    @State private var pulse = false

    var body: some View {
        if let b = store.brain, b.busy, let line = b.activity {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "brain").foregroundStyle(X.blue)
                        .opacity(pulse ? 0.45 : 1)
                        .onAppear {
                            guard !Motion.reduced else { return }
                            withAnimation(.easeInOut(duration: 0.9).repeatForever()) { pulse = true }
                        }
                    Text(line).foregroundStyle(X.text).contentTransition(.numericText())
                    Spacer()
                    Text([b.step, store.eta].compactMap { $0 }.joined(separator: " · ")).foregroundStyle(X.muted)
                }
                .font(.system(size: 12.5, weight: .semibold))
                ProgressView(value: b.fraction).progressViewStyle(.linear).tint(X.blue)
                    .animation(Motion.ease(0.4), value: b.fraction)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(X.blue.opacity(0.08))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct Row: View {
    let post: Post
    let selected: Bool
    let label: String?
    let terms: [String]
    let ns: Namespace.ID

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(url: post.avatarURL, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                if let label {
                    Text(label).font(.system(size: 11.5, weight: .bold)).foregroundStyle(X.blue).padding(.bottom, 1)
                }
                HStack(spacing: 4) {
                    Text(post.name ?? post.screen_name).font(.system(size: 13.5, weight: .bold)).foregroundStyle(X.text)
                        .lineLimit(1)
                        .layoutPriority(1)
                    Text("@\(post.screen_name)").font(.system(size: 13)).foregroundStyle(X.muted)
                        .lineLimit(1)
                    Text("· \(Fmt.relative(post.date))").font(.system(size: 13)).foregroundStyle(X.muted)
                        .lineLimit(1)
                        .fixedSize()
                    Spacer(minLength: 4)
                    if post.media.contains(where: { $0.type != "photo" }) {
                        Image(systemName: "play.rectangle").foregroundStyle(X.muted)
                    } else if !post.media.isEmpty {
                        Image(systemName: "photo").foregroundStyle(X.muted)
                    }
                    if post.is_bookmark == 1 { Image(systemName: "bookmark.fill").foregroundStyle(X.blue) }
                    if post.is_like == 1 { Image(systemName: "heart.fill").foregroundStyle(X.pink) }
                }
                .font(.system(size: 11))
                text
                    .font(.system(size: 13))
                    .foregroundStyle(X.text.opacity(0.85))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background {
            if selected {
                Rectangle().fill(X.blue.opacity(0.14))
                    .overlay(alignment: .leading) { Rectangle().fill(X.blue).frame(width: 3) }
                    .matchedGeometryEffect(id: "selection", in: ns)
            }
        }
        .contentShape(Rectangle())
    }

    /// The post's own words (what you remember), not the AI summary.
    var text: Text {
        let plain = Fmt.plain(post)
        if let title = post.article_title {
            return Text("📰 ").font(.system(size: 13))
                + Text(Fmt.highlighted(title, terms: terms)).bold()
                + Text(plain.isEmpty ? "" : " · ") + Text(Fmt.highlighted(plain, terms: terms))
        }
        if plain.isEmpty {
            return Text(post.summary ?? (post.media.isEmpty ? "" : "media only")).italic()
        }
        return Text(Fmt.highlighted(plain, terms: terms))
    }
}

struct MediaGrid: View {
    let media: [Post.Media]

    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: media.count > 1 ? 2 : 1)
        LazyVGrid(columns: cols, spacing: 2) {
            ForEach(Array(media.prefix(4).enumerated()), id: \.offset) { _, m in
                let url = m.src.flatMap { $0.hasPrefix("/") ? serverURL($0) : URL(string: $0) }
                ZStack {
                    AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { X.raised }
                        .frame(height: media.count > 1 ? 150 : 260)
                        .clipped()
                    if m.type != "photo" {
                        Image(systemName: "play.fill").font(.system(size: 20)).foregroundStyle(.white)
                            .padding(14).background(Circle().fill(X.blue))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if let o = m.original, let u = URL(string: o) { NSWorkspace.shared.open(u) } }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(X.line))
    }
}

struct Preview: View {
    let post: Post

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Avatar(url: post.avatarURL, size: 44)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(post.name ?? post.screen_name).font(.system(size: 15, weight: .bold)).foregroundStyle(X.text)
                        Text("@\(post.screen_name)").font(.system(size: 14)).foregroundStyle(X.muted)
                    }
                    Spacer()
                    Button { if let u = URL(string: post.url) { NSWorkspace.shared.open(u) } } label: {
                        Text("Open on X").font(.system(size: 13, weight: .bold)).foregroundStyle(X.bg)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(X.text))
                    }
                    .buttonStyle(PressStyle())
                }

                Text(Fmt.rich(post))
                    .font(.system(size: 15))
                    .foregroundStyle(X.text)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if post.isArticle {
                    Button { if let u = URL(string: post.url) { NSWorkspace.shared.open(u) } } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.richtext")
                                Text(["X ARTICLE", post.readingTime?.uppercased()].compactMap { $0 }.joined(separator: " · "))
                            }
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(X.muted)
                            if let t = post.article_title {
                                Text(t).font(.system(size: 17, weight: .heavy)).foregroundStyle(X.text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let p = post.article_preview {
                                Text(p).font(.system(size: 13.5)).foregroundStyle(X.muted).lineLimit(4)
                            }
                            Text("read on X →").font(.system(size: 13, weight: .bold)).foregroundStyle(X.blue)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(X.line))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                }

                if let summary = post.summary, !summary.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("tl;dr").font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(X.blue)
                        Text(summary).font(.system(size: 13)).foregroundStyle(X.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(X.raised))
                }

                if !post.media.isEmpty { MediaGrid(media: post.media) }

                if let q = post.q_text {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Text(post.q_name ?? post.q_author ?? "").font(.system(size: 13, weight: .bold)).foregroundStyle(X.text)
                            Text("@\(post.q_author ?? "")").font(.system(size: 13)).foregroundStyle(X.muted)
                        }
                        Text(q).font(.system(size: 13.5)).foregroundStyle(X.text).lineLimit(6)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(X.line))
                }

                ForEach(post.outboundLinks.prefix(3), id: \.url) { link in
                    Button { if let u = URL(string: link.url) { NSWorkspace.shared.open(u) } } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Fmt.host(link.url)).font(.system(size: 12)).foregroundStyle(X.muted)
                            Text(link.title ?? link.url).font(.system(size: 13.5)).foregroundStyle(X.text).lineLimit(2)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(X.line))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                }

                HStack(spacing: 4) {
                    Text(Fmt.full(post.date))
                    if let v = post.views_count, v > 0 {
                        Text("·")
                        Text(Fmt.count(v)).bold().foregroundStyle(X.text)
                        Text("Views")
                    }
                }
                .font(.system(size: 13)).foregroundStyle(X.muted)

                Divider().overlay(X.line)

                HStack {
                    stat("bubble.left", post.reply_count, X.muted)
                    stat("arrow.2.squarepath", post.repost_count, X.muted)
                    stat(post.is_like == 1 ? "heart.fill" : "heart", post.favorite_count, post.is_like == 1 ? X.pink : X.muted)
                    stat(post.is_bookmark == 1 ? "bookmark.fill" : "bookmark", nil, post.is_bookmark == 1 ? X.blue : X.muted)
                }

                if !post.tags.isEmpty {
                    FlowTags(tags: post.tags)
                }

                if post.matched_by == ["meaning"] {
                    Label("no exact words. found by meaning", systemImage: "sparkles")
                        .font(.system(size: 12)).foregroundStyle(X.muted)
                } else if post.matched_by == ["image"] {
                    Label("found in an image", systemImage: "photo")
                        .font(.system(size: 12)).foregroundStyle(X.muted)
                }
            }
            .padding(18)
        }
    }

    func stat(_ symbol: String, _ n: Int?, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(Fmt.count(n))
        }
        .font(.system(size: 13))
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct FlowTags: View {
    let tags: [String]
    @EnvironmentObject var store: Store

    var body: some View {
        // Simple wrapping layout: rows of tags that fit the width.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { chips(tags) }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { chips(Array(tags.prefix(4))) }
                HStack(spacing: 6) { chips(Array(tags.dropFirst(4))) }
            }
        }
    }

    @ViewBuilder func chips(_ list: [String]) -> some View {
        ForEach(list, id: \.self) { t in
            Chip(title: t) { store.query = t }
        }
    }
}

struct EmptyState: View {
    let emoji: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(emoji).font(.system(size: 40))
            Text(title).font(.system(size: 22, weight: .heavy)).foregroundStyle(X.text)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(X.muted).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 360, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
    }
}

struct Footer: View {
    @EnvironmentObject var store: Store
    @State private var spin = false

    var body: some View {
        HStack(spacing: 14) {
            if store.onHome {
                hint("↓", "browse")
                hint("⌘R", "surprise me")
                hint("⌘Y", "wrapped")
            } else {
                hint("↵", "open")
                hint("⌘L", "link")
                hint("⇧⌘C", "copy")
                hint("esc", "home")
            }
            Spacer()
            status
            Button { store.openWrapped() } label: {
                Label("wrapped", systemImage: "sparkles").foregroundStyle(X.blue)
            }
            .buttonStyle(PressStyle())
            .help("Your SomedayX Wrapped (⌘Y)")
            syncButton
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(X.raised)
    }

    @ViewBuilder var status: some View {
        if let p = store.progress {
            Text(progressText(p)).foregroundStyle(X.muted).contentTransition(.numericText())
        } else if store.syncing {
            Text("syncing with x…").foregroundStyle(X.muted)
        } else if store.brain?.busy == true {
            Text("gemma is working on it ↑").foregroundStyle(X.muted)
        } else if let line = store.brain?.activity {
            Text(line).foregroundStyle(X.muted)
        } else if store.wordsOnly {
            Text("matching words only until gemma is ready").foregroundStyle(X.muted)
        } else if let s = store.stats {
            HStack(spacing: 4) {
                Text(syncText(s)).foregroundStyle(X.muted)
                Image(systemName: "bookmark.fill").foregroundStyle(X.blue)
                    .symbolEffect(.bounce, value: store.newSaves)
                CountUp(value: Double(s.total)).foregroundStyle(X.text).fontWeight(.semibold)
            }
        }
    }

    var syncButton: some View {
        Button { store.onSync() } label: {
            ZStack {
                if store.justSynced {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(X.green)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "arrow.clockwise").foregroundStyle(X.blue)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(spin && !Motion.reduced ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default,
                                   value: spin)
                }
            }
            .frame(width: 16)
        }
        .buttonStyle(PressStyle())
        .disabled(store.syncing)
        .help("Sync now")
        .onChange(of: store.syncing) { _, s in spin = s }
        .onAppear { spin = store.syncing }
    }

    func progressText(_ p: SyncProgress) -> String {
        switch p.phase {
        case "login": return "waiting for you to log in to x…"
        case "bookmark", "like":
            if p.paused == true { return "x asked us to slow down. back in a minute ☕️" }
            return "stashing \(p.phase!)s… \(store.foundThisSync.formatted()) new"
        case "fetch": return "grabbing links and images…"
        case "articles": return "reading x articles… \(p.done ?? 0)/\(p.total ?? 0)"
        case "write":
            guard let t = p.total, t > 0 else { return "gemma is writing tl;drs…" }
            return "gemma is writing tl;drs… \(p.done ?? 0)/\(t)"
        case "index": return "gemma is indexing new posts…"
        default: return "syncing with x…"
        }
    }

    func syncText(_ s: Stats) -> String {
        guard let last = s.last_sync, let at = last.at, let date = DateFormatter.iso.date(from: at) else { return "" }
        switch last.state {
        case "login": return "logged out of x ·"
        case "error": return "last sync failed ·"
        default:
            let when = Fmt.relative(date)
            let ago = when == "now" ? "just now" : "\(when) ago"
            let added = (last.bookmark ?? 0) + (last.like ?? 0)
            return added == 0 && Date().timeIntervalSince(date) < 86400 ? "all caught up · synced \(ago) ·" : "synced \(ago) ·"
        }
    }

    func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(X.text)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(X.field))
            Text(label).foregroundStyle(X.muted)
        }
    }
}

extension DateFormatter {
    static let iso: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
}

// MARK: - Onboarding

struct Onboarding: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let step = store.step ?? .welcome
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(Store.Step.allCases, id: \.self) { s in
                    Capsule().fill(s.rawValue <= step.rawValue ? X.blue : X.line)
                        .frame(width: s == step ? 22 : 8, height: 8)
                }
            }
            .padding(.top, 28)
            .opacity(store.brainOnly ? 0 : 1)

            ZStack {
                switch step {
                case .welcome: Welcome().transition(slide)
                case .connect: Connect().transition(slide)
                case .brain: BrainStep().transition(slide)
                case .syncing: FirstSync().transition(slide)
                case .shortcut: Shortcut().transition(slide)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(X.bg)
    }

    var slide: AnyTransition {
        .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity))
    }
}

struct StepPage<Art: View, Actions: View>: View {
    let title: String
    let text: String
    @ViewBuilder var art: Art
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            art
            VStack(spacing: 10) {
                Text(title).font(.system(size: 30, weight: .heavy)).foregroundStyle(X.text)
                Text(text).font(.system(size: 15)).foregroundStyle(X.muted)
                    .multilineTextAlignment(.center).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 520)
            actions
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
    }
}

struct Welcome: View {
    @EnvironmentObject var store: Store

    var body: some View {
        StepPage(title: "your x saves, searchable in a blink",
                 text: "every bookmark and like, on your mac. type what you remember and somedayx finds it. private, local, no account.") {
            DemoLoop()
        } actions: {
            PrimaryButton(title: "let's go") { store.next() }
        }
    }
}

/// A tiny looping demo: double-tap ⌥, type, results appear.
struct DemoLoop: View {
    @State private var lit = -1
    @State private var typed = ""
    @State private var rows = 0
    let phrase = "that thread about pricing"

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                KeyCap(label: "⌥", lit: lit == 0, size: 46)
                KeyCap(label: "⌥", lit: lit == 1, size: 46)
            }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(X.blue)
                    Text(typed.isEmpty ? " " : typed).foregroundStyle(X.text)
                    Rectangle().fill(X.blue).frame(width: 1.5, height: 15).opacity(rows == 0 ? 1 : 0)
                    Spacer()
                }
                .font(.system(size: 14))
                .padding(.horizontal, 14).frame(height: 36)
                .overlay(Capsule().strokeBorder(X.blue))
                .padding(10)
                ForEach(0..<rows, id: \.self) { i in
                    HStack(spacing: 8) {
                        Circle().fill([X.blue, X.pink, X.green][i].opacity(0.8)).frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 4) {
                            RoundedRectangle(cornerRadius: 3).fill(X.text.opacity(0.7)).frame(width: 90, height: 6)
                            RoundedRectangle(cornerRadius: 3).fill(X.muted.opacity(0.5)).frame(width: CGFloat(200 - i * 30), height: 6)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(i == 0 ? X.blue.opacity(0.12) : .clear)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: 340, height: 160, alignment: .top)
            .background(RoundedRectangle(cornerRadius: 14).fill(X.raised))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(X.line))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .task {
            if Motion.reduced { typed = phrase; rows = 3; return }
            while !Task.isCancelled {
                for k in 0..<2 {
                    withAnimation(.spring(response: 0.15, dampingFraction: 0.6)) { lit = k }
                    try? await Task.sleep(for: .milliseconds(160))
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.6)) { lit = -1 }
                    try? await Task.sleep(for: .milliseconds(120))
                }
                for ch in phrase {
                    typed.append(ch)
                    try? await Task.sleep(for: .milliseconds(55))
                }
                for i in 1...3 {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { rows = i }
                    try? await Task.sleep(for: .milliseconds(110))
                }
                try? await Task.sleep(for: .seconds(2.2))
                withAnimation(.easeOut(duration: 0.2)) { rows = 0; typed = "" }
                try? await Task.sleep(for: .milliseconds(600))
            }
        }
    }
}

struct Connect: View {
    @EnvironmentObject var store: Store

    var body: some View {
        StepPage(title: "connect x",
                 text: "a chrome window opens just for logging in to x. once you're in, it closes by itself.") {
            VStack(alignment: .leading, spacing: 12) {
                promise("lock.fill", "no servers, no accounts, no tracking. ever.")
                promise("eye.fill", "read-only. it never posts, likes or follows.")
                promise("internaldrive.fill", "everything lives in one folder on your mac.")
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 16).fill(X.raised))
        } actions: {
            VStack(spacing: 12) {
                if store.hasData {
                    Label("connected\(store.stats?.handle.map { " as @\($0)" } ?? "") · \(store.stats!.total.formatted()) saves stashed",
                          systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(X.green)
                    PrimaryButton(title: "continue") { store.next() }
                } else {
                    PrimaryButton(title: "open x login") { store.next() }
                }
            }
        }
    }

    func promise(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(X.blue).frame(width: 18)
            Text(text).font(.system(size: 14)).foregroundStyle(X.text)
        }
    }
}

struct BrainStep: View {
    @EnvironmentObject var store: Store

    var body: some View {
        StepPage(title: "meet your search brain",
                 text: "somedayx runs google's gemma models right here on your mac. they read your posts and images so you can search by meaning. nothing leaves your mac.") {
            if let b = store.brain {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 12) {
                        model("sparkle.magnifyingglass", "EmbeddingGemma", "search by meaning, across text and images")
                        Spacer()
                        Text(embedStatus(b)).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(b.embed.state == "ready" || b.found_on_mac ? X.green : X.muted)
                    }
                    Divider().overlay(X.line)
                    HStack(alignment: .top, spacing: 12) {
                        model("text.quote", "Gemma 4 tl;drs (optional)",
                              "a one-line summary and tags for every new post. adds a few seconds per post while syncing.")
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            Toggle("", isOn: $store.useWriter).toggleStyle(.switch).labelsHidden().tint(X.blue)
                            Text(writerStatus(b)).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(b.writer.state == "ready" ? X.green : X.muted)
                        }
                    }
                    if !b.llama {
                        Label("needs llama.cpp. run: brew install llama.cpp", systemImage: "wrench.and.screwdriver.fill")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(X.pink)
                    } else if let warning = spaceWarning(b) {
                        Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(X.pink)
                    }
                }
                .padding(18)
                .frame(width: 500)
                .background(RoundedRectangle(cornerRadius: 16).fill(X.raised))
            } else {
                ProgressView().controlSize(.small)
            }
        } actions: {
            PrimaryButton(title: store.brainOnly ? "set it up" : "continue") { store.next() }
                .disabled(store.brain == nil)
        }
    }

    func model(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(X.blue).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(X.text)
                Text(subtitle).font(.system(size: 12.5)).foregroundStyle(X.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func gb(_ bytes: Int) -> String { String(format: "%.1f GB", Double(bytes) / 1e9) }

    func embedStatus(_ b: Brain) -> String {
        if b.embed.state == "ready" { return "ready ✓" }
        if b.embed.busy { return "\(b.embed.percent)%" }
        return b.found_on_mac ? "already on your mac ✓" : "\(gb(b.embed_size)) download"
    }

    func writerStatus(_ b: Brain) -> String {
        if b.writer.state == "ready" { return "on your mac ✓" }
        if b.writer.busy { return "\(b.writer.percent)%" }
        return "\(gb(b.writer_size)) download"
    }

    func spaceWarning(_ b: Brain) -> String? {
        var needed = 0
        if b.embed.state != "ready" && !b.found_on_mac { needed += b.embed_size }
        if store.useWriter && b.writer.state != "ready" { needed += b.writer_size }
        guard needed > 0, needed + 500_000_000 > b.free_space else { return nil }
        return "not enough space: needs \(gb(needed)), \(gb(b.free_space)) free"
    }
}

struct FirstSync: View {
    @EnvironmentObject var store: Store

    /// When no sync is running, this screen follows the brain instead.
    var brainWork: Bool { !store.syncing && store.brain?.busy == true }

    var counter: Double {
        if store.syncing { return Double(store.foundThisSync) }
        if brainWork, let b = store.brain {
            return Double(b.index.busy ? b.index.done ?? 0 : b.embed.busy ? b.embed.percent : b.writer.percent)
        }
        return Double(store.stats?.total ?? 0)
    }

    var body: some View {
        let p = store.progress
        StepPage(title: title(p), text: text(p)) {
            VStack(spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    CountUp(value: counter)
                    if brainWork && store.brain?.index.busy != true { Text("%") }
                }
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .foregroundStyle(X.text)
                .animation(Motion.spring(0.5, 0.9), value: counter)
                if store.syncing, let line = store.brain?.activity {
                    Text(line).font(.system(size: 13, weight: .semibold)).foregroundStyle(X.blue)
                }
                HStack(spacing: -8) {
                    ForEach(Array((p?.avatars ?? []).suffix(9)), id: \.self) { a in
                        Avatar(url: biggerAvatar(a), size: 34)
                            .overlay(Circle().strokeBorder(X.bg, lineWidth: 2))
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(height: 36)
                .animation(Motion.spring(), value: p?.avatars ?? [])
                if ["fetch", "write", "index"].contains(p?.phase ?? "") || brainWork {
                    ProgressView().progressViewStyle(.linear).frame(width: 220).tint(X.blue)
                }
            }
        } actions: {
            HStack(spacing: 10) {
                if store.syncing && !store.notificationsOn {
                    SecondaryButton(title: "ping me when it's done") { store.onAskNotifications() }
                }
                PrimaryButton(title: store.syncing ? "set up the shortcut meanwhile" : "next") { store.next() }
            }
        }
    }

    func title(_ p: SyncProgress?) -> String {
        if brainWork, let b = store.brain {
            if b.index.busy { return "teaching gemma your saves…" }
            return "getting gemma ready…"
        }
        if !store.syncing { return store.hasData ? "done. you're stashed 🎉" : "hmm, nothing came through" }
        switch p?.phase {
        case "login": return "log in to x 👀"
        case "bookmark": return "stashing your bookmarks…"
        case "like": return "stashing your likes…"
        case "fetch", "write", "index": return "making it all searchable 🧠"
        default: return "opening chrome…"
        }
    }

    func text(_ p: SyncProgress?) -> String {
        if brainWork, let b = store.brain {
            if b.index.busy {
                switch b.index.stage {
                case "ocr": return "reading the text in your images. memes and screenshots become searchable."
                case "images": return "looking at every image so you can search for what's in them."
                default: return "reading every post once. search by meaning works as soon as this is done."
                }
            }
            return b.found_on_mac ? "found gemma on your mac already. setting it up." : "a one-time download. after this, everything runs offline."
        }
        if !store.syncing {
            return store.hasData ? "\(store.stats!.total.formatted()) posts, ready to search."
                : "the sync didn't finish. check that you're logged in, then hit sync in the footer."
        }
        if p?.paused == true { return "x asked us to slow down. back in a minute ☕️" }
        switch p?.phase {
        case "login": return "use the chrome window that just opened. it closes by itself once you're in."
        case "bookmark", "like": return "the first sync scrolls your whole history. it can take a while for big collections. close this anytime, it keeps going."
        case "fetch": return "grabbing link titles and images so search can find them."
        case "write": return "gemma is writing tl;drs for your new posts."
        case "index": return "gemma is reading your new posts and images."
        default: return "a chrome window will pop up in a second."
        }
    }
}

struct Shortcut: View {
    @EnvironmentObject var store: Store

    var body: some View {
        StepPage(title: store.practiced ? "nailed it 🎉" : "now the fun part",
                 text: "double-tap ⌥ option to open somedayx from anywhere. try it right now.") {
            HStack(spacing: 14) {
                KeyCap(label: "⌥", lit: !store.practiced && store.optionTaps % 2 == 1, done: store.practiced)
                KeyCap(label: "⌥", lit: false, done: store.practiced)
            }
            .animation(Motion.spring(0.2, 0.6), value: store.optionTaps)
        } actions: {
            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    if store.trusted {
                        Label("works in every app", systemImage: "checkmark.circle.fill").foregroundStyle(X.green)
                    } else {
                        HStack(spacing: 12) {
                            Text("to make it work in every app, allow somedayx under accessibility. it only listens for ⌥.")
                                .foregroundStyle(X.text).fixedSize(horizontal: false, vertical: true)
                            SecondaryButton(title: "allow") { store.onAskAccessibility() }
                        }
                        Text("or use ⌥⌘X. no permission needed.").foregroundStyle(X.muted)
                    }
                    Toggle("open somedayx when my mac starts", isOn: $store.openAtLogin)
                        .toggleStyle(.switch).tint(X.blue).foregroundStyle(X.text)
                }
                .font(.system(size: 13))
                .padding(16)
                .frame(width: 460, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16).fill(X.raised))
                PrimaryButton(title: "start searching") { store.next() }
            }
        }
    }
}

// MARK: - Wrapped

struct WrappedCard: View {
    let w: Wrapped
    let card: WrapCard
    var countUp = true
    @State private var shown: Double = 0

    var body: some View {
        let years = w.by_year.sorted { $0.key < $1.key }
        let peak = max(years.map(\.value).max() ?? 1, 1)
        let (c1, c2) = (card.colors[0], card.colors[1])
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(w.handle.map { "@\($0)'s someday pile" } ?? "my someday pile").foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text(card.headline).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(LinearGradient(colors: [c1, c2], startPoint: .leading, endPoint: .trailing)))
            }
            .font(.system(size: 13, weight: .bold))

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                CountUp(value: countUp ? shown : Double(w.total))
                    .font(.system(size: 70, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text(w.source == nil ? "posts" : w.noun).font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.top, 8)
            Text("saved on x\(w.firstYear.map { " since \($0)" } ?? "") · \(w.persona)")
                .font(.system(size: 15, weight: .bold)).foregroundStyle(c1)
                .lineLimit(1).minimumScaleFactor(0.8)

            HStack(alignment: .top, spacing: 10) {
                ForEach(card.stats, id: \.title) { stat in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stat.emoji).font(.system(size: 20))
                        Text(stat.title).font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white.opacity(0.55))
                            .textCase(.uppercase).lineLimit(1).minimumScaleFactor(0.8)
                        Text(stat.value).font(.system(size: 17, weight: .heavy)).foregroundStyle(.white)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        if let d = stat.detail {
                            Text(d).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
                }
            }
            .padding(.top, 18)

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(years, id: \.key) { _, n in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(n == peak ? AnyShapeStyle(LinearGradient(colors: [c1, c2], startPoint: .bottom, endPoint: .top))
                                        : AnyShapeStyle(.white.opacity(0.2)))
                        .frame(height: max(3, CGFloat(n) / CGFloat(peak) * 30))
                }
            }
            .frame(height: 30, alignment: .bottom)
            .padding(.top, 16)

            Spacer(minLength: 0)
            HStack {
                Text(w.peak.map { "peak era: \($0.year) 🔥" } ?? "").foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text("🔖 made with somedayx · free & 100% on-device").foregroundStyle(.white.opacity(0.5))
            }
            .font(.system(size: 11, weight: .semibold))
        }
        .padding(26)
        .frame(width: 600, height: 400)
        .background(
            ZStack {
                Color.black
                RadialGradient(colors: [c1.opacity(0.42), .clear], center: .topTrailing, startRadius: 10, endRadius: 440)
                RadialGradient(colors: [c2.opacity(0.26), .clear], center: .bottomLeading, startRadius: 10, endRadius: 380)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .onAppear {
            guard countUp else { return }
            if Motion.reduced { shown = Double(w.total) } else { withAnimation(.easeOut(duration: 1.3)) { shown = Double(w.total) } }
        }
    }
}

struct WrappedView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button { store.closeWrapped() } label: {
                    Label("back", systemImage: "chevron.left").foregroundStyle(X.text)
                }
                .buttonStyle(PressStyle())
                Spacer()
                Text("esc to go back").foregroundStyle(X.muted)
            }
            .font(.system(size: 13, weight: .semibold))
            if let w = store.wrapped {
                let card = WrapCard(w, seed: store.cardSeed)
                WrappedCard(w: w, card: card)
                    .shadow(color: card.colors[0].opacity(0.3), radius: 30)
                    .id(store.cardSeed)
                    .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity), removal: .opacity))
            }
            HStack(spacing: 10) {
                SecondaryButton(title: "🎲 shuffle  ⌘R") { store.reroll() }
                SecondaryButton(title: "copy image") { store.copyWrapped() }
                SecondaryButton(title: "save to downloads") { store.saveWrapped() }
                PrimaryButton(title: store.sharing ? "opening x…" : "share on x") { store.shareWrapped() }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(X.bg)
    }
}

// MARK: - Home dashboard

/// What the panel opens on: your stats for the tab and the search index,
/// instead of a wall of posts. Typing, a topic, or "browse" shows posts.
struct HomeView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if store.syncing || store.stats?.total == 0 {
                SetupCard()
            } else {
                StatsCard()
            }
            VStack(spacing: 14) {
                IndexCard()
                QuickActions()
            }
            .frame(width: 320)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .transition(.opacity)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(X.raised))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(X.line))
    }
}

/// While the first sync fills an empty library (or after one stopped):
/// what's happening, live, and what to do about it.
struct SetupCard: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let p = store.progress
        VStack(alignment: .leading, spacing: 0) {
            Label(store.syncing ? "setting up" : "almost there", systemImage: store.syncing ? "arrow.triangle.2.circlepath" : "pause.circle")
                .font(.system(size: 12.5, weight: .bold)).foregroundStyle(X.blue)
            Text(title(p)).font(.system(size: 26, weight: .heavy)).foregroundStyle(X.text).padding(.top, 10)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail(p)).font(.system(size: 14)).foregroundStyle(X.muted).padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)

            if store.syncing {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    CountUp(value: Double(store.foundThisSync))
                        .font(.system(size: 54, weight: .black, design: .rounded)).foregroundStyle(X.text)
                    Text("saves found").font(.system(size: 16, weight: .bold)).foregroundStyle(X.muted)
                }
                .padding(.top, 14)
                .animation(Motion.spring(0.5, 0.9), value: store.foundThisSync)
                HStack(spacing: -8) {
                    ForEach(Array((p?.avatars ?? []).suffix(10)), id: \.self) { a in
                        Avatar(url: biggerAvatar(a), size: 30)
                            .overlay(Circle().strokeBorder(X.raised, lineWidth: 2))
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(height: 32)
                .animation(Motion.spring(), value: p?.avatars ?? [])
                ProgressView().progressViewStyle(.linear).tint(X.blue).padding(.top, 14)
            }

            Spacer(minLength: 12)
            if store.syncing {
                note(p?.phase == "login" ? "🪟" : "💤",
                     p?.phase == "login"
                        ? "log in to x in the chrome window. it closes by itself once you're in."
                        : "this runs in the background. close this panel anytime, it keeps going.")
            } else {
                Button { store.onSync() } label: {
                    Label("continue syncing", systemImage: "arrow.clockwise")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(Capsule().fill(X.blue))
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18).fill(X.raised))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(X.line))
    }

    func note(_ emoji: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(emoji)
            Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(X.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(X.bg.opacity(0.7)))
    }

    func title(_ p: SyncProgress?) -> String {
        guard store.syncing else {
            return store.stats?.last_sync?.state == nil ? "let's fill your someday pile" : "your first sync stopped"
        }
        switch p?.phase {
        case "login": return "log in to x 👀"
        case "bookmark": return "stashing your bookmarks…"
        case "like": return "stashing your likes…"
        case "articles": return "reading your x articles…"
        case "fetch", "write", "index": return "making it all searchable 🧠"
        default: return "starting up…"
        }
    }

    func detail(_ p: SyncProgress?) -> String {
        guard store.syncing else {
            return (store.stats?.last_sync?.message).map { "\($0)" }
                ?? "somedayx reads your bookmarks and likes once, then keeps them fresh every night."
        }
        if p?.paused == true { return "x asked us to slow down. back in a minute ☕️" }
        switch p?.phase {
        case "bookmark", "like": return "the first sync goes through your whole history. big collections take a while."
        case "articles": return "opening your saved x articles to read them in full."
        case "fetch": return "grabbing link titles and images."
        case "write": return "gemma is writing tl;drs."
        case "index": return "gemma is reading your posts and images so you can search by meaning."
        default: return "a chrome window may open for you to log in to x."
        }
    }
}

/// Your someday pile with some personality: a persona, a big number, a roast
/// that changes every few seconds, your saving eras, and a one-click share.
struct StatsCard: View {
    @EnvironmentObject var store: Store

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let w = store.homeStats {
                content(w)
            } else {
                SkeletonRows(count: 4).padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            ZStack {
                X.raised
                // A soft X-blue glow, like the Wrapped card.
                RadialGradient(colors: [X.blue.opacity(0.22), .clear], center: .topTrailing, startRadius: 5, endRadius: 380)
                RadialGradient(colors: [X.pink.opacity(0.10), .clear], center: .bottomLeading, startRadius: 5, endRadius: 300)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(X.line))
    }

    func content(_ w: Wrapped) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(w.persona)
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(X.blue)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Capsule().fill(X.blue.opacity(0.14)))

            Text("you've hoarded").font(.system(size: 15, weight: .semibold)).foregroundStyle(X.muted).padding(.top, 14)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CountUp(value: Double(w.total))
                    .font(.system(size: 58, weight: .black, design: .rounded))
                    .foregroundStyle(X.text)
                    .animation(Motion.spring(0.7, 0.9), value: w.total)
                Text(w.source == nil ? "posts" : w.noun).font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(X.text.opacity(0.8))
            }
            Text([w.firstYear.map { "since \($0)" }, w.pace].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 13, weight: .medium)).foregroundStyle(X.muted)

            FactTicker(facts: w.facts).padding(.top, 16)

            Eras(byYear: w.by_year).padding(.top, 16)

            Spacer(minLength: 12)
            HStack(spacing: 12) {
                Button { store.shareWrapped() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: store.sharing ? "hourglass" : "square.and.arrow.up")
                        Text(store.sharing ? "opening x…" : "share my wrapped")
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(X.blue))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .disabled(store.sharing)
                Text("opens x with the image attached.\nyou just hit post.").font(.system(size: 11)).foregroundStyle(X.muted)
                    .fixedSize()
                Spacer()
                Button { store.openWrapped() } label: {
                    Text("peek ⌘Y").font(.system(size: 12, weight: .semibold)).foregroundStyle(X.muted)
                }
                .buttonStyle(PressStyle())
                .help("See the card first")
            }
        }
        .padding(18)
    }
}

/// One fact at a time, rolling every few seconds; click for the next.
struct FactTicker: View {
    let facts: [String]
    @State private var index = 0

    var body: some View {
        if !facts.isEmpty {
            Button { next() } label: {
                HStack(alignment: .top, spacing: 10) {
                    Text("🫵").font(.system(size: 18))
                    Text(facts[index % facts.count])
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(X.text)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .id(index)
                        .transition(.push(from: .bottom))
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 14).fill(X.bg.opacity(0.7)))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .help("Another one")
            .task(id: facts) {
                index = Int.random(in: 0..<max(facts.count, 1))
                while !Task.isCancelled && !Motion.reduced {
                    try? await Task.sleep(for: .seconds(5))
                    next()
                }
            }
        }
    }

    func next() { withAnimation(Motion.spring(0.45, 0.9)) { index += 1 } }
}

/// Saves by year as little bars, with your biggest year called out.
struct Eras: View {
    let byYear: [String: Int]

    var body: some View {
        let years = byYear.sorted { $0.key < $1.key }
        let peak = max(years.map(\.value).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(years, id: \.key) { y, n in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(n == peak ? AnyShapeStyle(LinearGradient(colors: [X.blue, X.pink], startPoint: .bottom, endPoint: .top))
                                        : AnyShapeStyle(X.muted.opacity(0.28)))
                        .frame(height: max(4, CGFloat(n) / CGFloat(peak) * 40))
                        .help("\(y): \(n.formatted())")
                }
            }
            .frame(height: 40, alignment: .bottom)
            HStack {
                Text(years.first?.key ?? "")
                Spacer()
                if let top = years.max(by: { $0.value < $1.value }) {
                    Text("your era: \(top.key) 🔥").foregroundStyle(X.text)
                }
                Spacer()
                Text(years.last?.key ?? "")
            }
            .font(.system(size: 11, weight: .bold)).foregroundStyle(X.muted)
        }
    }
}

struct IndexCard: View {
    @EnvironmentObject var store: Store
    @State private var confirming = false

    var body: some View {
        Card {
            let b = store.brain
            HStack(spacing: 8) {
                Image(systemName: "brain").foregroundStyle(X.blue)
                Text("search brain").font(.system(size: 14, weight: .bold)).foregroundStyle(X.text)
                Spacer()
                Text(status(b)).font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(b?.busy == true ? X.blue : b?.embed.state == "ready" ? X.green : X.muted)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill((b?.busy == true ? X.blue : X.green).opacity(0.12)))
            }
            Text("EmbeddingGemma, on your mac").font(.system(size: 12)).foregroundStyle(X.muted).padding(.top, 2)

            if let b, b.busy, let line = b.activity {
                VStack(alignment: .leading, spacing: 6) {
                    Text(line).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(X.text)
                        .contentTransition(.numericText())
                    ProgressView(value: b.fraction).progressViewStyle(.linear).tint(X.blue)
                    Text([b.step, store.eta].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(X.muted)
                }
                .padding(.top, 12)
            } else if let c = b?.counts {
                VStack(alignment: .leading, spacing: 7) {
                    stat("text.alignleft", "posts", c.posts, c.posts_total)
                    stat("photo", "images", c.images, c.images_total)
                    stat("doc.richtext", "articles read", c.articles, nil)
                    if let d = c.indexedDate {
                        Label("last indexed \(RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date()))",
                              systemImage: "clock")
                    }
                }
                .font(.system(size: 12.5)).foregroundStyle(X.muted)
                .padding(.top, 12)
            }

            if b?.busy != true && b?.embed.state == "ready" {
                Group {
                    if confirming {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("rebuild every post and image? about 30 min. search keeps working meanwhile.")
                                .font(.system(size: 12)).foregroundStyle(X.text).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                SecondaryButton(title: "rebuild") { confirming = false; store.reindex() }
                                Button("cancel") { confirming = false }.buttonStyle(.plain).foregroundStyle(X.muted)
                            }
                        }
                    } else {
                        Button { withAnimation(Motion.spring()) { confirming = true } } label: {
                            Label("rebuild index", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(X.blue)
                        }
                        .buttonStyle(PressStyle())
                    }
                }
                .padding(.top, 12)
            }
        }
    }

    func status(_ b: Brain?) -> String {
        guard let b else { return "…" }
        if b.busy { return "working" }
        switch b.embed.state {
        case "ready": return "ready"
        case "error": return "stopped"
        default: return "not set up"
        }
    }

    func stat(_ icon: String, _ label: String, _ n: Int?, _ total: Int?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).frame(width: 16)
            Text(label)
            Spacer()
            Text(total.map { "\((n ?? 0).formatted()) / \($0.formatted())" } ?? (n ?? 0).formatted())
                .foregroundStyle(X.text).monospacedDigit()
        }
    }
}

struct QuickActions: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 8) {
            action("list.bullet", "browse recent \(store.scope.noun)", "↓") { store.browseRecent() }
            action("dice", "surprise me", "⌘R") { store.surprise() }
            action("arrow.clockwise", store.syncing ? "syncing with x…" : "sync now", nil) { store.onSync() }
                .disabled(store.syncing)
        }
    }

    func action(_ icon: String, _ title: String, _ key: String?, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(X.blue).frame(width: 18)
                Text(title).foregroundStyle(X.text)
                Spacer()
                if let key {
                    Text(key).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(X.muted)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(X.field))
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(X.raised))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(X.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }
}

// MARK: - Panel content

struct SomedayXView: View {
    @EnvironmentObject var store: Store
    @Namespace private var ns

    var body: some View {
        ZStack {
            if store.step != nil {
                Onboarding().transition(.opacity)
            } else if store.showWrapped {
                WrappedView().transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                main.transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if let t = store.toast {
                Text(t)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(X.bg)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Capsule().fill(X.text))
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                    .padding(.bottom, 48)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay { Confetti(trigger: store.confetti) }
        .background(X.bg)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .scaleEffect(store.appeared ? 1 : 0.97)
        .opacity(store.appeared ? 1 : 0)
        .ignoresSafeArea()  // the hidden title bar shouldn't push content down
    }

    var main: some View {
        VStack(spacing: 0) {
            SearchBar().padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
            FilterChips()
            if store.query.isEmpty && store.phase == .ready && store.home != nil {
                TopicChips().transition(.opacity)
            }
            Divider().overlay(X.line)
            if store.loggedOut { LoginBanner() }
            if !store.onHome { BrainBanner() }  // home has its own index card
            content
            Divider().overlay(X.line)
            Footer()
        }
        .animation(Motion.ease(), value: store.query.isEmpty)
        .animation(Motion.spring(), value: store.onHome)
        .animation(Motion.spring(), value: store.loggedOut)
        .animation(Motion.spring(), value: store.brain?.busy)
    }

    @ViewBuilder var content: some View {
        switch store.phase {
        case .starting:
            HStack(spacing: 0) {
                VStack { SkeletonRows(); Spacer() }.frame(width: 380)
                Divider().overlay(X.line)
                EmptyState(emoji: "☕️", title: "warming up…", subtitle: "search is starting. a few seconds, tops.")
            }
        case .failed(let msg):
            EmptyState(emoji: "😵‍💫", title: "search tripped over itself", subtitle: msg)
        case .ready:
            if store.onHome {
                HomeView()
            } else if store.results.isEmpty && store.loading {
                HStack(spacing: 0) {
                    VStack { SkeletonRows(); Spacer() }.frame(width: 380)
                    Divider().overlay(X.line)
                    Spacer()
                }
            } else if store.results.isEmpty {
                if store.query.isEmpty {
                    EmptyState(emoji: "🫙", title: "your someday pile is empty",
                               subtitle: "go bookmark something good on x, then hit sync below.")
                } else {
                    EmptyState(emoji: "👀", title: "nothing for “\(store.query)”",
                               subtitle: "maybe you liked it on your other account. or try fewer words, from:handle, has:video or year:2024.")
                }
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 380)
                    Divider().overlay(X.line)
                    ZStack {
                        if let p = store.selected { Preview(post: p).id(p.id).transition(.opacity) }
                    }
                    .frame(maxWidth: .infinity)
                    .animation(Motion.ease(0.12), value: store.selected?.id)
                }
            }
        }
    }

    var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.results) { post in
                        Row(post: post, selected: post.id == store.selected?.id, label: store.labels[post.id],
                            terms: store.terms, ns: ns)
                            .id(post.id)
                            .onTapGesture(count: 2) { store.selectedID = post.id; store.openSelected() }
                            .onTapGesture { withAnimation(Motion.spring(0.22, 0.9)) { store.selectedID = post.id } }
                            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
                        Divider().overlay(X.line)
                    }
                }
            }
            .onChange(of: store.selectedID) { _, id in
                if let id { proxy.scrollTo(id, anchor: nil) }
            }
        }
    }
}

// MARK: - Panel

final class SomedayXPanel: NSPanel {
    init(root: some View) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                   styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        // Like Spotlight: take keyboard focus over whatever app is in front
        // without switching to SomedayX (macOS no longer lets apps steal activation).
        becomesKeyOnlyIfNeeded = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        let host = NSHostingView(rootView: root.frame(width: 900, height: 600).ignoresSafeArea())
        host.sizingOptions = []  // the panel has a fixed size; never grow to fit a long list
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Top-centre of the screen with the mouse, like Spotlight.
    func placeOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return center() }
        setFrameOrigin(NSPoint(x: vf.midX - frame.width / 2, y: vf.maxY - frame.height - vf.height * 0.12))
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let store = Store()
    lazy var panel = SomedayXPanel(root: SomedayXView().environmentObject(store))
    let menu = NSMenu()
    let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let syncItem = NSMenuItem(title: "Sync Now", action: #selector(syncNow), keyEquivalent: "")
    let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
    let notifyItem = NSMenuItem(title: "Turn On Notifications…", action: #selector(turnOnNotifications), keyEquivalent: "")
    let optionTapItem = NSMenuItem(title: "Turn On Double-Tap ⌥…", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    let writerItem = NSMenuItem(title: "Write tl;drs with Gemma", action: #selector(toggleWriter), keyEquivalent: "")
    var server: Process?
    var serverRestarts: [Date] = []
    var quitting = false
    var sync: Process?
    var hotKey: EventHotKeyRef?
    var scheduleTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        installEditMenu()
        wireStore()

        // macOS remembers a hidden icon (Visible = 0) and keeps hiding it;
        // always show it on launch.
        statusItem.autosaveName = "somedayx"
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: "SomedayX")
            button.image?.isTemplate = true
            button.toolTip = "SomedayX: search your X saves (⌥⌥ or ⌥⌘X)"
            button.action = #selector(statusClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        buildMenu()
        // A snapshot run only draws: no shortcuts, no keys, nothing that
        // could act on what you type in other apps.
        if let out = ProcessInfo.processInfo.environment["SOMEDAYX_SNAPSHOT"] {
            return snapshot(to: out)
        }
        registerHotKey()
        installDoubleOption()
        installKeyHandling()
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.hidePanel() }
        }
        setUpNotifications()
        setUpSchedule()
        startServer()
        if store.step != nil {  // first run: say hello
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.showPanel() }
        }
    }

    func wireStore() {
        store.onSync = { [weak self] in self?.runSync(scheduled: false) }
        store.onWantsPanel = { [weak self] in self?.showPanel() }
        store.onShare = { [weak self] image, text in self?.runShare(image: image, text: text) }
        store.onBrainDone = { [weak self] in
            guard let self, !self.panel.isVisible else { return }
            self.notify("Gemma's all caught up 🧠", "Search now understands your posts and the images in them. Double-tap ⌥ to try it.")
        }
        // After logging in to X in Chrome, bring the onboarding back.
        store.onLoggedIn = { [weak self] in
            guard let self, self.store.step != nil else { return }
            self.showPanel()
        }
        store.onMilestone = { [weak self] text in
            guard let self, !self.panel.isVisible else { return }
            self.notify(text, "Double-tap ⌥ to dig through them.")
        }
        store.onAskNotifications = { [weak self] in self?.askNotifications() }
        store.onAskAccessibility = { [weak self] in self?.openAccessibilitySettings() }
        store.onFinishOnboarding = { openAtLogin in
            do {
                if openAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                appLog("login item: \(error.localizedDescription)")
            }
        }
    }

    /// Debug aid: render the panel off-screen to a PNG and quit.
    /// SOMEDAYX_SNAPSHOT=out.png [SOMEDAYX_QUERY=…] [SOMEDAYX_DARK=1] SomedayX
    func snapshot(to path: String) {
        let env = ProcessInfo.processInfo.environment
        statusItem.isVisible = false
        NSApp.appearance = NSAppearance(named: env["SOMEDAYX_DARK"] == nil ? .aqua : .darkAqua)
        panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        panel.orderFront(nil)
        isServerUp { up in
            guard up else { NSApp.terminate(nil); return }
            self.store.serverReady()
            self.store.appeared = true
            self.store.query = env["SOMEDAYX_QUERY"] ?? ""
            switch env["SOMEDAYX_VIEW"] ?? "" {
            case "card":  // just the shareable image, exactly as it's posted
                self.store.step = nil
                if let seed = env["SOMEDAYX_SEED"].flatMap(UInt64.init) { self.store.cardSeed = seed }
                Task {
                    await self.store.exportCard(to: path)
                    NSApp.terminate(nil)
                }
                return
            case "wrapped":
                self.store.step = nil
                if let seed = env["SOMEDAYX_SEED"].flatMap(UInt64.init) { self.store.cardSeed = seed }
                self.store.openWrapped()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {  // the caption that would be posted
                    if let w = self.store.wrapped {
                        try? WrapCard(w, seed: self.store.cardSeed).caption.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
                    }
                }
            case let v where v.hasPrefix("onboarding"):
                self.store.step = Store.Step(rawValue: Int(v.dropFirst("onboarding".count)) ?? 0) ?? .welcome
            default: self.store.step = nil
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                let view = self.panel.contentView!
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        quitting = true
        server?.terminate()
    }

    // Without a main menu, ⌘C / ⌘V / ⌘A would not work in the search field.
    func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: Panel

    @objc func statusClicked() {
        let event = NSApp.currentEvent
        appLog("menu bar icon clicked (\(event?.type == .rightMouseUp ? "right" : "left"))")
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePanel()
        }
    }

    func togglePanel() { panel.isVisible ? hidePanel() : showPanel() }

    // Opening SomedayX again (Spotlight, Finder, `open -a SomedayX`) shows the panel,
    // so it is reachable even when the menu bar icon is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        appLog("reopened")
        showPanel()
        return false
    }

    @objc func showPanel() {
        if store.phase != .ready {
            // Recover from a slow or failed start: reuse a server that came up
            // late, or start one if none is running.
            isServerUp { up in
                appLog("panel opened while \(self.store.phase); server up: \(up)")
                if up { self.store.serverReady() } else if self.server?.isRunning != true { self.startServer() }
            }
        }
        panel.placeOnActiveScreen()
        store.trusted = AXIsProcessTrusted()
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            withAnimation(Motion.spring(0.28, 0.8)) { self.store.appeared = true }
        }
        appLog("panel shown (visible: \(panel.isVisible), key: \(panel.isKeyWindow), active: \(NSApp.isActive), frame: \(panel.frame))")
        store.panelOpened()
    }

    func hidePanel() {
        if panel.isVisible { appLog("panel hidden") }
        panel.orderOut(nil)
        store.appeared = false
    }

    func installKeyHandling() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isKeyWindow else { return e }
            let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = Int(e.keyCode)
            // Onboarding and Wrapped are full-panel screens with their own keys.
            if self.store.step != nil {
                switch (key, mods) {
                case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []): self.store.next()
                case (kVK_Escape, []): self.hidePanel()
                default: return e
                }
                return nil
            }
            if self.store.showWrapped {
                switch (key, mods) {
                case (kVK_Escape, []), (kVK_ANSI_Y, [.command]): self.store.closeWrapped()
                case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []): self.store.shareWrapped()
                case (kVK_ANSI_C, [.command]): self.store.copyWrapped()
                case (kVK_ANSI_R, [.command]), (kVK_Space, []): self.store.reroll()
                default: return e
                }
                return nil
            }
            switch (key, mods) {
            case (kVK_Escape, []):
                if !self.store.query.isEmpty || self.store.browsing { self.store.goHome() } else { self.hidePanel() }
            case (kVK_DownArrow, []) where self.store.onHome: self.store.browseRecent()
            case (kVK_DownArrow, []): self.store.move(1)
            case (kVK_UpArrow, []): self.store.move(-1)
            case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []): self.store.openSelected()
            case (kVK_ANSI_L, [.command]): self.store.openLink()
            case (kVK_ANSI_C, [.command, .shift]): self.store.copyLink()
            case (kVK_ANSI_1, [.command]): self.store.scope = .both
            case (kVK_ANSI_2, [.command]): self.store.scope = .bookmarks
            case (kVK_ANSI_3, [.command]): self.store.scope = .likes
            case (kVK_ANSI_R, [.command]): self.store.surprise()
            case (kVK_ANSI_Y, [.command]): self.store.openWrapped()
            default: return e
            }
            return nil
        }
    }

    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            let me = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            DispatchQueue.main.async { appLog("hotkey pressed"); me.togglePanel() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x5853_5243), id: 1)  // "XSRC"
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_X), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { appLog("couldn't register ⌥⌘X (error \(status)); another app may be using it") }
    }

    /// Double-tap ⌥ (alone, both taps quick) toggles the panel. Watching keys
    /// outside the app needs Accessibility; macOS asks the first time.
    var optionDownAt: TimeInterval = 0
    var lastOptionTapAt: TimeInterval = 0
    var optionMonitor: Any?
    var optionHandler: ((NSEvent) -> Void)?

    /// A global monitor added before permission was granted stays deaf, so
    /// re-add it once Accessibility is switched on; no relaunch needed.
    func waitForAccessibility() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, AXIsProcessTrusted(), let handle = self.optionHandler else { return }
                timer.invalidate()
                self.store.trusted = true
                if let m = self.optionMonitor { NSEvent.removeMonitor(m) }
                self.optionMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handle)
                appLog("double-tap ⌥ ready")
            }
        }
    }

    func installDoubleOption() {
        // No prompt here: onboarding (or the menu) asks, with a reason.
        let trusted = AXIsProcessTrusted()
        appLog("double-tap ⌥ \(trusted ? "ready" : "waiting for Accessibility permission")")
        let handle: (NSEvent) -> Void = { [weak self] e in
            MainActor.assumeIsolated { self?.handleOption(e) }
        }
        optionMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handle)
        optionHandler = handle
        if !trusted { waitForAccessibility() }
        NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { e in handle(e); return e }
    }

    func handleOption(_ e: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        guard e.type == .flagsChanged else { optionDownAt = 0; lastOptionTapAt = 0; return }
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control, .function])
        if mods == .option {
            optionDownAt = now
        } else if mods.isEmpty, optionDownAt > 0, now - optionDownAt < 0.3 {
            optionDownAt = 0
            let double = now - lastOptionTapAt < 0.4
            lastOptionTapAt = double ? 0 : now
            // Practising on the shortcut step lights the keys instead of closing the panel.
            if store.step == .shortcut && panel.isVisible {
                store.optionTapped(double: double)
            } else if double {
                appLog("double-tap ⌥")
                togglePanel()
            }
        } else {
            optionDownAt = 0; lastOptionTapAt = 0
        }
    }

    // MARK: Menu

    func buildMenu() {
        menu.delegate = self
        let open = NSMenuItem(title: "Search Your Saves", action: #selector(showPanel), keyEquivalent: "x")
        open.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(open)
        menu.addItem(NSMenuItem(title: "Your SomedayX Wrapped", action: #selector(showWrapped), keyEquivalent: ""))
        menu.addItem(.separator())
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(syncItem)
        menu.addItem(.separator())
        menu.addItem(writerItem)
        menu.addItem(loginItem)
        menu.addItem(notifyItem)
        menu.addItem(optionTapItem)
        menu.addItem(NSMenuItem(title: "Open in Browser", action: #selector(openInBrowser), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show Sync Log", action: #selector(showLog), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Welcome Tour…", action: #selector(showTour), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SomedayX", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        store.refreshStats()
        let running = sync?.isRunning == true
        syncItem.title = running ? "Syncing with X…" : "Sync Now"
        syncItem.isEnabled = !running
        statusLine.title = running ? "Sync in progress" : lastSyncSummary()
        if !running, let b = store.brain, b.busy, let line = b.activity {
            statusLine.title = "🧠 " + ([line] + [b.step, store.eta].compactMap { $0 }).joined(separator: " · ")
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        writerItem.state = store.brain?.writer_on == true ? .on : .off
        writerItem.isEnabled = store.brain != nil && store.brain?.writer.busy != true
        optionTapItem.isHidden = AXIsProcessTrusted()
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async {
                self.notifyItem.isHidden = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            }
        }
    }

    func lastSync() -> (json: [String: Any], date: Date?)? {
        let file = logDir.appendingPathComponent("last_sync.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json, DateFormatter.iso.date(from: json["at"] as? String ?? ""))
    }

    func lastSyncSummary() -> String {
        guard let (json, date) = lastSync() else { return "Not synced yet" }
        let when = date.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? ""
        switch json["state"] as? String {
        case "ok": return "Synced \(when): \(json["message"] as? String ?? "")"
        case "login": return "Log in to X needed. Choose Sync Now"
        case "running": return "Last sync didn't finish (\(when))"
        default: return "Last sync failed \(when). See log"
        }
    }

    /// X's composer in the logged-in browser, caption typed, image attached.
    func runShare(image: String, text: String) {
        let p = pythonProcess(["share", image, text], log: "share.log")
        p.terminationHandler = { proc in
            DispatchQueue.main.async { self.store.shareFinished(ok: proc.terminationStatus == 0) }
        }
        do {
            try p.run()
            // Step aside for the composer window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.hidePanel() }
        } catch {
            store.shareFinished(ok: false)
        }
    }

    @objc func toggleWriter() {
        guard let b = store.brain else { return }
        if b.writer_on {
            let alert = NSAlert()
            alert.messageText = "Turn off tl;drs?"
            alert.informativeText = "SomedayX deletes the Gemma 4 model to free \(String(format: "%.1f", Double(b.writer_size) / 1e9)) GB. The tl;drs you already have stay."
            alert.addButton(withTitle: "Turn Off")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            store.setWriter(false)
        } else {
            store.setWriter(true)
            showPanel()  // shows the download in the footer
        }
    }

    @objc func showWrapped() {
        store.step = nil
        showPanel()
        store.openWrapped()
    }

    @objc func showTour() {
        store.restartOnboarding()
        showPanel()
    }

    @objc func openInBrowser() { if let u = serverURL("/") { NSWorkspace.shared.open(u) } }
    @objc func showLog() { NSWorkspace.shared.open(logDir.appendingPathComponent("sync.log")) }

    // MARK: Python processes

    func pythonProcess(_ args: [String], log: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: uvPath)
        p.arguments = ["run", "python", "-m", "somedayx"] + args
        p.currentDirectoryURL = projectDir
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = toolPath
        env["PYTHONUNBUFFERED"] = "1"
        env["SOMEDAYX_HOME"] = dataDir.path
        p.environment = env
        let logURL = logDir.appendingPathComponent(log)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            p.standardOutput = handle
            p.standardError = handle
        }
        return p
    }

    func startServer() {
        store.phase = .starting
        isServerUp { up in
            if up {  // e.g. started from a terminal
                appLog("reusing running search server")
                return self.store.serverReady()
            }
            appLog("starting search server")
            let p = self.pythonProcess(["serve", String(port)], log: "server.log")
            p.terminationHandler = { [weak self] proc in
                DispatchQueue.main.async { self?.serverExited(proc) }
            }
            do { try p.run() } catch {
                self.store.phase = .failed("Couldn't start search: \(error.localizedDescription)")
                return
            }
            self.server = p
            self.waitForServer(attempts: 360)  // up to 3 min; the first start after an update is slow
        }
    }

    /// Search stopped on its own (a crash, or killed): start it again,
    /// unless it keeps happening.
    func serverExited(_ p: Process) {
        guard !quitting, server === p else { return }
        appLog("search server stopped (status \(p.terminationStatus)); restarting")
        serverRestarts = serverRestarts.filter { Date().timeIntervalSince($0) < 600 } + [Date()]
        server = nil
        guard serverRestarts.count <= 5 else {
            store.phase = .failed("Search keeps stopping. Right-click the icon → Show Sync Log, or see logs/server.log in the data folder.")
            return
        }
        store.phase = .starting
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.startServer() }
    }

    func waitForServer(attempts: Int) {
        isServerUp { up in
            if up {
                appLog("search server ready")
                return self.store.serverReady()
            }
            guard attempts > 0, self.server?.isRunning == true else {
                appLog("search server didn't start (running: \(self.server?.isRunning == true))")
                self.store.phase = .failed("Search didn't start. Right-click the icon → Show Sync Log, or see logs/server.log in the data folder.")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.waitForServer(attempts: attempts - 1) }
        }
    }

    func isServerUp(_ done: @escaping (Bool) -> Void) {
        var req = URLRequest(url: URL(string: "\(serverBase)/api/stats")!)
        req.setValue(accessToken, forHTTPHeaderField: "X-SomedayX-Token")
        req.timeoutInterval = 3
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async { done(ok) }
        }.resume()
    }

    // MARK: Sync

    @objc func syncNow() { runSync(scheduled: false) }

    /// Manual syncs show the browser so X can ask you to log in; scheduled
    /// ones run headless and report a needed login as a notification.
    func runSync(scheduled: Bool) {
        guard sync?.isRunning != true else { return }
        let p = pythonProcess(scheduled ? ["sync", "--headless"] : ["sync"], log: "sync.log")
        p.terminationHandler = { _ in
            DispatchQueue.main.async { self.syncFinished(scheduled: scheduled) }
        }
        do {
            try p.run()
            sync = p
            store.syncing = true
        } catch {
            notify("Couldn't sync", error.localizedDescription)
        }
    }

    func syncFinished(scheduled: Bool) {
        let json = lastSync()?.json ?? [:]
        let b = json["bookmark"] as? Int ?? 0, l = json["like"] as? Int ?? 0
        store.syncFinished(state: json["state"] as? String ?? "error", added: b + l, manual: !scheduled)
        // The panel shows its own toast; notifications are for when it's closed.
        if panel.isVisible && json["state"] as? String == "ok" { return }
        switch json["state"] as? String {
        case "ok":
            if b + l > 0 {
                let parts = [b > 0 ? "\(b) new bookmark\(b == 1 ? "" : "s")" : nil,
                             l > 0 ? "\(l) new like\(l == 1 ? "" : "s")" : nil].compactMap { $0 }
                notify("+\(b + l) new saves stashed 🔖", parts.joined(separator: " and ") + ". Double-tap ⌥ to search them.")
            } else if !scheduled {
                notify("All caught up", "Nothing new since your last sync. Go touch grass 🌱")
            }
        case "login":
            notify("X logged you out", "Syncing is paused. Open SomedayX and hit reconnect.")
        default:
            notify("Sync didn't finish", (json["message"] as? String) ?? "See the sync log for details.")
        }
    }

    // MARK: Nightly schedule

    func setUpSchedule() {
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in MainActor.assumeIsolated { self.checkSchedule() } }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self.checkSchedule() }  // let Wi-Fi reconnect
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { self.checkSchedule() }
    }

    func checkSchedule() {
        let cal = Calendar.current
        let now = Date()
        guard var due = cal.date(bySettingHour: nightlyHour, minute: 0, second: 0, of: now) else { return }
        if due > now { due = cal.date(byAdding: .day, value: -1, to: due)! }
        if (lastSync()?.date ?? .distantPast) < due { runSync(scheduled: true) }
    }

    // MARK: Notifications

    /// Permission is asked in context (onboarding's "ping me", or the menu),
    /// never as a surprise at launch.
    func setUpNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.getNotificationSettings { s in
            let on = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            DispatchQueue.main.async { self.store.notificationsOn = on }
        }
    }

    func askNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { appLog("notification authorization error: \(error.localizedDescription)") }
            DispatchQueue.main.async {
                self.store.notificationsOn = granted
                if granted { self.store.show(toast: "we'll ping you 🔔") } else { self.openNotificationSettings() }
            }
        }
    }

    func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        ) { error in
            if let error { appLog("notification failed: \(error.localizedDescription)") }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        DispatchQueue.main.async { self.showPanel() }
        done()
    }

    @objc func openAccessibilitySettings() {
        guard !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) else { return }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc func turnOnNotifications() { askNotifications() }

    @objc func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!)
    }

    // MARK: Login item

    @objc func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            notify("Couldn't change Open at Login", error.localizedDescription)
        }
    }
}

func appLog(_ message: String) {
    let url = logDir.appendingPathComponent("app.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate

    // Quit cleanly (stopping the search server) on SIGTERM too, e.g. at logout.
    signal(SIGTERM, SIG_IGN)
    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigterm.setEventHandler { NSApp.terminate(nil) }
    sigterm.resume()

    app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
    withExtendedLifetime((delegate, sigterm)) { app.run() }
}
