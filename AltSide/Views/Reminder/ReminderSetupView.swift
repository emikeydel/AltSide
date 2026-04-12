import SwiftUI
import SwiftData

struct ReminderSetupView: View {
    let spot: ParkingSpot
    let onSave: () -> Void
    let onSkip: () -> Void
    let onCancel: () -> Void

    @State private var config: ReminderConfig = ReminderConfig()
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ZStack {
            Color.sweepyBlack.ignoresSafeArea()

            VStack(spacing: 0) {
                CardHeader()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {

                        // Spot summary bar
                        spotSummaryBar

                        // Section header
                        Text("SET YOUR REMINDERS")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(Color.sweepyGray3)

                        // Reminder options
                        VStack(spacing: 1) {
                            beforeCleaningRow
                            divider
                            eveningBeforeRow
                            divider
                            morningOfRow
                        }
                        .background(Color.sweepySurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.sweepyBorder, lineWidth: 1)
                        )

                        // CTAs
                        SweepyButton(title: "Save spot & confirm", action: {
                            spot.reminderConfig = config
                            onSave()
                        })

                        Button(action: onSkip) {
                            Text("Skip reminders")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.sweepyGray3)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }

                        Button(action: onCancel) {
                            Label("Cancel — go back", systemImage: "arrow.uturn.left")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.sweepyAmber)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }

                        TipJarButton()

                        Spacer().frame(height: 20)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                }
            }
        }
        .onAppear { config = spot.reminderConfig }
        .sensoryFeedback(.selection, trigger: config.beforeCleaningEnabled)
        .sensoryFeedback(.selection, trigger: config.eveningBeforeEnabled)
        .sensoryFeedback(.selection, trigger: config.morningOfEnabled)
        .sensoryFeedback(.selection, trigger: config.beforeCleaningMinutes)
    }

    // MARK: - Spot Summary Bar

    private var spotSummaryBar: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.sweepyGreen.opacity(0.15)).frame(width: 36, height: 36)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.sweepyGreen)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(spot.streetName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.sweepyWhite)
                if let side = spot.streetSide {
                    HStack(spacing: 4) {
                        let rel = side.relativeLabel(facing: spot.parkingHeading)
                        Text(rel.map { "\($0) side (\(side.displayName))" } ?? "\(side.displayName) side")
                        if spot.nextCleaningDate != nil {
                            Text("·")
                            Text(spot.moveByDisplay)
                                .foregroundStyle(spot.isCleaningSoon ? Color.sweepyAmber : Color.sweepyGreen)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sweepyGray2)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(Color.sweepySurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.sweepyGreen.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Reminder Rows

    private var beforeCleaningRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            toggleRow(
                title: "Before street cleaning",
                subtitle: "Fires \(config.beforeCleaningMinutes < 60 ? "\(config.beforeCleaningMinutes) min" : "1 hr") before the sweeper",
                isOn: $config.beforeCleaningEnabled
            )
            if config.beforeCleaningEnabled {
                timingChips
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
    }

    private var timingChips: some View {
        HStack(spacing: 8) {
            ForEach([15, 30, 45, 60], id: \.self) { mins in
                Button(action: { config.beforeCleaningMinutes = mins }) {
                    Text(mins < 60 ? "\(mins)m" : "\(mins/60)h")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(config.beforeCleaningMinutes == mins ? .black : Color.sweepyGray2)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(config.beforeCleaningMinutes == mins ? Color.sweepyGreen : Color.sweepySurface3)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    private var eveningBeforeRow: some View {
        toggleRow(
            title: "Evening before",
            subtitle: "Reminder at 9:00 PM the night before",
            isOn: $config.eveningBeforeEnabled
        )
    }

    private var morningOfRow: some View {
        toggleRow(
            title: "Morning of cleaning day",
            subtitle: "Early morning heads-up at 7:00 AM",
            isOn: $config.morningOfEnabled
        )
    }

    private func toggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.sweepyWhite)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sweepyGray3)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .tint(Color.sweepyGreen)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var divider: some View {
        Divider()
            .background(Color.sweepyBorder)
            .padding(.horizontal, 16)
    }
}
