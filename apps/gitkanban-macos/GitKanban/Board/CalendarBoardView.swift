import GitKanbanKit
import GitKittieKit
import SwiftUI

/// The board as a month: each task on the day it is due. Tasks without a due date are
/// counted under the month, not shown.
struct CalendarBoardView: View {
    @Environment(AppModel.self) private var model
    let columns: [Column]
    /// Any day in the month on screen.
    @State private var month = Date()

    private var calendar: Calendar { Calendar.current }
    private var priorities: [Priority] { model.board?.config.priorities ?? [] }

    private struct Item: Identifiable {
        let card: Card
        let lane: Lane
        var id: String { card.id }
    }

    private var items: [Item] {
        columns.flatMap { column in column.cards.map { Item(card: $0, lane: column.lane) } }
    }

    /// Tasks by the day they are due (`yyyy-MM-dd`).
    private var byDay: [String: [Item]] {
        Dictionary(grouping: items.filter { $0.card.fields.due != nil }) { $0.card.fields.due ?? "" }
    }

    /// The days on screen: whole weeks covering the month.
    private var days: [Date] {
        guard let span = calendar.dateInterval(of: .month, for: month),
              let first = calendar.dateInterval(of: .weekOfYear, for: span.start)?.start,
              let last = calendar.dateInterval(of: .weekOfYear, for: span.end.addingTimeInterval(-1))?.end else { return [] }
        var out: [Date] = []
        var day = first
        while day < last {
            out.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? last
        }
        return out
    }

    private var weekdayNames: [String] {
        let names = calendar.shortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(names[start...] + names[..<start])
    }

    var body: some View {
        let grouped = byDay
        let without = items.filter { $0.card.fields.due == nil }.count
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(month.formatted(.dateTime.month(.wide).year())).font(.title3.weight(.semibold))
                Spacer()
                if without > 0 {
                    Text("\(without) task\(without == 1 ? "" : "s") without a due date")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { step(-1) } label: { Image(systemName: "chevron.left") }.help("Previous month")
                    .accessibilityLabel("Previous month")
                Button("Today") { month = Date() }
                Button { step(1) } label: { Image(systemName: "chevron.right") }.help("Next month")
                    .accessibilityLabel("Next month")
            }
            HStack(spacing: 6) {
                ForEach(weekdayNames, id: \.self) { name in
                    Text(name).font(.caption.weight(.medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            GeometryReader { geo in
                let rows = max(days.count / 7, 1)
                let height = max((geo.size.height - CGFloat(rows - 1) * 6) / CGFloat(rows), 70)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                        ForEach(days, id: \.self) { day in
                            cell(day, grouped[CardDates.day(day)] ?? [], height: height)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }

    private func step(_ months: Int) {
        if let next = calendar.date(byAdding: .month, value: months, to: month) { month = next }
    }

    private func cell(_ day: Date, _ tasks: [Item], height: CGFloat) -> some View {
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        let isToday = calendar.isDateInToday(day)
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(calendar.component(.day, from: day))")
                .font(.caption.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? AnyShapeStyle(.white) : (inMonth ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)))
                .frame(minWidth: 20, minHeight: 20)
                .background(isToday ? Color.accentColor : .clear, in: Circle())
            ForEach(tasks.prefix(4)) { item in
                Button { model.selectedCard = item.card } label: {
                    HStack(spacing: 5) {
                        Circle().fill(laneColor(item.lane, model.board?.config ?? EffectiveConfig())).frame(width: 6, height: 6)
                        Text(item.card.fields.title.isEmpty ? item.card.fields.id : item.card.fields.title)
                            .font(.caption).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(model.selectedCard?.id == item.card.id ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .contextMenu { cardMenu(item.card, model: model) }
                .help("\(item.card.fields.title) · \(item.lane.name)")
            }
            if tasks.count > 4 {
                Text("\(tasks.count - 4) more").font(.caption2).foregroundStyle(.secondary).padding(.leading, 6)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
        .background(Theme.panel.opacity(inMonth ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month().day()))
    }
}
