import SwiftUI
import Combine

struct CountdownBlocksView: View {
    let timeInterval: TimeInterval
    var accentColor: Color = .sweepyAmber

    private var days: Int    { max(0, Int(timeInterval) / 86400) }
    private var hours: Int   { max(0, (Int(timeInterval) % 86400) / 3600) }
    private var minutes: Int { max(0, (Int(timeInterval) % 3600) / 60) }

    var body: some View {
        HStack(spacing: 8) {
            block(value: days,    label: "DAYS")
            separator
            block(value: hours,   label: "HRS")
            separator
            block(value: minutes, label: "MIN")
        }
    }

    private func block(value: Int, label: String) -> some View {
        VStack(spacing: 4) {
            Text(String(format: "%02d", value))
                .font(.system(size: 28, weight: .black, design: .monospaced))
                .tracking(-0.5)
                .foregroundStyle(accentColor)
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Color.sweepyGray3)
        }
        .frame(width: 72, height: 64)
        .background(Color.sweepySurface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.sweepyBorder, lineWidth: 1)
        )
    }

    private var separator: some View {
        Text(":")
            .font(.system(size: 22, weight: .black))
            .foregroundStyle(Color.sweepyGray3)
            .offset(y: -6)
    }
}

/// Auto-updating countdown that ticks every second.
struct LiveCountdownBlocksView: View {
    let targetDate: Date
    var accentColor: Color = .sweepyAmber

    @State private var timeRemaining: TimeInterval = 0

    var body: some View {
        CountdownBlocksView(timeInterval: timeRemaining, accentColor: accentColor)
            .onAppear { update() }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in update() }
    }

    private func update() {
        timeRemaining = max(0, targetDate.timeIntervalSinceNow)
    }
}

#Preview {
    CountdownBlocksView(timeInterval: 90061)
        .padding()
        .background(.black)
}
