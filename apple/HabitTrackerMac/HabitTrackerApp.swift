import SwiftUI
import HabitCore
import HabitStore
import HabitUI

@main
struct HabitTrackerApp: App {
    @State private var state: AppState
    /// Wenn die Datenbank nicht aufgeht, wird das gezeigt statt still zu scheitern.
    @State private var startupError: String?

    init() {
        do {
            let api = try LocalHabitAPI(url: Self.databaseURL)
            _state = State(initialValue: AppState(api: api))
        } catch {
            // Ein Zustand ohne Datenbank wäre nicht bedienbar; die App startet
            // trotzdem, damit der Fehler sichtbar wird.
            _state = State(initialValue: AppState(api: try! LocalHabitAPI.inMemory()))
            _startupError = State(initialValue: String(describing: error))
        }
    }

    static var databaseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base
            .appendingPathComponent("HabitTracker", isDirectory: true)
            .appendingPathComponent("habits.sqlite")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(state)
                .frame(minWidth: 820, minHeight: 560)
                .task { await state.reload() }
                .alert("Datenbank konnte nicht geöffnet werden",
                       isPresented: .constant(startupError != nil)) {
                    Button("OK") { startupError = nil }
                } message: {
                    Text(startupError ?? "")
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Neuer Habit …") {
                    NotificationCenter.default.post(name: .newHabitRequested, object: nil)
                }
                .keyboardShortcut("n")
            }
        }
    }
}

extension Notification.Name {
    static let newHabitRequested = Notification.Name("newHabitRequested")
}
