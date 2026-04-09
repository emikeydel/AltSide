import SwiftUI

struct TipJarButton: View {
    // TODO: Replace with your actual tip jar URL (Ko-fi, Buy Me a Coffee, etc.)
    private let tipURL = URL(string: "https://ko-fi.com/altside")!

    var body: some View {
        Link(destination: tipURL) {
            HStack(spacing: 8) {
                Text("☕")
                    .font(.system(size: 14))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Enjoying AltSide?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.uberWhite)
                    Text("Leave a tip to support the app")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.uberGray3)
                }
                Spacer()
                Image(systemName: "heart.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "FF6B6B"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.uberSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.uberBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
