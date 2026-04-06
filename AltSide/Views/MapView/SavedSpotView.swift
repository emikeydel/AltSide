import SwiftUI
import MapKit

/// Full-screen "you're parked" view shown when a spot is saved.
/// Replaces the background map entirely — no two maps stacked.
struct SavedSpotView: View {
    let spot: ParkingSpot
    let onClear: () -> Void
    let onNavigate: () -> Void

    @State private var showShare = false
    @State private var isClearing = false
    @State private var showParkAgainConfirm = false
    @State private var showWelcome = false

    private var accentColor: Color {
        spot.isCleaningSoon ? Color.uberAmber : Color.uberGreen
    }

    var body: some View {
        ZStack {
            Color.uberBlack.ignoresSafeArea()

            if isClearing {
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(Color.uberGray2)
                        .scaleEffect(1.2)
                    Text("Finding your spot...")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.uberGray3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {

                        // Mini map
                        miniMap

                        // Status + street info + action icons inline
                        parkedHeader

                        // Countdown
                        countdownSection

                        // ASP updates
                        aspUpdatesSection

                        // Primary CTA
                        UberButton(
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
        }
        .sheet(isPresented: $showShare) {
            ShareSpotView(spot: spot, onDone: { showShare = false })
        }
        .sheet(isPresented: $showWelcome) {
            WelcomeView { showWelcome = false }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .alert("Park somewhere new?", isPresented: $showParkAgainConfirm) {
            Button("Remove spot & reminders", role: .destructive) {
                isClearing = true
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
                        .fill(Color.uberRed.opacity(0.2))
                        .frame(width: 40, height: 40)
                    Circle()
                        .fill(Color.uberRed)
                        .frame(width: 28, height: 28)
                    Image(systemName: "car.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(color: Color.uberRed.opacity(0.5), radius: 6)
            }
        }
        .mapStyle(.standard)
        .mapControls {}
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
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
                .foregroundStyle(Color.uberWhite)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

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
    }

    private func iconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.uberSurface2)
                    .frame(width: 36, height: 36)
                Image(systemName: systemName)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.uberGray2)
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
                        .foregroundStyle(Color.uberGray3)

                    LiveCountdownBlocksView(targetDate: next, accentColor: accentColor)
                        .scaleEffect(1.1)
                        .padding(.vertical, 4)

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

    // MARK: - ASP Updates

    @ViewBuilder
    private var aspUpdatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STREET CLEANING UPDATES")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.5)
                .foregroundStyle(Color.uberGray3)

            if let todayHoliday = ASPSuspensionCalendar.holidayName(on: Date()) {
                updateRow(icon: "checkmark.shield.fill", iconColor: .uberGreen,
                          title: "Suspended today", subtitle: todayHoliday, accent: .uberGreen)
            } else if let next = spot.nextCleaningDate,
                      let holiday = ASPSuspensionCalendar.holidayName(on: next) {
                updateRow(icon: "checkmark.shield.fill", iconColor: .uberGreen,
                          title: "Next cleaning suspended", subtitle: "\(holiday) — no need to move", accent: .uberGreen)
            } else {
                updateRow(icon: "checkmark.circle.fill", iconColor: .uberGray3,
                          title: "ASP in effect", subtitle: "Normal street cleaning schedule applies", accent: .uberGray3)
            }

            if let upcoming = ASPSuspensionCalendar.nextSuspension(after: Date()) {
                updateRow(icon: "calendar", iconColor: .uberGray2,
                          title: "Next suspension",
                          subtitle: formattedDate(upcoming.date) + " · " + upcoming.holiday,
                          accent: .uberGray2)
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
                    .foregroundStyle(Color.uberWhite)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.uberGray3)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.uberSurface2)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(accent.opacity(0.2), lineWidth: 1)
        )
    }
}
