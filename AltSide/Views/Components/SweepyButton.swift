import SwiftUI

struct SweepyButton: View {
    let title: String
    var icon: String? = nil
    var style: Style = .primary
    var isLoading: Bool = false
    let action: () -> Void

    enum Style {
        case primary     // green fill, black text
        case secondary   // surface fill, white text, border
        case ghost       // no fill, gray text
        case destructive // red text, no fill
        case dark        // black fill, white text
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(foregroundColor)
                        .scaleEffect(0.8)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .bold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(-0.3)
            }
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
        }
        .disabled(isLoading)
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:     .white
        case .secondary:   .sweepyWhite
        case .ghost:       .sweepyGray3
        case .destructive: .sweepyRed
        case .dark:        .white
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .primary:     .sweepyGreen
        case .secondary:   .sweepySurface2
        case .ghost:       .clear
        case .destructive: .clear
        case .dark:        Color(hex: "111111")
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary:     .clear
        case .secondary:   Color.sweepyBorder
        case .ghost:       .clear
        case .destructive: .clear
        case .dark:        .clear
        }
    }

    private var borderWidth: CGFloat {
        style == .secondary ? 1 : 0
    }
}

#Preview {
    VStack(spacing: 12) {
        SweepyButton(title: "Save spot here", icon: "location.fill", action: {})
        SweepyButton(title: "Navigate to car", icon: "arrow.triangle.turn.up.right.circle", style: .secondary, action: {})
        SweepyButton(title: "Skip reminders", style: .ghost, action: {})
        SweepyButton(title: "Clear spot", style: .destructive, action: {})
    }
    .padding()
    .background(.black)
}
