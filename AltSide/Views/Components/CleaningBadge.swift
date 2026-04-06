import SwiftUI

struct CleaningBadge: View {
    enum BadgeState {
        case cleaningSoon(daysUntil: Int)
        case safe(daysUntil: Int)
        case activeNow
        case suspended(reason: String)
    }

    let state: BadgeState

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(label)
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(borderColor, lineWidth: 1)
        )
    }

    private var label: String {
        switch state {
        case .cleaningSoon(let days):
            switch days {
            case 0:  return "Move today"
            case 1:  return "Move tomorrow"
            default: return "Move in \(days) days"
            }
        case .safe(let days):
            switch days {
            case 0:  return "Safe today"
            case 1:  return "Safe for 1 day"
            default: return "Safe for \(days) days"
            }
        case .activeNow:
            return "Cleaning now!"
        case .suspended(let reason):
            return "Suspended · \(reason)"
        }
    }

    private var icon: String {
        switch state {
        case .cleaningSoon, .activeNow: return "exclamationmark.triangle.fill"
        case .safe:                     return "checkmark.circle.fill"
        case .suspended:                return "party.popper.fill"
        }
    }

    private var foregroundColor: Color {
        switch state {
        case .cleaningSoon, .activeNow: return .uberAmber
        case .safe, .suspended:         return .uberGreen
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .cleaningSoon, .activeNow: return .uberAmberDim
        case .safe, .suspended:         return .uberGreenDim
        }
    }

    private var borderColor: Color {
        switch state {
        case .cleaningSoon, .activeNow: return .uberAmber.opacity(0.3)
        case .safe, .suspended:         return .uberGreen.opacity(0.3)
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        CleaningBadge(state: .cleaningSoon(daysUntil: 1))
        CleaningBadge(state: .safe(daysUntil: 3))
        CleaningBadge(state: .activeNow)
        CleaningBadge(state: .suspended(reason: "Labor Day"))
    }
    .padding()
    .background(.black)
}
