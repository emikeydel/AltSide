import SwiftUI

struct UberButton: View {
    let title: String
    var icon: String? = nil
    var style: Style = .primary
    var isLoading: Bool = false
    let action: () -> Void

    enum Style {
        case primary    // green fill, black text
        case secondary  // surface fill, white text, border
        case ghost      // no fill, gray text
        case destructive // red text, no fill
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
        case .secondary:   .uberWhite
        case .ghost:       .uberGray3
        case .destructive: .uberRed
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .primary:     .uberGreen
        case .secondary:   .uberSurface2
        case .ghost:       .clear
        case .destructive: .clear
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary:     .clear
        case .secondary:   Color.uberBorder
        case .ghost:       .clear
        case .destructive: .clear
        }
    }

    private var borderWidth: CGFloat {
        style == .secondary ? 1 : 0
    }
}

#Preview {
    VStack(spacing: 12) {
        UberButton(title: "Save spot here", icon: "location.fill", action: {})
        UberButton(title: "Navigate to car", icon: "arrow.triangle.turn.up.right.circle", style: .secondary, action: {})
        UberButton(title: "Skip reminders", style: .ghost, action: {})
        UberButton(title: "Clear spot", style: .destructive, action: {})
    }
    .padding()
    .background(.black)
}
