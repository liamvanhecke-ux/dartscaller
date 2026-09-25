import SwiftUI
import SwiftData

@main
struct DartsCallerApp: App {
    @State private var camera = CameraSystem()
    @State private var audio = CallerAudioManager()
    @State private var learning = LearningCenter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(camera)
                .environment(audio)
                .environment(learning)
        }
        .modelContainer(for: Player.self)
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            NavigationStack { NewGameView() }
                .tabItem { Label("Spelen", systemImage: "target") }
            NavigationStack { PlayersView() }
                .tabItem { Label("Spelers", systemImage: "person.2") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Instellingen", systemImage: "gearshape") }
        }
    }
}
