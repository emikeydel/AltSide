import SwiftUI
import MessageUI
import ContactsUI

struct ShareSpotView: View {
    let spot: ParkingSpot
    let onDone: () -> Void

    @State private var showMessageCompose = false
    @State private var showShareSheet = false
    @State private var showContactPicker = false
    @State private var canSendText = MFMessageComposeViewController.canSendText() || ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil
    @State private var selectedName: String?
    @State private var selectedPhone: String?

    @AppStorage("lastShareContactName") private var lastShareContactName = ""
    @AppStorage("lastShareContactPhone") private var lastShareContactPhone = ""

    private var hasLastContact: Bool { !lastShareContactName.isEmpty }

    var body: some View {
        ZStack {
            Color.uberBlack.ignoresSafeArea()

            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.uberGray3.opacity(0.5))
                    .frame(width: 36, height: 4)
                    .padding(.top, 12)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {

                        // Header
                        VStack(alignment: .leading, spacing: 6) {
                            Text("SHARE YOUR SPOT")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1.5)
                                .foregroundStyle(Color.uberGray3)
                                .padding(.top, 20)
                            Text("Let someone know\nwhere you parked")
                                .font(.system(size: 26, weight: .black))
                                .tracking(-0.8)
                                .foregroundStyle(Color.uberWhite)
                        }

                        // Recipient section
                        recipientSection

                        // Message preview card
                        messagePreviewCard

                        // Actions
                        VStack(spacing: 10) {
                            if canSendText {
                                UberButton(
                                    title: selectedName != nil ? "Send to \(selectedName!)" : "Send via iMessage",
                                    icon: "message.fill",
                                    action: { showMessageCompose = true }
                                )
                            }
                            UberButton(
                                title: "More options",
                                icon: "square.and.arrow.up",
                                style: .secondary,
                                action: { showShareSheet = true }
                            )
                            Button(action: onDone) {
                                Text("Skip")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.uberGray3)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            }
                        }

                        Spacer().frame(height: 20)
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .onAppear {
            if hasLastContact && selectedName == nil {
                selectedName = lastShareContactName
                selectedPhone = lastShareContactPhone
            }
        }
        .sheet(isPresented: $showMessageCompose) {
            MessageComposeView(recipients: selectedPhone.map { [$0] } ?? [], body: shareMessage, onDismiss: { showMessageCompose = false })
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityView(text: shareMessage)
        }
        .sheet(isPresented: $showContactPicker) {
            ContactPickerView { name, phone in
                selectedName = name
                selectedPhone = phone
                lastShareContactName = name
                lastShareContactPhone = phone
                if canSendText { showMessageCompose = true }
            }
        }
    }

    // MARK: - Recipient Section

    @ViewBuilder
    private var recipientSection: some View {
        if let name = selectedName {
            // Contact selected — show name with change/clear options
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.uberGreen.opacity(0.15)).frame(width: 36, height: 36)
                        Text(name.prefix(1).uppercased())
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.uberGreen)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.uberWhite)
                        if hasLastContact && name == lastShareContactName {
                            Text("Recent")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.uberGray3)
                        }
                    }
                    Spacer()
                    Button(action: { showContactPicker = true }) {
                        Text("Change")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.uberGray2)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.uberSurface2)
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.uberSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.uberGreen.opacity(0.3), lineWidth: 1)
                )
            }
        } else {
            // No contact — show picker prompt
            Button(action: { showContactPicker = true }) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(Color.uberSurface2).frame(width: 36, height: 36)
                        Image(systemName: "person.fill.badge.plus")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.uberGray2)
                    }
                    Text("Choose who to send to")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.uberGray2)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.uberGray3)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.uberSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Message Content

    private var shareMessage: String {
        var lines: [String] = []
        lines.append("📍 Parked on \(spot.streetName)")
        if let side = spot.streetSide {
            lines.append("\(side.displayName) side")
        }
        if !spot.crossStreetFrom.isEmpty && !spot.crossStreetTo.isEmpty {
            lines.append("Between \(spot.crossStreetFrom) & \(spot.crossStreetTo)")
        }
        if let next = spot.nextCleaningDate {
            let fmt = DateFormatter()
            fmt.dateFormat = "EEE MMM d 'at' h:mm a"
            lines.append("⚠️ Street cleaning: \(fmt.string(from: next))")
            let moveBy = next.addingTimeInterval(-60)
            fmt.dateFormat = "EEE MMM d 'at' h:mm a"
            lines.append("Move by \(fmt.string(from: moveBy))")
        }
        lines.append("maps://?ll=\(spot.latitude),\(spot.longitude)&q=My+Car")
        return lines.joined(separator: "\n")
    }

    // MARK: - Message Preview Card

    private var messagePreviewCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // "Phone" chrome header
            HStack {
                Text("iMessage")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.uberGray3)
                Spacer()
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.uberGray3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.uberSurface3)

            // Bubble
            HStack(alignment: .bottom, spacing: 8) {
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    messageBubble
                    Text("Delivered")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.uberGray3)
                }
            }
            .padding(14)
        }
        .background(Color.uberSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var messageBubble: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "car.fill")
                    .font(.system(size: 11))
                Text(spot.streetName)
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(.white)

            if let side = spot.streetSide {
                Text("\(side.displayName) side")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
            }

            if !spot.crossStreetFrom.isEmpty && !spot.crossStreetTo.isEmpty {
                Text("Between \(spot.crossStreetFrom) & \(spot.crossStreetTo)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            }

            if let next = spot.nextCleaningDate {
                Divider().background(Color.white.opacity(0.2))
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.uberAmber)
                    Text(spot.moveByDisplay)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.uberAmber)
                }
                let _ = next // suppress unused warning
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(hex: "1B7FE3")) // iMessage blue
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 18, bottomLeadingRadius: 18,
                bottomTrailingRadius: 4, topTrailingRadius: 18
            )
        )
        .frame(maxWidth: 240, alignment: .trailing)
    }
}

// MARK: - MFMessageComposeViewController wrapper

struct MessageComposeView: UIViewControllerRepresentable {
    let recipients: [String]
    let body: String
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.recipients = recipients.isEmpty ? nil : recipients
        vc.body = body
        vc.messageComposeDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            controller.dismiss(animated: true)
            onDismiss()
        }
    }
}

// MARK: - CNContactPickerViewController wrapper

struct ContactPickerView: UIViewControllerRepresentable {
    let onSelect: (String, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let vc = CNContactPickerViewController()
        vc.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: CNContactPickerViewController, context: Context) {}

    class Coordinator: NSObject, CNContactPickerDelegate {
        let onSelect: (String, String) -> Void
        init(onSelect: @escaping (String, String) -> Void) { self.onSelect = onSelect }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
            guard let phoneNumber = contactProperty.value as? CNPhoneNumber else { return }
            let name = [contactProperty.contact.givenName, contactProperty.contact.familyName]
                .filter { !$0.isEmpty }.joined(separator: " ")
            onSelect(name, phoneNumber.stringValue)
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {}
    }
}

// MARK: - UIActivityViewController wrapper

struct ActivityView: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
