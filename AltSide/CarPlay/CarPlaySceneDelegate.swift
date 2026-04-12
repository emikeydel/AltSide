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
        case let .spotSaved(streetName, sideLabel, schedule, nextCleaning, _):
            return spotSavedTemplate(
                streetName: streetName,
                sideLabel: sideLabel,
                schedule: schedule,
                nextCleaning: nextCleaning
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

    // MARK: - Spot saved screen

    private func spotSavedTemplate(
        streetName: String,
        sideLabel: String,
        schedule: String,
        nextCleaning: String
    ) -> CPInformationTemplate {
        var items: [CPInformationItem] = [
            CPInformationItem(title: "Parked on", detail: sideLabel),
            CPInformationItem(title: "Cleaning",  detail: schedule),
        ]
        if !nextCleaning.isEmpty {
            items.append(CPInformationItem(title: "Move by", detail: nextCleaning))
        }
        let asp = CarPlayDataStore.shared.aspSummary
        if !asp.isEmpty {
            items.append(CPInformationItem(title: "ASP Status", detail: asp))
        }
        let parkAgain = CPTextButton(title: "Park Again", textStyle: .cancel) { [weak self] _ in
            self?.presentParkAgainAlert()
        }
        let reminders = CPTextButton(title: "Set Reminders", textStyle: .normal) { [weak self] _ in
            self?.presentRemindersAlert()
        }
        let share = CPTextButton(title: "Share", textStyle: .normal) { [weak self] _ in
            self?.presentShareAlert()
        }
        return CPInformationTemplate(
            title: streetName,
            layout: .leading,
            items: items,
            actions: [parkAgain, reminders, share]
        )
    }

    // MARK: - Alert helpers

    private func presentParkAgainAlert() {
        let confirm = CPAlertAction(title: "Park Again", style: .default) { [weak self] _ in
            CarPlayDataStore.shared.onParkAgainConfirmed?()
            self?.interfaceController?.popTemplate(animated: true, completion: nil)
        }
        let cancel = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.interfaceController?.popTemplate(animated: true, completion: nil)
        }
        push(CPAlertTemplate(titleVariants: ["Clear your saved spot?"], actions: [confirm, cancel]))
    }

    private func presentRemindersAlert() {
        let set = CPAlertAction(title: "Set Reminder", style: .default) { [weak self] _ in
            CarPlayDataStore.shared.onSetRemindersConfirmed?()
            self?.interfaceController?.popTemplate(animated: true, completion: nil)
        }
        let cancel = CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.interfaceController?.popTemplate(animated: true, completion: nil)
        }
        push(CPAlertTemplate(titleVariants: ["Remind me before street cleaning?"], actions: [set, cancel]))
    }

    private func presentShareAlert() {
        let ok = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.interfaceController?.popTemplate(animated: true, completion: nil)
        }
        push(CPAlertTemplate(
            titleVariants: ["Open Sweepy on your iPhone to share this spot."],
            actions: [ok]
        ))
    }

    private func push(_ template: CPAlertTemplate) {
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }
}
