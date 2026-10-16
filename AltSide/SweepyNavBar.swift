import SwiftUI

/// The app's main nav — drawn once by `MainMapView` above every scene (Home, the park map,
/// Scout mode, the saved-spot screen) so Home is always in the same place.
struct SweepyNavBar: View {
    enum Tab { case home, parking }

    let selected: Tab
    /// True when a spot is saved — the second tab becomes "My car" instead of "Park".
    let hasSavedSpot: Bool
    let onSelect: (Tab) -> Void
    let onHelp: () -> Void

    /// Height scenes reserve at the top so content isn't hidden under the bar.
    static let height: CGFloat = 52

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                tabButton(.home, title: "Home", icon: "house.fill")
                tabButton(.parking,
                          title: hasSavedSpot ? "My car" : "Park",
                          icon: hasSavedSpot ? "car.fill" : "mappin.and.ellipse")
            }
            .padding(4)
            .background(Color.sweepySurface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.sweepyBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)

            Spacer()

            Button(action: onHelp) {
                Image(systemName: "questionmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.sweepyGray2)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.sweepySurface))
                    .overlay(Circle().strokeBorder(Color.sweepyBorder, lineWidth: 1))
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
            }
            .accessibilityLabel("Help")
        }
        .padding(.horizontal, 16)
        .frame(height: Self.height)
    }

    private func tabButton(_ tab: Tab, title: String, icon: String) -> some View {
        let isSelected = tab == selected
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSelect(tab)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(-0.3)
            }
            .foregroundStyle(isSelected ? Color.white : Color.sweepyGray2)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.sweepyWhite : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
