import SwiftUI
import HabitCore
import HabitStore
import HabitUI

/// Hält die App am Leben, wenn das Fenster zugeht.
///
/// Eine Menüleisten-App, die mit ihrem letzten Fenster stirbt, ist keine —
/// dann wäre das Symbol nach dem ersten Schließen weg. SwiftUI verhält sich mit
/// einer `MenuBarExtra`-Szene vermutlich schon so; ausdrücklich gesagt kostet
/// sechs Zeilen und hängt nicht an einer Vermutung.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct HabitTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
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

    /// Damit die Menüleiste das Fenster wieder aufmachen kann, nachdem man es
    /// geschlossen hat.
    static let mainWindowID = "main"

    static var databaseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base
            .appendingPathComponent("HabitTracker", isDirectory: true)
            .appendingPathComponent("habits.sqlite")
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            ContentView()
                .environment(state)
                .frame(minWidth: 820, minHeight: 560)
                .task {
                    // Erst den Stichtag prüfen: das Fenster kann seit gestern
                    // offen gestanden haben.
                    if await !state.refreshToday() { await state.reload() }
                }
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

        MenuBarExtra {
            MenuBarView().environment(state)
        } label: {
            // Der Fortschritt steht im Symbol selbst — sonst müsste man das
            // Menü aufklappen, nur um zu sehen, ob noch etwas offen ist.
            let progress = state.todaysProgress
            Image(systemName: progress.total > 0 && progress.done == progress.total
                  ? "checkmark.circle.fill" : "checkmark.circle")
            Text(progress.total == 0 ? "" : "\(progress.done)/\(progress.total)")
        }
        // `.window` statt `.menu`: die Zeilen tragen Fortschrittsringe und
        // Zwischentexte, das geht in einem echten NSMenu nicht.
        .menuBarExtraStyle(.window)
    }
}

extension Notification.Name {
    static let newHabitRequested = Notification.Name("newHabitRequested")
}
