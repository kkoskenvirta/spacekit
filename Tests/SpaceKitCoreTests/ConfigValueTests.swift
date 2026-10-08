import Foundation
import Testing
import Yams

@testable import SpaceKitCore

@Suite("Config values")
struct ConfigValueTests {
    @Test("Sizes too large for 64 bits are rejected instead of trapping")
    func byteCountOverflow() {
        #expect(ByteCount.parse("20000000TB") == nil)
        #expect(ByteCount.parse("16EiB") == nil)
        #expect(ByteCount.parse("18446744073709551616") == nil)
        #expect(ByteCount.parse("18446744073709551615")?.bytes == UInt64.max)
        #expect(ByteCount.parse("1e30 kb") == nil)
        #expect(ByteCount.parse("inf GB") == nil)
        #expect(ByteCount.parse("-1GB") == nil)
    }

    @Test("Ages reject negative, non-finite and absurd values")
    func ageBounds() {
        #expect(Age.parse("-3d") == nil)
        #expect(Age.parse("-3") == nil)
        #expect(Age.parse("inf") == nil)
        #expect(Age.parse("infd") == nil)
        #expect(Age.parse("nan") == nil)
        #expect(Age.parse("1e300y") == nil)
        #expect(Age.parse("5m") == Age(seconds: 300))
        #expect(Age.parse("100y") == .days(36_500))
    }

    @Test("Numeric ages in YAML are checked like text")
    func numericAgeDecoding() throws {
        #expect(throws: (any Error).self) { try YAMLDecoder().decode(Age.self, from: "-5") }
        #expect(throws: (any Error).self) { try YAMLDecoder().decode(Age.self, from: ".inf") }
        #expect(throws: (any Error).self) { try YAMLDecoder().decode(Age.self, from: ".nan") }
        #expect(try YAMLDecoder().decode(Age.self, from: "30") == .days(30))
    }

    @Test("olderThan and keepRecent reject sub-day values and hint at months")
    func retentionAges() throws {
        let minutes = "jobs:\n  - name: x\n    rules: [a]\n    when:\n      olderThan: 6m\n"
        let error = #expect(throws: (any Error).self) { try ConfigStore.parse(minutes) }
        #expect("\(error.map(DecodingErrorText.describe) ?? "")".contains("6mo"))
        #expect(throws: (any Error).self) { try ConfigStore.parse("jobs:\n  - name: x\n    rules: [a]\n    when:\n      keepRecent: 12h\n") }
        #expect(throws: (any Error).self) { try ConfigStore.parse("jobs:\n  - name: x\n    rules: [a]\n    when:\n      keepRecent: 0\n") }
        let config = try ConfigStore.parse("jobs:\n  - name: x\n    rules: [a]\n    when:\n      olderThan: 6mo\n      keepRecent: 36h\n")
        #expect(config.jobs[0].when.olderThan == .days(180))
        #expect(config.jobs[0].when.keepRecent == .hours(36))

        let rule = "name: x\npath: ~/.cache/x\npolicy:\n  olderThan: 3m\n"
        #expect(throws: (any Error).self) { try RuleLibrary.parse(yaml: rule) }
        #expect(Age.retentionProblem(.days(1), text: "1d") == nil)
    }

    @Test("checkEvery is clamped to a finite range")
    func checkEveryClamp() throws {
        #expect(try ConfigStore.parse("automation:\n  checkEvery: 1m\n").automation.checkEvery.seconds == 300)
        #expect(try ConfigStore.parse("automation:\n  checkEvery: 30y\n").automation.checkEvery.seconds == 86_400)
        #expect(try ConfigStore.parse("automation:\n  checkEvery: 2h\n").automation.checkEvery == .hours(2))
    }

    @Test("Schedule strings must be understood completely")
    func strictSchedules() {
        let invalid = [
            "daily at 3am", "weekly 25:00", "monthly on the 15th", "daily sunday", "monthly monday", "weekly weekly",
            "sunday monday", "03:00", "daily 03:00 04:00", "daily at 3:0", "daily at +3:00", "every", "",
        ]
        for text in invalid {
            #expect(Schedule.parse(text) == nil, "\(text)")
        }
        #expect(Schedule.parse("daily at 02:30") == Schedule(every: .daily, at: "02:30"))
        #expect(Schedule.parse("every sunday at 4:00") == Schedule(every: .weekly, at: "04:00", weekday: .sunday))
        #expect(Schedule.parse("weekly on mon") == Schedule(every: .weekly, weekday: .monday))
        #expect(Schedule.parse("Monthly") == Schedule(every: .monthly, day: 1))
        #expect(Schedule.parse("nightly") == Schedule(every: .daily))
        #expect(Schedule.parse("hourly") == Schedule(every: .hourly))
    }

    @Test("Object schedules reject days some months don't have")
    func scheduleDays() throws {
        func job(day: Int) -> String { "jobs:\n  - name: x\n    rules: [a]\n    schedule: {every: monthly, day: \(day)}\n" }
        #expect(throws: (any Error).self) { try ConfigStore.parse(job(day: 31)) }
        #expect(throws: (any Error).self) { try ConfigStore.parse(job(day: 0)) }
        #expect(try ConfigStore.parse(job(day: 28)).jobs[0].schedule.day == 28)
        let time = Schedule.components("7:05")
        #expect(time?.hour == 7 && time?.minute == 5)
        #expect(Schedule.components("24:00") == nil)
    }

    @Test("Rule policies are typed: unknown modes, types and schedules are errors")
    func typedPolicy() throws {
        func policy(_ body: String) throws -> PolicySpec? {
            try RuleLibrary.parse(yaml: "name: x\npath: ~/.cache/x\npolicy:\n" + body).first?.policy
        }
        #expect(throws: (any Error).self) { try policy("  mode: automtic\n") }
        #expect(throws: (any Error).self) { try policy("  type: sise\n") }
        #expect(throws: (any Error).self) { try policy("  schedule: fortnightly\n") }
        let parsed = try #require(try policy("  type: age\n  schedule: monthly\n  mode: automatic\n  olderThan: 30d\n"))
        #expect(parsed == PolicySpec(type: .age, olderThan: .days(30), schedule: Schedule(every: .monthly, day: 1), mode: .automatic))
        let rule = try #require(try RuleLibrary.parse(yaml: "name: x\npath: ~/.cache/x\nexclusions: [active_projects]\n").first)
        #expect(Job.suggested(for: rule).when.keepRecent == Job.defaultActiveProjectsWindow)
    }

    @Test("Ages convert to and from dates")
    func ageDates() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Age.days(2).ago(from: now) == Date(timeIntervalSince1970: 1_000_000 - 172_800))
        #expect(Age.since(Date(timeIntervalSince1970: 1_000_000 - 3 * 86_400), now: now).days == 3)
    }
}
