import SwiftUI

@main
struct WordHuntLiveApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Word Hunt Live", id: "main") {
            MainView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 460, minHeight: 720)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 520, height: 860)

        Settings {
            SettingsView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}
