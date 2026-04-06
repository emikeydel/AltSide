import SwiftUI

struct ParkedSummaryView: View {
    let spot: ParkingSpot
    let onDone: () -> Void

    @State private var showShare = false

    private var accentColor: Color {
        spot.isCleaningSoon ? Color.uberAmber : Color.uberGreen
    }

    var body: some View {
        ZStack {
            Color.uberBlack.ignoresSafeArea()

            VStack(spacing: 0) {
                // Drag handle
                Capsule()
                    .fill(Color.uberGray3.opacity(0.5))
                    .frame(width: 36, height: 4)
                    .padding(.top, 12)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 28) {

                        // Header
                        parkedHeader

                        // Countdown section
                        countdownSection

                        // Schedule detail card
                        scheduleCard

                        // Action buttons
                        VStack(spacing: 10) {
                            UberButton(
                                title: "Share my location",
                                icon: "square.and.arrow.up",
                                style: .secondary,
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
                    .padding(.top, 24)
                }
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSpotView(spot: spot, onDone: { showShare = false })
        }
    }

    // MARK: - Header

    private var parkedHeader: some View {
        VStack(spacing: 10) {
            // Status pill
            HStack(spacing: 6) {
                Circle()
                    .fill(accentColor)
                    .frame(width: 7, height: 7)
                Text(spot.isCleaningSoon ? "MOVE SOON" : "YOU'RE PARKED")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(accentColor)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(accentColor.opacity(0.12))
            .clipShape(Capsule())

            // Street name
            Text(spot.streetName)
                .font(.system(size: 34, weight: .black))
                .tracking(-1)
                .foregroundStyle(Color.uberWhite)
                .multilineTextAlignment(.center)

            // Side + cross streets
            VStack(spacing: 4) {
                if let side = spot.streetSide {
                    Text("\(side.displayName) side of the street")
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
                VStack(spacing: 8) {
                    Text("TIME UNTIL YOU MUST MOVE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(Color.uberGray3)

                    // Big countdown blocks — centered, slightly larger
                    LiveCountdownBlocksView(targetDate: next, accentColor: accentColor)
                        .scaleEffect(1.1)
                        .padding(.vertical, 4)

                    // Move-by callout
                    HStack(spacing: 6) {
                        Image(systemName: spot.isCleaningSoon ? "exclamationmark.triangle.fill" : "clock.badge.checkmark")
                            .font(.system(size: 13))
                        Text(spot.moveByDisplay)
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
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
            }
        }
    }

    // MARK: - Schedule detail card

    private var scheduleCard: some View {
        VStack(spacing: 0) {
            // Card header
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

            Divider().background(Color.white.opacity(0.08))

            VStack(spacing: 0) {
                scheduleRow(
                    icon: "calendar",
                    label: "Days",
                    value: cleaningDaysText
                )
                Divider().background(Color.white.opacity(0.08)).padding(.horizontal, 14)
                scheduleRow(
                    icon: "clock",
                    label: "Time window",
                    value: timeWindowText
                )
                if let next = spot.nextCleaningDate {
                    Divider().background(Color.white.opacity(0.08)).padding(.horizontal, 14)
                    scheduleRow(
                        icon: "arrow.clockwise",
                        label: "Next cleaning",
                        value: nextCleaningText(next),
                        valueColor: accentColor
                    )
                }
            }
            .padding(.bottom, 4)
        }
        .background(Color.uberSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
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
        if days == 0 {
            fmt.dateFormat = "'Today at' h:mm a"
        } else if days == 1 {
            fmt.dateFormat = "'Tomorrow at' h:mm a"
        } else {
            fmt.dateFormat = "EEE MMM d 'at' h:mm a"
        }
        return fmt.string(from: date)
    }
}
