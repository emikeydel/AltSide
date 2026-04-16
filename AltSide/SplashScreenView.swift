import SwiftUI

struct SplashScreenView: View {
    @State private var sweepyScale: CGFloat = 0.25

    var body: some View {
        ZStack {
            // Radial gradient background
            RadialGradient(
                colors: [Color(hex: "EAE8E0"), Color(hex: "D2C7BA")],
                center: .center,
                startRadius: 0,
                endRadius: 420
            )
            .ignoresSafeArea()

            VStack {
                Spacer()

                Image("SweepySplash")
                    .resizable()
                    .scaledToFit()
                    .padding(40)
                    .scaleEffect(sweepyScale)

                Spacer()

                Image("LaidOffDadLogo")
                    .resizable()
                    .scaledToFit()
                    .containerRelativeFrame(.horizontal) { w, _ in w * 0.25 }
                    .padding(.bottom, 40)
            }
        }
        .onAppear {
            withAnimation(.timingCurve(0.34, 1.56, 0.64, 1.0, duration: 0.8)) {
                sweepyScale = 1.0
            }
        }
    }
}
