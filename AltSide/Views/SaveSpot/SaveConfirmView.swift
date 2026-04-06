import SwiftUI

struct SaveConfirmView: View {
    let spot: ParkingSpot
    let onSetReminders: () -> Void
    let onShare: () -> Void
    let onDone: () -> Void

    @State private var checkmarkScale: CGFloat = 0.3
    @State private var checkmarkOpacity: Double = 0

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
                        // Animated checkmark
                        ZStack {
                            Circle()
                                .fill(Color.uberGreen.opacity(0.12))
                                .frame(width: 96, height: 96)
                            Circle()
                                .fill(Color.uberGreen.opacity(0.2))
                                .frame(width: 72, height: 72)
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 48))
                                .foregroundStyle(Color.uberGreen)
                        }
                        .scaleEffect(checkmarkScale)
                        .opacity(checkmarkOpacity)
                        .padding(.top, 32)

                        // Title
                        VStack(spacing: 8) {
                            Text("Spot saved!")
                                .font(.system(size: 28, weight: .black))
                                .tracking(-0.8)
                                .foregroundStyle(Color.uberWhite)
                            Text(spot.streetName)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.uberGreen)
                            if let side = spot.streetSide {
                                Text("\(side.displayName) side")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.uberGray2)
                            }
                        }

                        // Info card
                        spotInfoCard

                        // Actions
                        VStack(spacing: 10) {
                            UberButton(
                                title: "Set reminders",
                                icon: "bell.badge.fill",
                                action: onSetReminders
                            )
                            UberButton(
                                title: "Share with someone",
                                icon: "square.and.arrow.up",
                                style: .secondary,
                                action: onShare
                            )
                            Button(action: onDone) {
                                Text("Done")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.uberGray3)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                        }

                        Spacer().frame(height: 20)
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.65)) {
                checkmarkScale = 1.0
                checkmarkOpacity = 1.0
            }
        }
    }

    private var spotInfoCard: some View {
        VStack(spacing: 12) {
            if let next = spot.nextCleaningDate {
                infoRow(
                    icon: "calendar.badge.clock",
                    label: "Next cleaning",
                    value: nextCleaningText(next),
                    valueColor: spot.isCleaningSoon ? Color.uberAmber : Color.uberWhite
                )
                Divider().background(Color.white.opacity(0.08))
                infoRow(
                    icon: "clock.arrow.circlepath",
                    label: "Move by",
                    value: spot.moveByDisplay.replacingOccurrences(of: "Move by ", with: ""),
                    valueColor: spot.isCleaningSoon ? Color.uberAmber : Color.uberGreen
                )
            } else {
                infoRow(
                    icon: "calendar.badge.exclamationmark",
                    label: "Schedule",
                    value: "No data found",
                    valueColor: Color.uberGray3
                )
            }

            if !spot.crossStreetFrom.isEmpty || !spot.crossStreetTo.isEmpty {
                Divider().background(Color.white.opacity(0.08))
                infoRow(
                    icon: "arrow.left.and.right",
                    label: "Between",
                    value: "\(spot.crossStreetFrom) & \(spot.crossStreetTo)",
                    valueColor: Color.uberGray2
                )
            }
        }
        .padding(16)
        .background(Color.uberSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.uberGreen.opacity(0.25), lineWidth: 1)
        )
    }

    private func infoRow(icon: String, label: String, value: String, valueColor: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Color.uberGray3)
                .frame(width: 20)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Color.uberGray2)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(valueColor)
        }
    }

    private func nextCleaningText(_ date: Date) -> String {
        let formatter = DateFormatter()
        let days = Calendar.current.dateComponents([.day], from: Date(), to: date).day ?? 0
        if days == 0 {
            formatter.dateFormat = "'Today,' h:mm a"
        } else if days == 1 {
            formatter.dateFormat = "'Tomorrow,' h:mm a"
        } else {
            formatter.dateFormat = "EEE MMM d, h:mm a"
        }
        return formatter.string(from: date)
    }
}
