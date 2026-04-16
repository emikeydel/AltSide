import SwiftUI

struct TipJarButton: View {
    @State private var showTipPopup = false

    var body: some View {
        Button(action: { showTipPopup = true }) {
            HStack(spacing: 8) {
                Text("☕")
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Enjoying Sweepy?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.sweepyWhite)
                    Text("Leave a tip to support the app")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.sweepyGray3)
                }
                Spacer()
                Image(systemName: "heart.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "FF6B6B"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.sweepySurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.sweepyBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showTipPopup) {
            TipPopupView()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }
}
