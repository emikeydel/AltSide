import SwiftUI

/// Standard logo header used at the top of all modal cards.
/// Replaces the plain drag handle with the AltSide wordmark.
struct CardHeader: View {
    var body: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color.sweepyGray3.opacity(0.5))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 12)

            // Wordmark
            Image("AltSideLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 56)
                .padding(.bottom, 8)
        }
    }
}
