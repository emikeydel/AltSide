import CarPlay

/// Scene delegate for the CarPlay screen.
/// Registered in Info.plist under CPTemplateApplicationSceneSessionRoleApplication.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?

    // MARK: - Connection lifecycle

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        CarPlayDataStore.shared.onUpdate = { [weak self] in
            DispatchQueue.main.async { self?.setRootTemplate() }
        }
        setRootTemplate()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        interfaceController = nil
        CarPlayDataStore.shared.onUpdate = nil
    }

    // MARK: - Root template dispatch

    private func setRootTemplate() {
        interfaceController?.setRootTemplate(currentTemplate(), animated: false, completion: nil)
    }

    private func currentTemplate() -> CPInformationTemplate {
        let store = CarPlayDataStore.shared
        switch store.state {
        case .noSpot:
            return noSpotTemplate()
        case let .scouting(streetName, leftLabel, leftSchedule, rightLabel, rightSchedule):
            return scoutTemplate(
                streetName: streetName,
                leftLabel: leftLabel,   leftSchedule: leftSchedule,
                rightLabel: rightLabel, rightSchedule: rightSchedule
            )
        case let .spotSaved(streetName, sideLabel, schedule, nextCleaning, _, leftLabel, rightLabel):
            return spotSavedTemplate(
                streetName: streetName,
                sideLabel: sideLabel,
                schedule: schedule,
                nextCleaning: nextCleaning,
                leftLabel: leftLabel,
                rightLabel: rightLabel
            )
        }
    }

    // MARK: - No spot screen

    private func noSpotTemplate() -> CPInformationTemplate {
        var items: [CPInformationItem] = []
        let asp = CarPlayDataStore.shared.aspSummary
        if !asp.isEmpty {
            items.append(CPInformationItem(title: "ASP Status", detail: asp))
        }
        let findButton = CPTextButton(title: "Find Parking", textStyle: .confirm) { _ in
            CarPlayDataStore.shared.onFindParkingTapped?()
        }
        return CPInformationTemplate(
            title: "Sweepy",
            layout: .leading,
            items: items,
            actions: [findButton]
        )
    }

    // MARK: - Scout mode screen

    private func scoutTemplate(
        streetName: String,
        leftLabel: String, leftSchedule: String,
        rightLabel: String, rightSchedule: String
    ) -> CPInformationTemplate {
        let items: [CPInformationItem] = [
            CPInformationItem(title: leftLabel,  detail: leftSchedule),
            CPInformationItem(title: rightLabel, detail: rightSchedule),
        ]
        let saveLeft = CPTextButton(
            title: "Park \(leftLabel) · \(compactSchedule(leftSchedule))",
            textStyle: .confirm
        ) { _ in CarPlayDataStore.shared.onSaveLeftTapped?() }
        let saveRight = CPTextButton(
            title: "Park \(rightLabel) · \(compactSchedule(rightSchedule))",
            textStyle: .normal
        ) { _ in CarPlayDataStore.shared.onSaveRightTapped?() }
        return CPInformationTemplate(
            title: streetName,
            layout: .leading,
            items: items,
            actions: [saveLeft, saveRight]
        )
    }

    // MARK: - Spot saved screen

    private func spotSavedTemplate(
        streetName: String,
        sideLabel: String,
        schedule: String,
        nextCleaning: String,
        leftLabel: String,
        rightLabel: String
    ) -> CPInformationTemplate {
        var items: [CPInformationItem] = [
            CPInformationItem(title: "Parked on", detail: sideLabel),
        ]
        if !nextCleaning.isEmpty {
            items.append(CPInformationItem(title: "Next cleaning", detail: nextCleaning))
        }
        items.append(CPInformationItem(title: "Schedule", detail: schedule))
        let asp = CarPlayDataStore.shared.aspSummary
        if !asp.isEmpty {
            items.append(CPInformationItem(title: "ASP Status", detail: asp))
        }
        let saveLeft = CPTextButton(title: "Park on \(leftLabel)", textStyle: .confirm) { _ in
            CarPlayDataStore.shared.onSaveLeftTapped?()
        }
        let saveRight = CPTextButton(title: "Park on \(rightLabel)", textStyle: .normal) { _ in
            CarPlayDataStore.shared.onSaveRightTapped?()
        }
        return CPInformationTemplate(
            title: streetName,
            layout: .leading,
            items: items,
            actions: [saveLeft, saveRight]
        )
    }

    // MARK: - Helpers

    /// Returns the first line of a multi-line schedule string in compact form.
    /// "Mon 8:00 – 9:30\nThu 8:00 – 9:30" → "Mon 8–9:30 AM"
    /// "No restrictions" or "—" pass through unchanged.
    private func compactSchedule(_ schedule: String) -> String {
        let first = schedule.components(separatedBy: "\n").first ?? schedule
        guard first != "No restrictions", first != "—", first != "-" else { return first }
        // Suspended lines pass through as-is ("Mon Jun 19 · Suspended ✓").
        if first.contains("Suspended") { return first }
        // Collapse "8:00 – 9:30" → "8–9:30 AM" by stripping :00.
        var compact = first
        compact = compact.replacingOccurrences(of: ":00", with: "")
        compact = compact.replacingOccurrences(of: " – ", with: "–")
        if !compact.contains("AM") && !compact.contains("PM") {
            compact += " AM"
        }
        return compact
    }

    // MARK: - Alert helpers

    private func push(_ template: CPAlertTemplate) {
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }
}
