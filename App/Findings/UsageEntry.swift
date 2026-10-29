// Every route to Usage passes here before the dashboard can create its model, restore cached data or start polling.
import SwiftUI
import UIKit

struct UsageEntry: View {
    var body: some View {
        if UIDevice.current.userInterfaceIdiom != .phone {
            UsageScreen()
        }
    }
}
