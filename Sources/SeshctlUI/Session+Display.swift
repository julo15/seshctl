import Foundation
import SeshctlCore

struct SessionAgeDisplay {
    let timestamp: Date
    let now: Date
    let calendar: Calendar
    let locale: Locale

    init(
        timestamp: Date,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) {
        self.timestamp = timestamp
        self.now = now
        self.calendar = calendar
        self.locale = locale
    }

    /// Human-readable timestamp string for the row's left-side time slot.
    /// Today is fully relative — quick triage doesn't require parsing a clock
    /// time — and older days fall back to absolute calendar formatting:
    ///
    /// - Less than 1 minute ago (past) → seconds (`"0s"`, `"30s"`).
    /// - Less than 1 hour ago (past) → minutes (`"1m"`, `"59m"`).
    /// - Same calendar day, ≥ 1 hour past (or future-today clock skew) → hours
    ///   (`"1h"`, `"23h"`); future-today is clamped to `"0s"`.
    /// - Different day, same calendar year → abbreviated month + day
    ///   (`"Apr 28"`).
    /// - Different year → abbreviated month + day + year (`"Apr 28, 2025"`).
    ///
    /// The cross-midnight edge case (timestamp is yesterday but `< 1h` ago)
    /// hits the seconds/minutes branch first, so a 45-minute-old timestamp
    /// from yesterday still reads `"45m"` rather than `"Apr 14"`.
    ///
    /// Locale-aware branches respect the configured `locale` and `calendar`,
    /// so tests can pin a deterministic locale (`en_US`) while production
    /// follows the user's system locale.
    var label: String {
        let secondsSince = now.timeIntervalSince(timestamp)
        if secondsSince >= 0 && secondsSince < 3600 {
            let elapsed = Int(secondsSince)
            if elapsed < 60 { return "\(elapsed)s" }
            return "\(elapsed / 60)m"
        }
        if calendar.isDate(timestamp, inSameDayAs: now) {
            if secondsSince < 0 { return "0s" }   // future-today clamp
            return "\(Int(secondsSince) / 3600)h"
        }
        let timestampYear = calendar.component(.year, from: timestamp)
        let nowYear = calendar.component(.year, from: now)
        if timestampYear == nowYear {
            return Self.monthDayFormatter(locale: locale, calendar: calendar)
                .string(from: timestamp)
        }
        return Self.fullDateFormatter(locale: locale, calendar: calendar)
            .string(from: timestamp)
    }

    /// `DateFormatter` initialization is non-trivial (locale parsing, ICU
    /// work). The label render path runs once per row per popover refresh,
    /// so a fresh formatter per call is wasteful. Cache by
    /// (kind, locale, timezone) — production hits the same key on every
    /// render, and tests' deterministic locales fold to a small set too.
    private static let formatterCache = FormatterCache()

    private static func monthDayFormatter(locale: Locale, calendar: Calendar) -> DateFormatter {
        formatterCache.formatter(
            kind: "monthDay",
            locale: locale,
            timeZone: calendar.timeZone
        ) {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
            return formatter
        }
    }

    private static func fullDateFormatter(locale: Locale, calendar: Calendar) -> DateFormatter {
        formatterCache.formatter(
            kind: "fullDate",
            locale: locale,
            timeZone: calendar.timeZone
        ) {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("MMM d yyyy")
            return formatter
        }
    }

    /// Thread-safe `(kind, locale, timezone)` → `DateFormatter` cache. Lock-
    /// guarded because `SessionAgeDisplay.label` may be evaluated off the main
    /// actor (e.g., from `bucket`-like helpers in non-view code paths).
    /// Returned `DateFormatter` instances are read-only at the call site
    /// (`.string(from:)`), so sharing is safe.
    private final class FormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private var formatters: [String: DateFormatter] = [:]

        func formatter(
            kind: String,
            locale: Locale,
            timeZone: TimeZone,
            build: () -> DateFormatter
        ) -> DateFormatter {
            let key = "\(kind)|\(locale.identifier)|\(timeZone.identifier)"
            lock.lock()
            defer { lock.unlock() }
            if let cached = formatters[key] { return cached }
            let formatter = build()
            formatters[key] = formatter
            return formatter
        }
    }

    enum AgeBucket {
        case today, yesterday, older
        var displayName: String {
            switch self {
            case .today: return "Today"
            case .yesterday: return "Yesterday"
            case .older: return "Older"
            }
        }
    }

    /// Calendar-day bucket — used to insert recency section headers in lists.
    var bucket: AgeBucket {
        if calendar.isDate(timestamp, inSameDayAs: now) { return .today }
        if calendar.isDateInYesterday(timestamp) { return .yesterday }
        return .older
    }
}

extension Session {
    var primaryName: String {
        gitRepoName ?? (directory as NSString).lastPathComponent
    }
}

// MARK: - Sender / preview / status-hint / accessibility helpers
//
// These are the centralized display computations used by the row UI redesign
// (Phase 1 of the Gmail-style row layout). View layers should treat the
// returned values as already-decided structure and concern themselves only
// with rendering — see plan `2026-04-29-1730-row-ui-gmail-redesign.md`.

