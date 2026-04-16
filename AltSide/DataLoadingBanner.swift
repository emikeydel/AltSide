import SwiftUI

/// Shows while CleaningDataManager is fetching the NYC ASP dataset.
struct DataLoadingBanner: View {
    let progress: Double        // 0.0 – 1.0
    let statusMessage: String
    let hasError: Bool

    @State private var shimmerOffset: CGFloat = -200

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status row
            HStack(spacing: 8) {
                if hasError {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.sweepyAmber)
                } else {
                    // Pulsing dot
                    Circle()
                        .fill(Color.sweepyGreen)
                        .frame(width: 6, height: 6)
                        .scaleEffect(progress < 1 ? 1.2 : 1.0)
                        .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: progress)
                }

                Text(statusMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(hasError ? Color.sweepyAmber : Color.sweepyGray2)

                Spacer()

                if progress > 0 && progress < 1 {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.sweepyGray3)
                }
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.sweepySurface3)
                        .frame(height: 4)

                    if hasError {
                        // Amber bar at whatever progress we reached
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.sweepyAmber.opacity(0.6))
                            .frame(width: geo.size.width * max(0.05, progress), height: 4)
                    } else if progress >= 1 {
                        // Completed — full green bar
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.sweepyGreen)
                            .frame(width: geo.size.width, height: 4)
                    } else {
                        // In-progress — green fill with shimmer
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.sweepyGreen)
                            .frame(width: geo.size.width * max(0.05, progress), height: 4)
                            .overlay(
                                // Shimmer sweep
                                LinearGradient(
                                    colors: [.clear, .white.opacity(0.35), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: 80)
                                .offset(x: shimmerOffset)
                                .clipped()
                            )
                            .clipped()
                            .onAppear {
                                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                                    shimmerOffset = 300
                                }
                            }
                    }
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.sweepySurface2)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    hasError ? Color.sweepyAmber.opacity(0.3) : Color.sweepyGreen.opacity(0.2),
                    lineWidth: 1
                )
        )
        .animation(.easeInOut(duration: 0.3), value: progress)
        .animation(.easeInOut(duration: 0.3), value: hasError)
    }
}
