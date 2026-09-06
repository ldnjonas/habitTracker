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
            let api = try LocalHabitAPI(url: Self.datenbankURL)
            _state = State(initialValue: AppState(api: api))
        } catch {
            // Ein Zustand ohne Datenbank wäre nicht bedienbar; die App startet
            // trotzdem, damit der Fehler sichtbar wird.
            _state = State(initialValue: AppState(api: try! LocalHabitAPI.inMemory()))
            _startupError = State(initialValue: String(describing: error))
        }
    }

    /// Wo die Datenbank liegt — **die eine Stelle, die es später zu ändern gilt.**
    ///
    /// Heute der Container dieser App. Sobald ein Widget dazukommt, muss die
    /// Datei in einem App-Group-Container liegen, damit beide sie lesen können:
    ///
    ///     FileManager.default.containerURL(
    ///         forSecurityApplicationGroupIdentifier: "group.de.jonasreinhard.habittracker")
    ///
    /// Dann ist es diese eine Zeile und kein Umbau. App Groups brauchen aber
    /// ein bezahltes Entwicklerkonto — deshalb steht hier vorerst der Container.
    static var datenbankURL: URL {
        let basis = FileManager.default.urls(for: .applicationSupportDirectory,
                                             in: .userDomainMask)[0]
        // Auf iOS existiert der Ordner nicht von selbst.
        try? FileManager.default.createDirectory(at: basis, withIntermediateDirectories: true)
        return basis.appendingPathComponent("habits.sqlite")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .task {
                    // Wie auf dem Mac: der Abgleich gehört zum Programmstart und
                    // nicht zu einem einzelnen Bildschirm — er soll auch stehen,
                    // wenn niemand die Einstellungen öffnet.
                    await state.ladeAbgleich()
                    // Erst den Stichtag prüfen: die App kann seit gestern im
                    // Hintergrund gelegen haben.
                    if await !state.refreshToday() { await state.reload() }
                }
                .alert("Datenbank konnte nicht geöffnet werden",
                       isPresented: .constant(startupError != nil)) {
                    Button("OK") { startupError = nil }
                } message: {
                    Text(startupError ?? "")
                }
        }
    }
}

// Keine automatische Sicherung auf dem Telefon. `AutoBackup` liegt in
// `HabitStore` und wäre aufrufbar, aber ein Telefon ist nicht der Ort, an dem
// man Sicherungen aufhebt — und der Server hat den Bestand ohnehin.
