import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - Widget Entry Point

struct ParkingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ParkingActivityAttributes.self) { context in
            // Lock Screen & StandBy
            ParkingLockScreenView(state: context.state)
                .activityBackgroundTint(Color(red: 0.918, green: 0.910, blue: 0.878)) // #EAE8E0
        } dynamicIsland: { context in
            DynamicIsland {
                // ── Expanded (long press) ──────────────────────────────
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "car.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(accentColor(context.state))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(context.state.streetName)
                                .font(.system(size: 14, weight: .black))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if !context.state.sideDisplayName.isEmpty {
                                Text(context.state.sideDisplayName + " side")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if let date = context.state.cleaningDate {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(date, style: .relative)
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundStyle(accentColor(context.state))
                                .multilineTextAlignment(.trailing)
                            Text("remaining")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .tracking(0.5)
                        }
                        .padding(.trailing, 4)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                        Text(context.state.moveByDisplay)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                        Spacer()
                        if context.state.isCleaningSoon {
                            Label("Move soon", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(red: 1, green: 0.369, blue: 0)) // #FF5E00
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(red: 0.102, green: 0.102, blue: 0.102)) // #1A1A1A
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                }

            } compactLeading: {
                // ── Compact Leading ────────────────────────────────────
                HStack(spacing: 4) {
                    Image(systemName: "car.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accentColor(context.state))
                    Text(context.state.streetName)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
                .padding(.leading, 4)

            } compactTrailing: {
                // ── Compact Trailing ───────────────────────────────────
                if let date = context.state.cleaningDate {
                    Text(date, style: .timer)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(accentColor(context.state))
                        .monospacedDigit()
                        .padding(.trailing, 4)
                }

            } minimal: {
                // ── Minimal (two activities competing) ────────────────
                if let date = context.state.cleaningDate {
                    ZStack {
                        Circle()
                            .fill(accentColor(context.state).opacity(0.15))
                        Image(systemName: context.state.isCleaningSoon
                              ? "exclamationmark.triangle.fill"
                              : "car.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(accentColor(context.state))
                    }
                    .accessibilityLabel(Text(date, style: .relative))
                }
            }
        }
    }

    private func accentColor(_ state: ParkingActivityAttributes.ContentState) -> Color {
        state.isCleaningSoon
            ? Color(red: 1, green: 0.369, blue: 0)       // #FF5E00
            : Color(red: 0.176, green: 0.702, blue: 0.286) // #2DB349
    }
}

// MARK: - Lock Screen / StandBy View

struct ParkingLockScreenView: View {
    let state: ParkingActivityAttributes.ContentState

    private var accent: Color {
        state.isCleaningSoon
            ? Color(red: 1, green: 0.369, blue: 0)
            : Color(red: 0.176, green: 0.702, blue: 0.286)
    }

    var body: some View {
        HStack(spacing: 16) {
            // Left: car icon circle
            ZStack {
                Circle()
                    .fill(accent.opacity(0.12))
                    .frame(width: 52, height: 52)
                Image(systemName: "car.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(accent)
            }

            // Centre: street info + move by
            VStack(alignment: .leading, spacing: 3) {
                Text(state.streetName)
                    .font(.system(size: 17, weight: .black))
                    .foregroundStyle(Color(red: 0.102, green: 0.102, blue: 0.102))
                    .lineLimit(1)

                if !state.sideDisplayName.isEmpty {
                    Text(state.sideDisplayName + " side")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 0.533, green: 0.533, blue: 0.533))
                }

                // Move by pill
                HStack(spacing: 5) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 10))
                    Text(state.moveByDisplay)
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(red: 0.102, green: 0.102, blue: 0.102))
                .clipShape(Capsule())
                .padding(.top, 2)
            }

            Spacer()

            // Right: countdown
            if let date = state.cleaningDate {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(date, style: .relative)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                    Text("left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(red: 0.533, green: 0.533, blue: 0.533))
                        .textCase(.uppercase)
                        .tracking(0.5)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
