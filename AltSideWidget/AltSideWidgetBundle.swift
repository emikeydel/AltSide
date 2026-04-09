import WidgetKit
import SwiftUI

@main
struct AltSideWidgetBundle: WidgetBundle {
    var body: some Widget {
        ParkingLockScreenWidget()
        ParkingLiveActivityWidget()
    }
}
