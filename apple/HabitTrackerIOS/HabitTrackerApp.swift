import SwiftUI
import HabitCore
import HabitStore
import HabitUI

@main
struct HabitTrackerApp: App {
    @Environment(\.scenePhase) private var scenePhase
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
                    await holeNach()
                }
                // Ein Telefon läuft nicht, es wird aufgeweckt. Ohne diesen
                // Auslöser bliebe Abgehaktes hier liegen, bis jemand von Hand
                // abgleicht — und fehlte damit auch in der täglichen Sicherung,
                // die der Mac aus dem Serverstand schreibt.
                .onChange(of: scenePhase) { _, neu in
                    guard neu == .active else { return }
                    Task { await holeNach() }
                }
                .alert("Datenbank konnte nicht geöffnet werden",
                       isPresented: .constant(startupError != nil)) {
                    Button("OK") { startupError = nil }
                } message: {
                    Text(startupError ?? "")
                }
        }
    }

    /// Stichtag nachziehen, dann abgleichen — beim Start und bei jeder Rückkehr.
    ///
    /// Den Mindestabstand bringt `syncWennFaellig` mit: zwischen zwei Blicken
    /// aufs Telefon liegen manchmal zehn Sekunden, und die sind kein Anlass,
    /// erneut übers Netz zu gehen.
    private func holeNach() async {
        if await !state.refreshToday() { await state.reload() }
        await state.syncWennFaellig()
    }
}

// Keine automatische Sicherung auf dem Telefon. `AutoBackup` liegt in
// `HabitStore` und wäre aufrufbar, aber ein Telefon ist nicht der Ort, an dem
// man Sicherungen aufhebt — und der Server hat den Bestand ohnehin.
