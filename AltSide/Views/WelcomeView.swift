import SwiftUI

struct WelcomeView: View {
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.uberBlack.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {

                Spacer()

                // Wordmark
                VStack(alignment: .leading, spacing: 8) {
                    Text("AltSide")
                        .font(.system(size: 48, weight: .black))
                        .tracking(-1.5)
                        .foregroundStyle(Color.uberWhite)

                    Text("Never forget to move your car.")
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(Color.uberGreen)
                }

                Spacer().frame(height: 32)

                // Description
                Text("AltSide tracks NYC alternate side parking schedules so you know exactly when street cleaning hits your block — and reminds you before the sweeper arrives.")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.uberGray2)
                    .lineSpacing(4)

                Spacer().frame(height: 36)

                // Feature list
                VStack(alignment: .leading, spacing: 16) {
                    featureRow(icon: "location.fill",
                               color: Color.uberGreen,
                               text: "Save your spot with one tap")
                    featureRow(icon: "bell.fill",
                               color: Color.uberAmber,
                               text: "Get reminders before the sweeper comes")
                    featureRow(icon: "checkmark.shield.fill",
                               color: Color.uberGreen,
                               text: "See suspension updates when street cleaning is cancelled where you're parked")
                    featureRow(icon: "dot.radiowaves.left.and.right",
                               color: Color(hex: "5B8DEF"),
                               text: "Scout nearby streets for the best side to park")
                }

                Spacer()

                // CTA
                UberButton(title: "Get started", action: onDismiss)
                    .padding(.bottom, 40)
            }
            .padding(.horizontal, 28)
        }
    }

    private func featureRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(color)
            }
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Color.uberGray2)
        }
    }
}
