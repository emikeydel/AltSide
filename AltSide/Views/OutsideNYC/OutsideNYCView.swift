import SwiftUI
import MapKit

struct OutsideNYCView: View {
    /// Called with a valid NYC coordinate when the user picks a search result.
    let onLocationSelected: (CLLocationCoordinate2D, String) -> Void

    @State private var searchText = ""
    @State private var results: [MKMapItem] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @FocusState private var fieldFocused: Bool

    // NYC region used to bias search results
    private let nycRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
        latitudinalMeters: 60_000, longitudinalMeters: 60_000
    )

    var body: some View {
        ZStack {
            Color.uberBlack.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Top icon
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.uberAmber.opacity(0.12))
                                .frame(width: 80, height: 80)
                            Image(systemName: "location.slash.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(Color.uberAmber)
                        }
                        .padding(.top, 64)

                        Text("Outside Service Area")
                            .font(.system(size: 26, weight: .black))
                            .tracking(-0.8)
                            .foregroundStyle(Color.uberWhite)
                            .multilineTextAlignment(.center)

                        Text("AltSide only works in New York City. It looks like you're outside the service area.\n\nIf this is an error or you're interested in a specific location, enter the NYC address below.")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.uberGray2)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .padding(.horizontal, 8)
                    }
                    .padding(.horizontal, 28)

                    // Search field
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ENTER AN NYC LOCATION")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1.5)
                            .foregroundStyle(Color.uberGray3)
                            .padding(.top, 36)

                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.uberGray3)

                            TextField("Street, neighborhood, or landmark…", text: $searchText)
                                .font(.system(size: 15))
                                .foregroundStyle(Color.uberWhite)
                                .tint(Color.uberGreen)
                                .focused($fieldFocused)
                                .submitLabel(.search)
                                .onSubmit { search() }

                            if !searchText.isEmpty {
                                Button(action: {
                                    searchText = ""
                                    results = []
                                    searchError = nil
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color.uberGray3)
                                }
                            }

                            if isSearching {
                                ProgressView()
                                    .scaleEffect(0.75)
                                    .tint(Color.uberGray3)
                            }
                        }
                        .padding(14)
                        .background(Color.uberSurface2)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(fieldFocused ? Color.uberGreen.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .onChange(of: searchText) { _, text in
                            searchError = nil
                            guard text.count >= 3 else { results = []; return }
                            search()
                        }

                        // Error
                        if let error = searchError {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.circle")
                                    .font(.system(size: 12))
                                Text(error)
                                    .font(.system(size: 12))
                            }
                            .foregroundStyle(Color.uberAmber)
                        }
                    }
                    .padding(.horizontal, 24)

                    // Results list
                    if !results.isEmpty {
                        VStack(spacing: 1) {
                            ForEach(results, id: \.self) { item in
                                resultRow(item)
                            }
                        }
                        .background(Color.uberSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                    }

                    Spacer().frame(height: 60)
                }
            }
        }
        .onAppear { fieldFocused = true }
    }

    // MARK: - Result row

    private func resultRow(_ item: MKMapItem) -> some View {
        let coordinate = item.location.coordinate
        let borough = CleaningDataManager.borough(for: coordinate)
        let inNYC = !borough.isEmpty

        return Button(action: {
            guard inNYC else {
                searchError = "That location isn't in NYC. Try a different address."
                return
            }
            fieldFocused = false
            onLocationSelected(coordinate, borough)
        }) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(inNYC ? Color.uberGreen.opacity(0.12) : Color.uberAmber.opacity(0.1))
                        .frame(width: 34, height: 34)
                    Image(systemName: inNYC ? "mappin.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(inNYC ? Color.uberGreen : Color.uberAmber)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name ?? "Unknown")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(inNYC ? Color.uberWhite : Color.uberGray3)
                    if let addr = item.address?.shortAddress {
                        Text(addr)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.uberGray3)
                    }
                }

                Spacer()

                if inNYC {
                    Text(borough)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Color.uberGreen)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.uberGreen.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Search

    private func search() {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isSearching = true

        let request = MKLocalSearch.Request()
        // Append "New York" to bias results toward NYC
        request.naturalLanguageQuery = "\(searchText), New York"
        request.region = nycRegion
        request.resultTypes = [.address, .pointOfInterest]

        Task {
            do {
                let response = try await MKLocalSearch(request: request).start()
                // Show up to 5 results, prioritising those inside NYC
                let sorted = response.mapItems.sorted { a, b in
                    let aIn = !CleaningDataManager.borough(for: a.location.coordinate).isEmpty
                    let bIn = !CleaningDataManager.borough(for: b.location.coordinate).isEmpty
                    return aIn && !bIn
                }
                results = Array(sorted.prefix(5))
            } catch {
                results = []
            }
            isSearching = false
        }
    }
}
