import Charts
import SpaceKitCore
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var days = 90
    @State private var hoveredDate: Date?

    private var points: [(date: Date, used: UInt64, total: UInt64)] {
        model.historyStore.dailyUsage(days: days)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    SectionTitle(title: "Storage History", subtitle: "Not just how much is free — how it changed, and what grew.")
                    Picker("Range", selection: $days) {
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                        Text("1 year").tag(365)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                if points.count < 2 {
                    emptyState
                } else {
                    deltas
                    usageChart
                    HStack(alignment: .top, spacing: 16) {
                        growthChart
                        recoveredChart
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("History")
        .onAppear { model.refreshHistory() }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("History builds up over time", systemImage: "chart.xyaxis.line")
        } description: {
            Text(
                "The background agent records disk usage every few hours and takes a full snapshot weekly. Every analysis in the app adds a snapshot too."
            )
        } actions: {
            if model.agentStatus?.loaded != true {
                Button("Install Background Agent") { model.installAgent() }
            }
        }
    }

    private var deltas: some View {
        let history = model.historyStore
        let month = history.usedDelta(over: .days(30))
        let range = history.usedDelta(over: .days(Double(days)))
        return HStack(spacing: 12) {
            if let last = points.last {
                StatTile(title: "Used now", value: last.used.formattedBytes, detail: "of \(last.total.formattedBytes)", symbol: "internaldrive")
            }
            if let month {
                StatTile(
                    title: "This month", value: ByteCount.formatDelta(month), detail: month > 0 ? "more used" : "freed",
                    symbol: month > 0 ? "arrow.up.right" : "arrow.down.right", tint: month > 0 ? Theme.warning : Theme.good)
            }
            if let range, days != 30 {
                StatTile(
                    title: "Last \(days) days", value: ByteCount.formatDelta(range), detail: range > 0 ? "more used" : "freed",
                    symbol: "calendar")
            }
            StatTile(
                title: "Recovered by SpaceKit", value: model.recovered90Days.formattedBytes, detail: "last 3 months",
                symbol: "arrow.uturn.backward.circle", tint: Theme.good)
        }
    }

    // Single series: one hue, no legend (the title names it); capacity is a muted reference line.
    private var usageChart: some View {
        let total = points.last?.total ?? 0
        let lowest = points.map(\.used).min() ?? 0
        let floor = Double(lowest) * 0.9 / 1e9
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Used space").font(.headline)
                Chart {
                    ForEach(points, id: \.date) { point in
                        AreaMark(
                            x: .value("Day", point.date), yStart: .value("Floor", floor),
                            yEnd: .value("Used (GB)", Double(point.used) / 1e9)
                        )
                        .foregroundStyle(Theme.categorical[0].opacity(0.15))
                        .interpolationMethod(.monotone)
                        LineMark(x: .value("Day", point.date), y: .value("Used (GB)", Double(point.used) / 1e9))
                            .foregroundStyle(Theme.categorical[0])
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)
                    }
                    if total > 0 {
                        RuleMark(y: .value("Capacity", Double(total) / 1e9))
                            .foregroundStyle(Theme.mutedInk)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .annotation(position: .top, alignment: .leading) {
                                Text("Capacity \(total.formattedBytes)").font(.caption).foregroundStyle(.secondary)
                            }
                    }
                    if let hoveredDate, let point = nearest(to: hoveredDate) {
                        RuleMark(x: .value("Day", point.date)).foregroundStyle(Theme.mutedInk.opacity(0.6))
                        PointMark(x: .value("Day", point.date), y: .value("Used (GB)", Double(point.used) / 1e9))
                            .foregroundStyle(Theme.categorical[0])
                            .symbolSize(70)
                            .annotation(position: .top) {
                                VStack(spacing: 2) {
                                    Text(point.date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(
                                        .secondary)
                                    Text(point.used.formattedBytes).font(.callout.weight(.semibold)).monospacedDigit()
                                }
                                .padding(6)
                                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                                .shadow(radius: 2)
                            }
                    }
                }
                .chartYScale(domain: floor...(max(Double(total), Double(points.map(\.used).max() ?? 0)) / 1e9 * 1.02))
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel { if let gb = value.as(Double.self) { Text(ByteCount.format(UInt64(gb * 1e9))) } }
                    }
                }
                .chartXSelection(value: $hoveredDate)
                .frame(height: 260)
            }
        }
    }

    private func nearest(to date: Date) -> (date: Date, used: UInt64, total: UInt64)? {
        points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
    }

    // Growth is polarity, so it uses a diverging pair: warm for grew, cool for shrank. Values are labeled directly.
    private var growthChart: some View {
        let grew = model.historyStore.whatGrew(over: .days(Double(days)), limit: 10)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("What grew?").font(.headline)
                if grew.isEmpty {
                    Text("Needs two snapshots in this range. Run an analysis or wait for the weekly snapshot.").font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Chart(grew) { item in
                        BarMark(x: .value("Change (GB)", Double(item.delta) / 1e9), y: .value("Group", item.name))
                            .foregroundStyle(item.delta > 0 ? Theme.categorical[7] : Theme.categorical[0])
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .annotation(position: item.delta > 0 ? .trailing : .leading) {
                                Text(ByteCount.formatDelta(item.delta)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: CGFloat(grew.count) * 30 + 20)
                    HStack(spacing: 12) {
                        legend(Theme.categorical[7], "Grew")
                        legend(Theme.categorical[0], "Shrank")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var recoveredChart: some View {
        let calendar = Calendar.current
        var byWeek: [Date: UInt64] = [:]
        for entry in model.journal {
            let week = calendar.dateInterval(of: .weekOfYear, for: entry.date)?.start ?? entry.date
            byWeek[week, default: 0] += entry.bytes
        }
        let weeks = byWeek.keys.sorted().map { (week: $0, bytes: byWeek[$0]!) }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recovered per week").font(.headline)
                if weeks.isEmpty {
                    Text("Nothing cleaned yet.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Chart(weeks, id: \.week) { week in
                        BarMark(x: .value("Week", week.week, unit: .weekOfYear), y: .value("Recovered (GB)", Double(week.bytes) / 1e9))
                            .foregroundStyle(Theme.good)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine().foregroundStyle(Theme.hairline)
                            AxisValueLabel { if let gb = value.as(Double.self) { Text(ByteCount.format(UInt64(gb * 1e9))) } }
                        }
                    }
                    .frame(height: 180)
                }
            }
        }
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }
}
