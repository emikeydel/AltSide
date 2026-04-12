import SwiftUI

struct MiniWeekView: View {
    let cleaningDays: [Int]        // weekday ints (1=Sun) that have cleaning
    let nextCleaningDay: Int?      // weekday int of the next cleaning
    var accentColor: Color = .sweepyAmber

    private let labels = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]
    private var todayWeekday: Int { Calendar.current.component(.weekday, from: Date()) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(1...7, id: \.self) { weekday in
                dayColumn(weekday)
            }
        }
    }

    private func dayColumn(_ weekday: Int) -> some View {
        let isToday     = weekday == todayWeekday
        let isCleaning  = cleaningDays.contains(weekday)
        let isNext      = weekday == nextCleaningDay

        return VStack(spacing: 6) {
            // Day label
            Text(labels[weekday - 1])
                .font(.system(size: 10, weight: isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.sweepyWhite : Color.sweepyGray3)

            // Dot
            ZStack {
                Circle()
                    .fill(dotColor(isToday: isToday, isCleaning: isCleaning, isNext: isNext))
                    .frame(width: dotSize(isNext: isNext), height: dotSize(isNext: isNext))

                if isToday {
                    Circle()
                        .strokeBorder(Color.sweepyWhite.opacity(0.6), lineWidth: 1)
                        .frame(width: dotSize(isNext: isNext) + 2, height: dotSize(isNext: isNext) + 2)
                }
            }
            .frame(width: 20, height: 20)

            // Date number (next cleaning only)
            if isNext {
                Text(dateNumber(weekday: weekday))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(accentColor)
            } else {
                Spacer().frame(height: 12)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func dotColor(isToday: Bool, isCleaning: Bool, isNext: Bool) -> Color {
        if isNext { return accentColor }
        if isCleaning { return accentColor.opacity(0.5) }
        if isToday { return Color.sweepyWhite }
        return Color.sweepySurface3
    }

    private func dotSize(isNext: Bool) -> CGFloat {
        isNext ? 14 : 10
    }

    private func dateNumber(weekday: Int) -> String {
        let cal = Calendar.current
        let today = Date()
        let todayWeekday = cal.component(.weekday, from: today)
        var diff = weekday - todayWeekday
        if diff < 0 { diff += 7 }
        guard let target = cal.date(byAdding: .day, value: diff, to: today) else { return "" }
        let f = DateFormatter()
        f.dateFormat = "d"
        return f.string(from: target)
    }
}

#Preview {
    MiniWeekView(cleaningDays: [2, 5], nextCleaningDay: 5)
        .padding()
        .background(.black)
}
