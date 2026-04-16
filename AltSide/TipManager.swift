import Combine
import StoreKit
import SwiftUI

@MainActor
class TipManager: ObservableObject {
    static let productIDs = ["sweepy_tip_1", "sweepy_tip_5", "sweepy_tip_10"]

    @Published var products: [Product] = []
    @Published var isPurchasing = false
    @Published var purchasedProductID: String?
    @Published var purchaseError: String?
    @Published var loadError: String?

    func loadProducts() async {
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            products = loaded.sorted { $0.price < $1.price }
            if loaded.isEmpty {
                loadError = "No products returned (IDs may not match)"
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func purchase(_ product: Product) async {
        isPurchasing = true
        purchaseError = nil
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    if product.id == "sweepy_tip_10" {
                        UserDefaults.standard.set(true, forKey: "tipPopupSuppressed")
                    }
                    purchasedProductID = product.id
                    await transaction.finish()
                case .unverified:
                    purchaseError = "Purchase could not be verified."
                }
            case .pending, .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseError = "Purchase failed. Please try again."
        }
        isPurchasing = false
    }
}
