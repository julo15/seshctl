import Foundation
import Testing

@testable import SeshctlUI


@Suite("SessionAgeDisplay")
struct SessionAgeDisplayTests {
    /// UTC Gregorian calendar — keeps day boundaries deterministic regardless of host TZ/DST.
    private static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// `Calendar.isDateInYesterday` is implemented against the wall clock, not against
    /// our synthetic `now`. To keep `.yesterday` cases hermetic-ish, anchor `now` to the
    /// real "today" in UTC so Foundation agrees on what "yesterday" is. Offsets within a
    /// case are still fully deterministic.
    private static func todayNoonUTC() -> Date {
        let cal = utcCalendar
        let startOfToday = cal.startOfDay(for: Date())
        return cal.date(byAdding: .hour, value: 12, to: startOfToday)!
    }

    // MARK: - bucket

    @Test("Same calendar day (morning of now) → .today")
    func bucketSameDayMorning() {
        let cal = Self.utcCalendar
        let now = Self.todayNoonUTC()
        let morning = cal.date(byAdding: .hour, value: -6, to: now)!
        let display = SessionAgeDisplay(timestamp: morning, now: now, calendar: cal)
        #expect(display.bucket == .today)
    }

    @Test("Same calendar day (one second before now) → .today")
    func bucketSameDayJustBefore() {
        let cal = Self.utcCalendar
        let now = Self.todayNoonUTC()
        let justBefore = now.addingTimeInterval(-1)
        let display = SessionAgeDisplay(timestamp: justBefore, now: now, calendar: cal)
        #expect(display.bucket == .today)
    }

    @Test("Late last night (23:59 the day before now) → .yesterday")
    func bucketLateLastNight() {
        let cal = Self.utcCalendar
        let now = Self.todayNoonUTC()
        let startOfToday = cal.startOfDay(for: now)
        let lateLastNight = cal.date(byAdding: .minute, value: -1, to: startOfToday)!
        let display = SessionAgeDisplay(timestamp: lateLastNight, now: now, calendar: cal)
        #expect(display.bucket == .yesterday)
    }

