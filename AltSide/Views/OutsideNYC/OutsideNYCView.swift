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
            Color.sweepyBlack.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // SweepyFail illustration
                    Image("SweepyFail")
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .padding(.horizontal, 60)
                        .padding(.top, 60)

                    // Title
                    VStack(spacing: 4) {
                        Text("Oh no!")
                            .font(.system(size: 30, weight: .black))
                            .foregroundStyle(Color.sweepyGreen)
                        Text("Outside Service Area")
                            .font(.system(size: 30, weight: .black))
                            .foregroundStyle(Color.sweepyGreen)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
                    .padding(.horizontal, 28)

                    // Search field
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.sweepyGray3)

                            TextField("Street, neighborhood, or landmark…", text: $searchText)
                                .font(.system(size: 15))
                                .foregroundStyle(Color.sweepyWhite)
                                .tint(Color.sweepyGreen)
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
                                        .foregroundStyle(Color.sweepyGray3)
                                }
                            }

                            if isSearching {
                                ProgressView()
                                    .scaleEffect(0.75)
                                    .tint(Color.sweepyGray3)
                            }
                        }
                        .padding(14)
                        .background(Color.sweepySurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(fieldFocused ? Color.sweepyGreen.opacity(0.5) : Color.sweepyBorder, lineWidth: 1)
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
                            .foregroundStyle(Color.sweepyAmber)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 32)

                    // Results list
                    if !results.isEmpty {
                        VStack(spacing: 1) {
                            ForEach(results, id: \.self) { item in
                                resultRow(item)
                            }
                        }
                        .background(Color.sweepySurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.sweepyBorder, lineWidth: 1)
                        )
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                    }

                    // Tip jar
                    TipJarButton()
                        .padding(.horizontal, 24)
                        .padding(.top, 32)

                    Spacer().frame(height: 40)
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
                        .fill(inNYC ? Color.sweepyGreen.opacity(0.12) : Color.sweepyAmber.opacity(0.1))
                        .frame(width: 34, height: 34)
                    Image(systemName: inNYC ? "mappin.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(inNYC ? Color.sweepyGreen : Color.sweepyAmber)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name ?? "Unknown")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(inNYC ? Color.sweepyWhite : Color.sweepyGray3)
                    if let addr = item.address?.shortAddress {
                        Text(addr)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.sweepyGray3)
                    }
                }

                Spacer()

                if inNYC {
                    Text(borough)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Color.sweepyGreen)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.sweepyGreen.opacity(0.12))
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
        request.naturalLanguageQuery = "\(searchText), New York"
        request.region = nycRegion
        request.resultTypes = [.address, .pointOfInterest]

        Task {
            do {
                let response = try await MKLocalSearch(request: request).start()
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
