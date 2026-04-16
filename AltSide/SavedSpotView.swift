import SwiftUI
import MapKit

/// Full-screen "you're parked" view shown when a spot is saved.
/// Replaces the background map entirely — no two maps stacked.
struct SavedSpotView: View {
    let spot: ParkingSpot
    let onClear: () -> Void
    let onNavigate: () -> Void
    @Environment(\.notificationManager) private var notificationManager

    @State private var showShare = false
    @State private var showParkAgainConfirm = false
    @State private var showWelcome = false
    @State private var showEditReminders = false

    private var accentColor: Color {
        spot.isCleaningSoon ? Color.sweepyAmber : Color.sweepyGreen
    }

    var body: some View {
        ZStack {
            Color.sweepyBlack.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {

                    // Mini map
                    miniMap

                    // Status + street info + action icons inline
                    parkedHeader

                    // Countdown
                    countdownSection

                    // Reminders
                    remindersCard

                    // ASP updates
                    aspUpdatesSection

                    // Tip jar
                    TipJarButton()

                    // Primary CTA
                    SweepyButton(
                        title: "Park again",
                        icon: "car.fill",
                        style: .primary,
                        action: { showParkAgainConfirm = true }
                    )

                    Spacer().frame(height: 20)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
        }
        .sheet(isPresented: $showShare) {
            ShareSpotView(spot: spot, onDone: { showShare = false })
        }
        .sheet(isPresented: $showWelcome) {
            WelcomeView { showWelcome = false }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showEditReminders) {
            ReminderSetupView(
                spot: spot,
                onSave: {
                    Task { @MainActor in await notificationManager.scheduleAlerts(for: spot) }
                    showEditReminders = false
                },
                onSkip: { showEditReminders = false },
                onCancel: { showEditReminders = false }
            )
            .presentationDetents([.large])
        }
        .alert("Park somewhere new?", isPresented: $showParkAgainConfirm) {
            Button("Remove spot & reminders", role: .destructive) {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                onClear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear your saved spot and cancel any street cleaning reminders.")
        }
    }

    // MARK: - Mini Map

    private var miniMap: some View {
        Map(position: .constant(
            .region(MKCoordinateRegion(
                center: spot.coordinate,
                latitudinalMeters: 300,
                longitudinalMeters: 300
            ))
        ), interactionModes: []) {
            Annotation("", coordinate: spot.coordinate) {
                ZStack {
                    Circle()
                        .fill(Color.sweepyRed.opacity(0.2))
                        .frame(width: 40, height: 40)
                    Circle()
                        .fill(Color.sweepyRed)
                        .frame(width: 28, height: 28)
                    Image(systemName: "car.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(color: Color.sweepyRed.opacity(0.5), radius: 6)
            }
        }
        .mapStyle(.standard)
        .mapControls {}
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.sweepyBorder, lineWidth: 1)
        )
    }

    // MARK: - Header

    private var parkedHeader: some View {
        VStack(spacing: 10) {
            // Status pill + icon buttons on same row
            HStack {
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

                Spacer()

                // Navigate + Share + Info icons
                HStack(spacing: 8) {
                    iconButton(systemName: "arrow.triangle.turn.up.right.circle.fill", action: onNavigate)
                    iconButton(systemName: "square.and.arrow.up", action: { showShare = true })
                    iconButton(systemName: "questionmark", action: { showWelcome = true })
                }
            }

            Text(spot.streetName)
                .font(.system(size: 34, weight: .black))
                .tracking(-1)
                .foregroundStyle(Color.sweepyWhite)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            VStack(spacing: 4) {
                if let side = spot.streetSide {
                    let rel = side.relativeLabel(facing: spot.parkingHeading)
                    Text(rel.map { "\($0) side (\(side.displayName))" } ?? "\(side.displayName) side")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.sweepyGray2)
                }
                if !spot.crossStreetFrom.isEmpty && !spot.crossStreetTo.isEmpty {
                    Text("between \(spot.crossStreetFrom) & \(spot.crossStreetTo)")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.sweepyGray3)
                }
            }
        }
    }

    private func iconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.sweepySurface2)
                    .frame(width: 36, height: 36)
                Image(systemName: systemName)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.sweepyGray2)
            }
        }
    }

    // MARK: - Countdown

    private var countdownSection: some View {
        VStack(spacing: 12) {
            if let next = spot.nextCleaningDate, next > Date() {
                VStack(spacing: 8) {
                    Text("TIME UNTIL YOU MUST MOVE")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.5)
                        .foregroundStyle(Color.sweepyGray3)

                    LiveCountdownBlocksView(targetDate: next, accentColor: accentColor)
                        .scaleEffect(1.1)
                        .padding(.vertical, 4)

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
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.sweepyGray3)
                    Text("No cleaning schedule found for this block")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.sweepyGray3)
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(Color.sweepySurface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Reminders Card

    private var remindersCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("REMINDERS")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.5)
                    .foregroundStyle(Color.sweepyGray3)
                Spacer()
                Button(action: { showEditReminders = true }) {
                    Text(activeReminders.isEmpty ? "Add" : "Edit")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.sweepyGreen)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.sweepyGreen.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().background(Color.sweepyBorder)

            if activeReminders.isEmpty {
                Button(action: { showEditReminders = true }) {
                    HStack(spacing: 10) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.sweepyGray3)
                            .frame(width: 18)
                        Text("No reminders set — tap to add")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.sweepyGray3)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.sweepyGray3)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(activeReminders.enumerated()), id: \.offset) { idx, item in
                        if idx > 0 {
                            Divider().background(Color.sweepyBorder).padding(.horizontal, 14)
                        }
                        HStack(spacing: 10) {
                            Image(systemName: "bell.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.sweepyGreen)
                                .frame(width: 18)
                            Text(item)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.sweepyGray2)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .background(Color.sweepySurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.sweepyBorder, lineWidth: 1))
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

    // MARK: - ASP Updates

    @ViewBuilder
    private var aspUpdatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STREET CLEANING UPDATES")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(Color.sweepyGray3)

            if let todayHoliday = ASPSuspensionCalendar.holidayName(on: Date()) {
                updateRow(icon: "checkmark.shield.fill", iconColor: .sweepyGreen,
                          title: "Suspended today", subtitle: todayHoliday, accent: .sweepyGreen)
            } else if let next = spot.nextCleaningDate,
                      let holiday = ASPSuspensionCalendar.holidayName(on: next) {
                updateRow(icon: "checkmark.shield.fill", iconColor: .sweepyGreen,
                          title: "Next cleaning suspended", subtitle: "\(holiday) — no need to move", accent: .sweepyGreen)
            } else {
                updateRow(icon: "checkmark.circle.fill", iconColor: .sweepyGray3,
                          title: "ASP in effect", subtitle: "Normal street cleaning schedule applies", accent: .sweepyGray3)
            }

            if let upcoming = ASPSuspensionCalendar.nextSuspension(after: Date()) {
                updateRow(icon: "calendar", iconColor: .sweepyGray2,
                          title: "Next suspension",
                          subtitle: formattedDate(upcoming.date) + " · " + upcoming.holiday,
                          accent: .sweepyGray2)
            }
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE, MMM d"
        return fmt.string(from: date)
    }

    private func updateRow(icon: String, iconColor: Color, title: String, subtitle: String, accent: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(iconColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.sweepyWhite)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sweepyGray3)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.sweepySurface2)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accent.opacity(0.2), lineWidth: 1)
        )
    }
}
