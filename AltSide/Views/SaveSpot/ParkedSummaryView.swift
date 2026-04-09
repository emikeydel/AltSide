import SwiftUI

struct ParkedSummaryView: View {
    let spot: ParkingSpot
    let onDone: () -> Void
    var notificationManager: NotificationManager? = nil

    @State private var showShare = false
    @State private var showEditReminders = false
    @State private var sweepyScale: CGFloat = 0.5
    @State private var sweepyOpacity: Double = 0

    private var accentColor: Color { Color.uberGreen }

    var body: some View {
        ZStack {
            Color.uberBlack.ignoresSafeArea()

            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.uberGray3.opacity(0.4))
                    .frame(width: 36, height: 4)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {

                        Image("SweepySplash")
                            .resizable()
                            .scaledToFit()
                            .frame(height: 180)
                            .scaleEffect(sweepyScale)
                            .opacity(sweepyOpacity)
                            .padding(.top, 8)

                        parkedHeader
                        countdownSection
                        scheduleCard
                        remindersCard

                        VStack(spacing: 10) {
                            UberButton(
                                title: "Share my location",
                                icon: "square.and.arrow.up",
                                action: { showShare = true }
                            )
                            Button(action: onDone) {
                                Text("Got it")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.uberGray3)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                        }

                        Spacer().frame(height: 20)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                }
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSpotView(spot: spot, onDone: { showShare = false })
        }
        .sheet(isPresented: $showEditReminders) {
            ReminderSetupView(
                spot: spot,
                onSave: {
                    if let nm = notificationManager {
                        Task { await nm.scheduleAlerts(for: spot) }
                    }
                    showEditReminders = false
                },
                onSkip: { showEditReminders = false }
            )
            .presentationDetents([.large])
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                sweepyScale = 1.0
                sweepyOpacity = 1.0
            }
        }
    }

    // MARK: - Header

    private var parkedHeader: some View {
        VStack(spacing: 8) {
            Text(spot.isCleaningSoon ? "MOVE SOON" : "YOU'RE PARKED")
                .font(.system(size: 13, weight: .black))
                .tracking(1.5)
                .foregroundStyle(accentColor)

            Text(spot.streetName)
                .font(.system(size: 34, weight: .black))
                .tracking(-1)
                .foregroundStyle(Color.uberWhite)
                .multilineTextAlignment(.center)

            VStack(spacing: 4) {
                if let side = spot.streetSide {
                    let rel = side.relativeLabel(facing: spot.parkingHeading)
                    Text(rel.map { "\($0) side (\(side.displayName))" } ?? "\(side.displayName) side")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.uberGray2)
                }
                if !spot.crossStreetFrom.isEmpty && !spot.crossStreetTo.isEmpty {
                    Text("between \(spot.crossStreetFrom) & \(spot.crossStreetTo)")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.uberGray3)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Countdown

    private var countdownSection: some View {
        VStack(spacing: 12) {
            if let next = spot.nextCleaningDate, next > Date() {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 14))
                        Text(spot.moveByDisplay)
                            .font(.system(size: 15, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color(hex: "1A1A1A"))
                    .clipShape(Capsule())

                    LiveCountdownBlocksView(targetDate: next, accentColor: accentColor)
                        .scaleEffect(1.1)
                        .padding(.vertical, 4)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.uberGray3)
                    Text("No cleaning schedule found for this block")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.uberGray3)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(Color.uberSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.uberBorder, lineWidth: 1))
            }
        }
    }

    // MARK: - Schedule Card

    private var scheduleCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CLEANING SCHEDULE")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Color.uberGray3)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().background(Color.uberBorder)

            VStack(spacing: 0) {
                scheduleRow(icon: "calendar", label: "Days", value: cleaningDaysText)
                Divider().background(Color.uberBorder).padding(.horizontal, 14)
                scheduleRow(icon: "clock", label: "Time window", value: timeWindowText)
                if let next = spot.nextCleaningDate {
                    Divider().background(Color.uberBorder).padding(.horizontal, 14)
                    scheduleRow(icon: "arrow.clockwise", label: "Next cleaning",
                                value: nextCleaningText(next), valueColor: accentColor)
                }
            }
            .padding(.bottom, 4)
        }
        .background(Color.uberSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.uberBorder, lineWidth: 1))
    }

    private func scheduleRow(icon: String, label: String, value: String, valueColor: Color = Color.uberWhite) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Color.uberGray3)
                .frame(width: 18)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Color.uberGray2)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Reminders Card

    private var remindersCard: some View {
        VStack(spacing: 0) {
            // Header row
            HStack {
                Text("REMINDERS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Color.uberGray3)
                Spacer()
                Button(action: { showEditReminders = true }) {
                    Text(activeReminders.isEmpty ? "Add" : "Edit")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.uberGreen)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.uberGreen.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().background(Color.uberBorder)

            if activeReminders.isEmpty {
                // No reminders set
                Button(action: { showEditReminders = true }) {
                    HStack(spacing: 10) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.uberGray3)
                            .frame(width: 18)
                        Text("No reminders set — tap to add")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.uberGray3)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.uberGray3)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            } else {
                // Active reminders list
                VStack(spacing: 0) {
                    ForEach(Array(activeReminders.enumerated()), id: \.offset) { idx, item in
                        if idx > 0 {
                            Divider().background(Color.uberBorder).padding(.horizontal, 14)
                        }
                        HStack(spacing: 10) {
                            Image(systemName: "bell.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.uberGreen)
                                .frame(width: 18)
                            Text(item)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.uberGray2)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .background(Color.uberSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.uberBorder, lineWidth: 1))
    }

    private var activeReminders: [String] {
        let config = spot.reminderConfig
        var list: [String] = []
        if config.beforeCleaningEnabled {
            let mins = config.beforeCleaningMinutes
            list.append(mins < 60 ? "\(mins) min before street cleaning" : "1 hr before street cleaning")
        }
        if config.eveningBeforeEnabled { list.append("Evening before at 9:00 PM") }
        if config.morningOfEnabled     { list.append("Morning of cleaning at 7:00 AM") }
        return list
    }

    // MARK: - Computed display strings

    private var cleaningDaysText: String {
        let dayNames = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let names = spot.cleaningDays.compactMap { $0 < dayNames.count ? dayNames[$0] : nil }
        return names.isEmpty ? "Unknown" : names.joined(separator: ", ")
    }

    private var timeWindowText: String {
        func fmt(h: Int, m: Int) -> String {
            let hour = h == 0 ? 12 : (h > 12 ? h - 12 : h)
            let min  = m == 0 ? "" : ":\(String(format: "%02d", m))"
            let ampm = h < 12 ? "AM" : "PM"
            return "\(hour)\(min) \(ampm)"
        }
        return "\(fmt(h: spot.cleaningStartHour, m: spot.cleaningStartMinute)) – \(fmt(h: spot.cleaningEndHour, m: spot.cleaningEndMinute))"
    }

    private func nextCleaningText(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        let fmt = DateFormatter()
        if days == 0 { fmt.dateFormat = "'Today at' h:mm a" }
        else if days == 1 { fmt.dateFormat = "'Tomorrow at' h:mm a" }
        else { fmt.dateFormat = "EEE MMM d 'at' h:mm a" }
        return fmt.string(from: date)
    }
}