/// Priority-chain content for the row's line-1 preview slot. The view layer
/// maps each case to its own typography (regular for `.reply`, italic for
/// `.userPrompt` and `.statusHint`).
enum PreviewContent: Equatable {
    /// Latest assistant message — rendered with no `Claude:`/`Codex:`/`Gemini:`
    /// prefix; that prefix lived only in the previous layout.
    case reply(String)
    /// User's last prompt; rendered as italic `You: <text>` by the view layer.
    case userPrompt(String)
    /// Fallback when neither reply nor prompt is available — derived from
    /// `Session.statusHint(for:)`.
    case statusHint(String)
    /// Claude Code "recap" string (`away_summary`) — a real piece of authored
    /// content describing what the session did while the user was away. The
    /// view layer renders this with the same typography as `.reply` (regular
    /// weight, primary color, `.title3`, bold on unread); it is NOT a UI
    /// fallback hint and should not be styled like `.statusHint`.
    case awaySummary(String)
}

/// Returns the trimmed content of `self` if it has any non-whitespace
/// content; otherwise returns nil. Used to fold "nil", "" and whitespace-only
/// strings into a single notion of "empty" for the preview-priority chain.
extension Optional where Wrapped == String {
    fileprivate var nonEmpty: String? {
        guard let value = self else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : value
    }
}

extension Session {
    /// Repo name for the row's line-1 sender slot, falling back to the
    /// directory basename when the session has no git context. Worktrees of
    /// the same repo collapse to identical sender values on line 1; the
    /// line-2 branch slot disambiguates them, so duplicating the worktree
    /// directory here only crowds the column and forces truncation on long
    /// worktree names. Two worktrees on the *same* branch (rare: detached
    /// HEAD, or both forced to `main`) read identically by design — line 2
    /// is the disambiguator, and there's no third line to fall back to.
    var senderDisplay: String {
        if let repoName = gitRepoName {
            return repoName
        }
        return (directory as NSString).lastPathComponent
    }

    /// Priority-chain preview content for the row's line-1 preview slot.
    ///
    /// Order: `lastReply` (assistant message) → `lastAsk` (user prompt) →
    /// status hint. `nil`, empty strings, and whitespace-only strings are all
    /// treated as "absent" and fall through to the next priority.
    ///
    /// Returns the multi-line body with leading/trailing whitespace trimmed;
    /// internal newlines are preserved so the view layer can render multiple
    /// wrapped lines.
    var previewContent: PreviewContent {
        if let reply = lastReply.nonEmpty, let body = Self.trimmedPreviewBody(of: reply) {
            return .reply(body)
        }
        if let ask = lastAsk.nonEmpty, let body = Self.trimmedPreviewBody(of: ask) {
            return .userPrompt(body)
        }
        return .statusHint(Self.statusHint(for: status))
    }

    /// Priority-chain preview content with an optional Claude Code recap
    /// (`away_summary`) injected at the top of the chain. When a non-empty
    /// recap is supplied, returns `.awaySummary` regardless of `lastReply` /
    /// `lastAsk` — the recap is what the user wants to see at a glance ("where
    /// is this session" trumps "what's the last assistant token"). Nil, empty,
    /// or whitespace-only summaries fall through to the existing chain
    /// (`previewContent`) unchanged.
    ///
    /// Multi-line summaries preserve internal newlines and trim only the
    /// leading/trailing whitespace, matching the existing chain's
    /// `trimmedPreviewBody` behavior.
    func previewContent(awaySummary: String?) -> PreviewContent {
        if let summary = awaySummary.nonEmpty, let body = Self.trimmedPreviewBody(of: summary) {
            return .awaySummary(body)
        }
        return previewContent
    }

    /// Status-hint copy used as the preview-chain fallback. Every
    /// `SessionStatus` case maps to one short string.
    static func statusHint(for status: SessionStatus) -> String {
        switch status {
        case .working:   return "Working\u{2026}"
        case .waiting:   return "Waiting\u{2026}"
        case .idle:      return "Idle"
        case .completed: return "Done"
        case .canceled:  return "Canceled"
        case .stale:     return "Ended"
        }
    }

    /// Composes a unified VoiceOver label for the row's host-icon-with-badge
    /// element.
    ///
    /// Contract:
    /// - Pass `nil` for `hostApp` for **remote** rows (the host part becomes
    ///   `"Globe"` to match the rendered globe SF Symbol).
    /// - Pass a `HostAppInfo` (or `.unknown`) for **local** rows — the
    ///   `name` field is read directly.
    ///
    /// Output shape: `"<host>, <agent>"` — e.g. `"Ghostty, Claude"`,
    /// `"Globe, Codex"`.
    static func accessibilityLabel(hostApp: HostAppInfo?, agent: SessionTool) -> String {
        let hostPart = hostApp?.name ?? "Globe"
        let agentPart: String = {
            switch agent {
            case .claude: return "Claude"
            case .codex:  return "Codex"
            case .gemini: return "Gemini"
            case .cursor: return "Cursor"
            }
        }()
        return "\(hostPart), \(agentPart)"
    }

    /// Returns the body of `text` with leading and trailing whitespace
    /// (including newlines) stripped, preserving internal newlines so a
    /// multi-line reply renders across multiple lines in the row preview.
    /// Returns nil when the trimmed result is empty.
    private static func trimmedPreviewBody(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
