import GitKanbanKit
import GitKittieKit
import SwiftUI

/// The board as a calendar: each task on the day it is due, in one column of weeks that
/// scrolls on through the months (GITKITTIE-113). The title names the month on screen; the
/// arrows and Today jump by month. Tasks without a due date are counted, not shown.
///
/// It used to be one month sized to fill the window, so a scroll had nothing to move and the
/// only way on was the arrows.
struct CalendarBoardView: View {
    @Environment(AppModel.self) private var model
    let columns: [Column]
    /// The week at the top of the screen.
    @State private var topWeek: Date?

    private var calendar: Calendar { Calendar.current }

    /// The weeks shown, rows at a fixed height so the lazy column can place them without
    /// drawing them first.
    private static let spacing: CGFloat = 6
    private static let weeksOnScreen: CGFloat = 5
    private static let minimumRowHeight: CGFloat = 104

    var body: some View {
        // `topWeek` is only handed on here, never read: the week at the top changes all the
        // time while scrolling, and reading it would rebuild every week on screen each time.
        let content = CalendarContent(columns: columns, config: model.board?.config ?? EffectiveConfig())
        let span = BoardCalendar(dueDays: content.byDay.keys)
        VStack(spacing: 10) {
            CalendarHeader(span: span, topWeek: $topWeek, without: content.withoutDue)
            HStack(spacing: Self.spacing) {
                ForEach(weekdayNames, id: \.self) { name in
                    Text(name).font(.caption.weight(.medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 6)
                }
            }
            GeometryReader { geo in
                let rowHeight = max((geo.size.height - (Self.weeksOnScreen - 1) * Self.spacing) / Self.weeksOnScreen, Self.minimumRowHeight)
                ScrollView {
                    LazyVStack(spacing: Self.spacing) {
                        ForEach(span.weeks, id: \.self) { week in
                            CalendarWeekRow(days: span.days(of: week), content: content, height: rowHeight)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $topWeek, anchor: .top)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        // Opens on this month.
        .onAppear { if topWeek == nil { topWeek = span.topWeek(forMonthOf: Date()) } }
    }

    private var weekdayNames: [String] {
        let names = calendar.shortStandaloneWeekdaySymbols
        let start = calendar.firstWeekday - 1
        return Array(names[start...] + names[..<start])
    }
}

/// The month on screen, how many tasks have no day, and the month and Today buttons.
private struct CalendarHeader: View {
    let span: BoardCalendar
    @Binding var topWeek: Date?
    let without: Int

    private var top: Date { topWeek ?? span.topWeek(forMonthOf: Date()) ?? Date() }

    var body: some View {
        let month = span.month(atTop: top)
        HStack(spacing: 10) {
            Text(month.formatted(.dateTime.month(.wide).year())).font(.title3.weight(.semibold))
            Spacer()
            if without > 0 {
                Text("\(without) task\(without == 1 ? "" : "s") without a due date")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Button { go(-1) } label: { Image(systemName: "chevron.left") }
                .help("Previous month")
                .accessibilityLabel("Previous month")
            Button("Today") { withAnimation(.snappy) { topWeek = span.topWeek(forMonthOf: Date()) } }
                .help("Go to this month")
            Button { go(1) } label: { Image(systemName: "chevron.right") }
                .help("Next month")
                .accessibilityLabel("Next month")
        }
    }

    private func go(_ months: Int) {
        guard let next = span.topWeek(stepping: months, from: top), span.weeks.contains(next) else { return }
        withAnimation(.snappy) { topWeek = next }
    }
}

/// The board's tasks by the day they are due, worked out once per drawing of the calendar
/// rather than once per day cell.
private struct CalendarContent {
    struct Item: Identifiable {
        let card: Card
        let laneName: String
        let color: Color
        var id: String { card.id }
    }

    /// Tasks by the day they are due (`yyyy-MM-dd`).
    let byDay: [String: [Item]]
    let withoutDue: Int

    init(columns: [Column], config: EffectiveConfig) {
        var byDay: [String: [Item]] = [:]
        var without = 0
        for column in columns {
            let color = laneColor(column.lane, config)
            for card in column.cards {
                // A due date written with a time still lands on its day.
                guard let due = card.fields.due.flatMap(CardDates.date).map(CardDates.day) else { without += 1; continue }
                byDay[due, default: []].append(Item(card: card, laneName: column.lane.name, color: color))
            }
        }
        self.byDay = byDay
        self.withoutDue = without
    }
}

/// One week: seven days side by side.
private struct CalendarWeekRow: View {
    let days: [Date]
    let content: CalendarContent
    let height: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(days, id: \.self) { day in
                CalendarDayCell(day: day, tasks: content.byDay[CardDates.day(day)] ?? [], height: height)
            }
        }
        .frame(height: height)
    }
}

/// One day: its number (and the month's name on the 1st), and the tasks due that day, as
/// many as fit; the rest behind "N more".
private struct CalendarDayCell: View {
    let day: Date
    let tasks: [CalendarContent.Item]
    let height: CGFloat
    @State private var showsAll = false

    private var calendar: Calendar { Calendar.current }
    /// Rows that fit under the day's number, one kept for "N more" when they do not all fit.
    private var fitting: Int {
        let rows = max(Int((height - 34) / 22), 1)
        return tasks.count > rows ? rows - 1 : rows
    }

    var body: some View {
        let dayNumber = calendar.component(.day, from: day)
        let isToday = calendar.isDateInToday(day)
        // Months alternate in shade, so where one ends is plain while scrolling.
        let isEvenMonth = calendar.component(.month, from: day) % 2 == 0
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("\(dayNumber)")
                    .font(.caption.weight(isToday || dayNumber == 1 ? .bold : .regular))
                    .foregroundStyle(isToday ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .frame(minWidth: 20, minHeight: 20)
                    .background(isToday ? Color.accentColor : .clear, in: Circle())
                if dayNumber == 1 {
                    Text(day.formatted(.dateTime.month(.abbreviated)))
                        .font(.caption.weight(.bold))
                }
            }
            ForEach(tasks.prefix(fitting)) { item in CalendarTaskChip(item: item) }
            if tasks.count > fitting {
                Button("\(tasks.count - fitting) more") { showsAll = true }
                    .buttonStyle(.plain)
                    .font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.leading, 6)
                    .popover(isPresented: $showsAll, arrowEdge: .trailing) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(day.formatted(.dateTime.weekday(.wide).month().day())).font(.headline).padding(.bottom, 4)
                            ForEach(tasks) { item in CalendarTaskChip(item: item) }
                        }
                        .padding(12)
                        .frame(width: 280)
                    }
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.panel.opacity(isEvenMonth ? 1 : 0.6), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month().day()))
    }
}

/// A task in a day: its lane's colour and its title. Its own view, so choosing a task redraws
/// the chips and not every day around them.
private struct CalendarTaskChip: View {
    @Environment(AppModel.self) private var model
    let item: CalendarContent.Item

    var body: some View {
        let isSelected = model.selectedCard?.id == item.card.id
        Button { model.selectedCard = item.card } label: {
            HStack(spacing: 5) {
                Circle().fill(item.color).frame(width: 6, height: 6)
                Text(item.card.fields.title.isEmpty ? item.card.fields.id : item.card.fields.title)
                    .font(.caption).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(isSelected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { cardMenu(item.card, model: model) }
        .help("\(item.card.fields.title) · \(item.laneName)")
    }
}