    @Test("Early yesterday morning (00:01 the day before now) → .yesterday")
    func bucketEarlyYesterdayMorning() {
        let cal = Self.utcCalendar
        let now = Self.todayNoonUTC()
        let startOfToday = cal.startOfDay(for: now)
        let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday)!
        let earlyYesterday = cal.date(byAdding: .minute, value: 1, to: startOfYesterday)!
        let display = SessionAgeDisplay(timestamp: earlyYesterday, now: now, calendar: cal)
        #expect(display.bucket == .yesterday)
    }

    @Test("Two days ago (midnight) → .older")
    func bucketTwoDaysAgo() {
        let cal = Self.utcCalendar
        let now = Self.todayNoonUTC()
        let startOfToday = cal.startOfDay(for: now)
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: startOfToday)!
        let display = SessionAgeDisplay(timestamp: twoDaysAgo, now: now, calendar: cal)
        #expect(display.bucket == .older)
    }

    @Test("Thirty days ago → .older")
    func bucketThirtyDaysAgo() {
        let cal = Self.utcCalendar
        let now = Self.todayNoonUTC()
        let thirtyDaysAgo = cal.date(byAdding: .day, value: -30, to: now)!
        let display = SessionAgeDisplay(timestamp: thirtyDaysAgo, now: now, calendar: cal)
        #expect(display.bucket == .older)
    }

    @Test("Future timestamp same calendar day (1 hour after now) → .today")
    func bucketFutureSameDay() {
        let cal = Self.utcCalendar
        let now = Self.todayNoonUTC()
        let futureSameDay = cal.date(byAdding: .hour, value: 1, to: now)!
        let display = SessionAgeDisplay(timestamp: futureSameDay, now: now, calendar: cal)
        #expect(display.bucket == .today)
    }

    /// Edge case: future timestamps on a *different* calendar day fall through to `.older`
    /// because `bucket` only recognizes today/yesterday/older — there is no `.tomorrow`.
    /// This is the documented current behavior; locked in here so a future change is intentional.
    @Test("Future timestamp on next calendar day → .older (no .tomorrow bucket)")
    func bucketFutureNextDay() {
        let cal = Self.utcCalendar
        let now = Self.todayNoonUTC()
        let nextDay = cal.date(byAdding: .day, value: 1, to: now)!
        let display = SessionAgeDisplay(timestamp: nextDay, now: now, calendar: cal)
        #expect(display.bucket == .older)
    }

    // MARK: - label (relative-today, absolute-older)
    //
    // Same calendar day → relative (`"30s"`, `"5m"`, `"12h"`); future-today
    // clamps to `"0s"`.
    // Different day, same calendar year → abbreviated month + day (`"Apr 14"`).
    // Different year → abbreviated month + day + year (`"Dec 1, 2025"`).
    //
    // Locale is pinned to `en_US` in tests so the format strings are stable
    // across machines / CI; production uses `.current`.

    private static let testLocale = Locale(identifier: "en_US")

    private static func displayAt(
        year: Int, month: Int, day: Int,
        hour: Int = 12, minute: Int = 0, second: Int = 0,
        nowYear: Int = 2026, nowMonth: Int = 4, nowDay: Int = 15,
        nowHour: Int = 12, nowMinute: Int = 0,
        yesterdayStyle: SessionAgeDisplay.YesterdayStyle = .date
    ) -> SessionAgeDisplay {
        let cal = Self.utcCalendar
        let timestamp = cal.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        ))!
        let now = cal.date(from: DateComponents(
            year: nowYear, month: nowMonth, day: nowDay,
            hour: nowHour, minute: nowMinute
        ))!
        return SessionAgeDisplay(
            timestamp: timestamp,
            now: now,
            calendar: cal,
            locale: testLocale,
            yesterdayStyle: yesterdayStyle
        )
    }

    // MARK: relative branch (past, < 1h ago)

    @Test("Equal timestamp → \"0s\" (relative branch)")
    func labelSameInstant() {
        let display = Self.displayAt(year: 2026, month: 4, day: 15, hour: 12)
        #expect(display.label == "0s")
    }

    @Test("30 seconds ago → \"30s\"")
    func label30SecondsAgo() {
        let display = Self.displayAt(
            year: 2026, month: 4, day: 15, hour: 11, minute: 59, second: 30
        )
        #expect(display.label == "30s")
    }

    @Test("59 minutes ago → \"59m\"")
    func label59MinutesAgo() {
        let display = Self.displayAt(
            year: 2026, month: 4, day: 15, hour: 11, minute: 1
        )
        #expect(display.label == "59m")
    }

    @Test("Exactly 1 hour ago → \"1h\"")
    func labelOneHourAgo() {
        let display = Self.displayAt(year: 2026, month: 4, day: 15, hour: 11)
        #expect(display.label == "1h")
    }

    @Test("1 hour 5 minutes ago → \"1h\" (hours integer-divide)")
    func label1HourFiveMinutesAgo() {
        let display = Self.displayAt(
            year: 2026, month: 4, day: 15, hour: 10, minute: 55
        )
        #expect(display.label == "1h")
    }

    @Test("12 hours ago (same calendar day) → \"12h\"")
    func label12HoursAgo() {
        let display = Self.displayAt(
            year: 2026, month: 4, day: 15, hour: 0, minute: 0,
            nowHour: 12, nowMinute: 0
        )
        #expect(display.label == "12h")
    }

    @Test("Early today from late now (00:30 vs 23:30 same day) → \"23h\"")
    func label23HoursAgoSameDay() {
        let display = Self.displayAt(
            year: 2026, month: 4, day: 15, hour: 0, minute: 30,
            nowHour: 23, nowMinute: 30
        )
        #expect(display.label == "23h")
    }

    /// Cross-midnight under-1h: timestamp is yesterday by calendar but only
    /// 45 minutes elapsed. The first (`< 3600s`) branch must win — if the
    /// same-day check were ever moved before it, this would silently regress
    /// to `"Apr 14"`.
    @Test("45 minutes ago across midnight → \"45m\" (not \"Apr 14\")")
    func labelCrossMidnightUnderOneHour() {
        let display = Self.displayAt(
            year: 2026, month: 4, day: 14, hour: 23, minute: 30,
            nowYear: 2026, nowMonth: 4, nowDay: 15, nowHour: 0, nowMinute: 15
        )
        #expect(display.label == "45m")
    }

    // MARK: absolute branches
    //
    // macOS 13+ DateFormatter for en_US uses a narrow no-break space (U+202F)
    // between time and AM/PM marker. Test literals use \u{202F} to match the
    // formatter's natural output exactly.

    @Test("Same calendar day, 2h 49m ago → \"2h\"")
    func labelSameDayEarlier() {
        let display = Self.displayAt(year: 2026, month: 4, day: 15, hour: 9, minute: 11)
        #expect(display.label == "2h")
    }

    @Test("Same calendar day, future evening → \"0s\" (future-today clamp)")
    func labelSameDayEvening() {
        let display = Self.displayAt(year: 2026, month: 4, day: 15, hour: 23, minute: 30)
        #expect(display.label == "0s")
    }

    @Test("Yesterday → MMM d")
    func labelYesterday() {
        let display = Self.displayAt(year: 2026, month: 4, day: 14, hour: 18)
        #expect(display.label == "Apr 14")
    }

    @Test("Earlier in same year → MMM d")
    func labelEarlierThisYear() {
        let display = Self.displayAt(year: 2026, month: 1, day: 3)
        #expect(display.label == "Jan 3")
    }

    @Test("Different year → MMM d, yyyy")
    func labelDifferentYear() {
        let display = Self.displayAt(year: 2025, month: 12, day: 1)
        #expect(display.label == "Dec 1, 2025")
    }

    @Test("Future timestamp same calendar day → \"0s\" (future-today clamp)")
    func labelFutureSameDay() {
        let display = Self.displayAt(year: 2026, month: 4, day: 15, hour: 13, minute: 30)
        #expect(display.label == "0s")
    }

    @Test("Future timestamp next calendar day → MMM d")
    func labelFutureNextDay() {
        let display = Self.displayAt(year: 2026, month: 4, day: 16, hour: 9)
        #expect(display.label == "Apr 16")
    }

    // MARK: yesterdayStyle branches
    //
    // The yesterday-bucket branch picks between three renderings driven by the
    // calling view: `.date` (legacy `"Apr 14"`), `.timeOfDay` (locale-formatted
    // clock time), and `.relativeDay` (`"1d"` shorthand). Today and older days
    // are not affected by the flag — locked in below.

    /// `Calendar.isDateInYesterday` resolves "yesterday" against the wall
    /// clock, not `now`. Use the same anchor as the `bucket` tests so the
    /// .yesterday branch fires deterministically.
    @Test(".timeOfDay yesterday → locale-formatted clock time")
    func labelYesterdayTimeOfDay() {
        let cal = Self.utcCalendar
        let now = Self.todayNoonUTC()
        let startOfToday = cal.startOfDay(for: now)
        let yesterdayEvening = cal.date(byAdding: .hour, value: -2, to: startOfToday)!
        let display = SessionAgeDisplay(
            timestamp: yesterdayEvening,
            now: now,
            calendar: cal,
            locale: Self.testLocale,
            yesterdayStyle: .timeOfDay
        )
        // en_US `jmm` template → `"10:00\u{202F}PM"` (narrow no-break space
        // between time and AM/PM marker on macOS 13+).
        #expect(display.label == "10:00\u{202F}PM")
    }

    @Test(".relativeDay yesterday → \"1d\"")
    func labelYesterdayRelativeDay() {
        let cal = Self.utcCalendar
        let now = Self.todayNoonUTC()
        let startOfToday = cal.startOfDay(for: now)
        let yesterdayEvening = cal.date(byAdding: .hour, value: -2, to: startOfToday)!
        let display = SessionAgeDisplay(
            timestamp: yesterdayEvening,
            now: now,
            calendar: cal,
            locale: Self.testLocale,
            yesterdayStyle: .relativeDay
        )
        #expect(display.label == "1d")
    }

    @Test(".timeOfDay does not affect 2-days-ago → MMM d")
    func labelTwoDaysAgoIgnoresTimeOfDay() {
        // `displayAt`'s pinned `now = 2026-04-15` means `2026-04-13` is two
        // days ago — `isDateInYesterday` returns false, the yesterday switch
        // is skipped, and the cascade falls through to the month-day branch.
        let display = Self.displayAt(
            year: 2026, month: 4, day: 13, hour: 18,
            yesterdayStyle: .timeOfDay
        )
        #expect(display.label == "Apr 13")
    }

    @Test(".relativeDay does not affect 2-days-ago → MMM d")
    func labelTwoDaysAgoIgnoresRelativeDay() {
        // Same anchor as the `.timeOfDay` twin above — 2-days-ago should NOT
        // collapse to "2d" because we explicitly opted out of multi-day
        // relative shorthand in the design.
        let display = Self.displayAt(
            year: 2026, month: 4, day: 13, hour: 18,
            yesterdayStyle: .relativeDay
        )
        #expect(display.label == "Apr 13")
    }

    /// Cross-midnight `< 1h` still wins over the yesterday-style branch, in
    /// both modes — locks in that the seconds/minutes formatter sits above
    /// the yesterday switch in the cascade.
    @Test(".timeOfDay yesterday < 1h ago → \"45m\" (seconds/minutes branch wins)")
    func labelCrossMidnightUnderOneHourTimeOfDay() {
        let display = Self.displayAt(
            year: 2026, month: 4, day: 14, hour: 23, minute: 30,
            nowYear: 2026, nowMonth: 4, nowDay: 15, nowHour: 0, nowMinute: 15,
            yesterdayStyle: .timeOfDay
        )
        #expect(display.label == "45m")
    }

    @Test(".relativeDay yesterday < 1h ago → \"45m\" (seconds/minutes branch wins)")
    func labelCrossMidnightUnderOneHourRelativeDay() {
        let display = Self.displayAt(
            year: 2026, month: 4, day: 14, hour: 23, minute: 30,
            nowYear: 2026, nowMonth: 4, nowDay: 15, nowHour: 0, nowMinute: 15,
            yesterdayStyle: .relativeDay
        )
        #expect(display.label == "45m")
    }

    /// Cross-midnight `≥ 1h, < 24h` in `.relativeDay` mode: the elapsed time
    /// is ~2 hours, but the day bucket says yesterday — by design, tree view
    /// shows the consistent day-bucket signal ("1d") rather than the elapsed
    /// hours, because the tree view has no time-based section headers and
    /// the user is grouping by repo, not recency. Locks in the trade-off.
    ///
    /// Anchored against the wall clock (not `displayAt`'s synthetic
    /// 2026-04-15 anchor) because `Calendar.isDateInYesterday` resolves
    /// "yesterday" against the real `Date()`, not against the injected `now`.
    @Test(".relativeDay yesterday 2h ago across midnight → \"1d\" (day-bucket wins over hours)")
    func labelCrossMidnightTwoHoursRelativeDay() {
        let cal = Self.utcCalendar
        let startOfToday = cal.startOfDay(for: Date())
        let now = cal.date(byAdding: .hour, value: 2, to: startOfToday)!
        let timestamp = cal.date(byAdding: .minute, value: -5, to: startOfToday)!
        let display = SessionAgeDisplay(
            timestamp: timestamp,
            now: now,
            calendar: cal,
            locale: Self.testLocale,
            yesterdayStyle: .relativeDay
        )
        #expect(display.label == "1d")
    }
}
