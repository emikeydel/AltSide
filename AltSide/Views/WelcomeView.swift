import SwiftUI

struct WelcomeView: View {
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.sweepyBlack.ignoresSafeArea()

            VStack(spacing: 0) {

                // Sweepy + wordmark
                Image("SweepySplash")
                    .resizable()
                    .scaledToFit()
                    .padding(.horizontal, 40)
                    .padding(.top, 40)

                Spacer().frame(height: 20)

                // Tagline
                Text("Never forget to move your car.")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.sweepyWhite)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                Spacer().frame(height: 12)

                // Description
                Text("Sweepy tracks NYC alternate side parking schedules so you know exactly when street cleaning hits your block. Set alerts before the sweeper arrives or when rules are suspended.")
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(Color.sweepyGray2)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 28)

                Spacer().frame(height: 28)

                // Feature list
                VStack(spacing: 12) {
                    featureRow(icon: "location.fill",
                               text: "Save your spot with one tap")
                    featureRow(icon: "bell.fill",
                               text: "Reminders before the sweeper comes")
                    featureRow(icon: "checkmark.shield.fill",
                               text: "Alerts when parking is suspended")
                    featureRow(icon: "dot.radiowaves.left.and.right",
                               text: "Find nearby streets with the best spots")
                }
                .padding(.horizontal, 28)

                Spacer()

                SweepyButton(title: "Let's go!", action: onDismiss)
                    .padding(.horizontal, 28)

                TipJarButton()
                    .padding(.horizontal, 28)
                    .padding(.top, 12)

                Link("Questions? support@sweepy.site", destination: URL(string: "mailto:support@sweepy.site")!)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color.sweepyGray3)
                    .padding(.top, 12)
                    .padding(.bottom, 40)
            }
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(hex: "1A1A1A"))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text(text)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.sweepyGray2)
            Spacer()
        }
    }
}
