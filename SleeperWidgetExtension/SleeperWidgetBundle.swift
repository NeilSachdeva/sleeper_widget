import SwiftUI
import WidgetKit

@main
struct SleeperWidgetBundle: WidgetBundle {
    var body: some Widget {
        MatchupLiveActivity()
        MatchupWidget()
    }
}
