import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            switch model.stage {
            case .signedOut:
                SignInView()
            case .choosingLeague:
                LeaguePickerView()
            case .ready:
                MatchupView()
            }
        }
        .fontDesign(.rounded)
        .tint(.green)
    }
}
