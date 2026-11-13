import SwiftUI

enum JournalDate {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = Calendar.current.firstWeekday
        return calendar
    }
    static func key(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    static func date(_ key: String) -> Date? {
        let values = key.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: values[0], month: values[1], day: values[2], hour: 12))
    }
    static func monthDays(_ date: Date) -> [Date?] {
        let calendar = calendar
        guard let start = calendar.dateInterval(of: .month, for: date)?.start,
              let range = calendar.range(of: .day, in: .month, for: date) else { return [] }
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + range.compactMap {
            calendar.date(byAdding: .day, value: $0 - 1, to: start)
        }.map(Optional.some)
    }
}

struct JournalCalendar: View {
    let counts: [String: Int]
    let selectedDay: String
    let select: (String) -> Void
    @State private var month: Date
    @State private var choosingDate = false
    @State private var jumpDate = Date()

    init(counts: [String: Int], selectedDay: String, select: @escaping (String) -> Void) {
        self.counts = counts; self.selectedDay = selectedDay; self.select = select
        _month = State(initialValue: JournalDate.date(selectedDay) ?? Date())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 16) {
                HStack {
                    monthButton(-1, symbol: "chevron.left")
                    Button { jumpDate = month; choosingDate = true } label: {
                        Label(month.formatted(.dateTime.month(.wide).year()), systemImage: "chevron.down")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                    }.accessibilityLabel("Choose month and year")
                    monthButton(1, symbol: "chevron.right")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 8) {
                    ForEach(0..<7) { offset in
                        let symbols = JournalDate.calendar.veryShortStandaloneWeekdaySymbols
                        Text(symbols[(JournalDate.calendar.firstWeekday - 1 + offset) % 7])
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(JournalDate.monthDays(month).enumerated()), id: \.offset) { _, date in
                        if let date { day(date) }
                        else { Color.clear.frame(height: 48) }
                    }
                }
                Spacer(minLength: 0)
            }.padding(16)
            }.background(Modernist.paper)
                .navigationTitle("Journal")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Today") { select(JournalDate.key(Date())) } }
                .sheet(isPresented: $choosingDate) {
                    NavigationStack {
                        DatePicker("Go to date", selection: $jumpDate, displayedComponents: .date)
                            .datePickerStyle(.graphical).padding()
                            .navigationTitle("Go to date").navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { choosingDate = false } }
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Go") { month = jumpDate; choosingDate = false; select(JournalDate.key(jumpDate)) }
                                }
                            }
                    }.presentationDetents([.medium, .large])
                }
        }.presentationDetents([.medium, .large])
    }

    private func monthButton(_ offset: Int, symbol: String) -> some View {
        Button {
            if let next = JournalDate.calendar.date(byAdding: .month, value: offset, to: month) { month = next }
        } label: { Image(systemName: symbol).frame(width: 44, height: 44) }
        .accessibilityLabel(offset < 0 ? "Previous month" : "Next month")
    }

    private func day(_ date: Date) -> some View {
        let key = JournalDate.key(date), count = counts[key] ?? 0
        return Button { select(key) } label: {
            VStack(spacing: 3) {
                Text("\(JournalDate.calendar.component(.day, from: date))").font(.body.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
                if count > 0 {
                    HStack(spacing: 2) {
                        Circle().frame(width: 4, height: 4)
                        Text("\(count)").font(.system(size: 9))
                    }
                } else { Color.clear.frame(height: 10) }
            }.frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(count >= 3 ? Modernist.paper : Modernist.ink)
                .background(count == 0 ? Modernist.canvas : count >= 3 ? Modernist.ink : Modernist.neutral300.opacity(count == 1 ? 0.5 : 1))
                .overlay { Rectangle().stroke(key == selectedDay ? Modernist.ink : .clear, lineWidth: 2) }
        }.buttonStyle(.plain)
            .accessibilityLabel("\(date.formatted(date: .abbreviated, time: .omitted)), \(count) notes")
            .accessibilityAddTraits(key == selectedDay ? .isSelected : [])
            .accessibilityIdentifier("journal.day.\(key)")
    }
}
