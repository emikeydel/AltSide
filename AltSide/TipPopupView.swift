import SwiftUI
import StoreKit

struct TipPopupView: View {
    @StateObject private var tipManager = TipManager()
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProductID: String?
    @State private var showThankYou = false

    var body: some View {
        ZStack {
            Color.sweepyBlack.ignoresSafeArea()

            VStack(spacing: 0) {
                if showThankYou {
                    thankYouView
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else {
                    mainContent
                        .transition(.opacity)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
        .task { await tipManager.loadProducts() }
        .onChange(of: tipManager.purchasedProductID) { _, id in
            guard id != nil else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                showThankYou = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { dismiss() }
        }
    }

    // MARK: - Main

    private var mainContent: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 6) {
                Text("☕")
                    .font(.system(size: 38))
                Text("Enjoying Sweepy?")
                    .font(.system(size: 22, weight: .black))
                    .tracking(-0.6)
                    .foregroundStyle(Color.sweepyWhite)
                Text("Help keep the app running")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.sweepyGray3)
            }

            // Amount cards
            if tipManager.products.isEmpty {
                if let loadError = tipManager.loadError {
                    Text("Could not load tips: \(loadError)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.sweepyAmber)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                    Button("Retry") {
                        Task { await tipManager.loadProducts() }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.sweepyGreen)
                } else {
                    HStack(spacing: 10) {
                        staticTipCard(price: "$0.99", label: "Quick thanks", productID: "sweepy_tip_1")
                        staticTipCard(price: "$4.99", label: "You rock!", productID: "sweepy_tip_5")
                        staticTipCard(price: "$9.99", label: "Super fan", productID: "sweepy_tip_10")
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ForEach(tipManager.products, id: \.id) { product in
                        tipCard(product)
                    }
                }
            }

            if let error = tipManager.purchaseError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sweepyAmber)
                    .multilineTextAlignment(.center)
            }

            Button(action: { dismiss() }) {
                Text("No thanks")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.sweepyGray3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
        }
    }

    // MARK: - Thank You

    private var thankYouView: some View {
        VStack(spacing: 12) {
            Text("🧡")
                .font(.system(size: 52))
            Text("Thank you!")
                .font(.system(size: 28, weight: .black))
                .tracking(-0.8)
                .foregroundStyle(Color.sweepyWhite)
            Text("Your support keeps Sweepy going.")
                .font(.system(size: 14))
                .foregroundStyle(Color.sweepyGray3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Static Fallback Card (shown when StoreKit products haven't loaded)

    private func tipImage(for productID: String) -> String {
        switch productID {
        case "sweepy_tip_1":  return "TipCoin1"
        case "sweepy_tip_5":  return "TipCoin2"
        case "sweepy_tip_10": return "TipCoin3"
        default: return "TipCoin1"
        }
    }

    @ViewBuilder
    private func staticTipCard(price: String, label: String, productID: String) -> some View {
        VStack(spacing: 6) {
            Image(tipImage(for: productID))
                .resizable()
                .scaledToFit()
                .frame(height: 44)
            Text(price)
                .font(.system(size: 18, weight: .black))
                .tracking(-0.5)
                .foregroundStyle(Color.sweepyWhite)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.sweepyGray2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 110)
        .padding(.vertical, 14)
        .background(Color.sweepySurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.sweepyBorder, lineWidth: 1)
        )
        .overlay(alignment: .top) {
            if productID == "sweepy_tip_10" {
                Text("no more popups")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.sweepyGreen)
                    .clipShape(Capsule())
                    .offset(y: -10)
            }
        }
    }

    // MARK: - Tip Card

    @ViewBuilder
    private func tipCard(_ product: Product) -> some View {
        let isPurchasing = tipManager.isPurchasing && selectedProductID == product.id

        Button(action: {
            guard !tipManager.isPurchasing else { return }
            selectedProductID = product.id
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            Task { await tipManager.purchase(product) }
        }) {
            VStack(spacing: 6) {
                if isPurchasing {
                    ProgressView()
                        .tint(Color.sweepyWhite)
                        .frame(height: 44)
                } else {
                    Image(tipImage(for: product.id))
                        .resizable()
                        .scaledToFit()
                        .frame(height: 44)
                    Text(product.displayPrice)
                        .font(.system(size: 18, weight: .black))
                        .tracking(-0.5)
                        .foregroundStyle(Color.sweepyWhite)
                }
                Text(tipLabel(for: product.id))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.sweepyGray2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 110)
            .padding(.vertical, 14)
            .background(Color.sweepySurface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.sweepyBorder, lineWidth: 1)
            )
            .overlay(alignment: .top) {
                if product.id == "sweepy_tip_10" {
                    Text("no more popups")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.sweepyGreen)
                        .clipShape(Capsule())
                        .offset(y: -10)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(tipManager.isPurchasing)
        .scaleEffect(isPurchasing ? 0.96 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPurchasing)
    }

    private func tipLabel(for id: String) -> String {
        switch id {
        case "sweepy_tip_1":  return "Quick thanks"
        case "sweepy_tip_5":  return "You rock!"
        case "sweepy_tip_10": return "Super fan"
        default: return ""
        }
    }
}
