import Foundation
import HabitCore

/// Legt ohne Zutun einmal am Tag eine Sicherung an.
///
/// **Wogegen das hilft und wogegen nicht.** Es schützt vor Fehlern der App und
/// vor eigenen: ein versehentlich gelöschter Habit, ein Abgleich, der etwas
/// überschreibt, eine Datenbank, die nicht mehr aufgeht. Es schützt **nicht**
/// vor dem Verlust der Festplatte — die Dateien liegen neben der Datenbank.
/// Wer das auch abdecken will, richtet Time Machine auf den Ordner oder kopiert
/// ihn gelegentlich weg; deshalb ist er über die Oberfläche erreichbar und
/// nicht versteckt.
///
/// Nur die Mac-App startet das. Der Server hat seine eigene Datei, und ein
/// Telefon ist nicht der Ort, an dem man Sicherungen aufhebt.
public enum AutoBackup {

    /// Wie eine Runde ausgegangen ist.
    public enum Ergebnis: Sendable, Equatable {
        /// Die Datei des Tages steht — neu angelegt oder auf den neuen Stand
        /// gebracht.
        case geschrieben(URL)
        /// Seit der letzten Sicherung hat sich nichts geändert.
        ///
        /// Dann wird nichts geschrieben. Eine Reihe gleicher Dateien sagt
        /// nichts aus, die man nicht schon an ihrem Alter ablesen könnte — und
        /// sie verdrängt beim Aufräumen die Stände, die sich unterscheiden.
        case unveraendert(seit: URL)
        /// Ausgeschaltet.
        case aus

        public var url: URL? {
            switch self {
            case .geschrieben(let url), .unveraendert(let url): url
            case .aus: nil
            }
        }
    }

    /// Wie viele Tage am Stück aufgehoben werden.
    public static let taeglicheTage = 14
    /// Wie viele Monate darüber hinaus, mit je einer Datei.
    public static let monatlicheMonate = 12

    /// Der Ordner neben der Datenbank.
    public static func ordner(neben datenbank: URL) -> URL {
        datenbank.deletingLastPathComponent()
            .appendingPathComponent("Sicherungen", isDirectory: true)
    }

    static func dateiname(_ tag: CalendarDate) -> String { "habits-\(tag).json" }

    /// Ob eine Datei aus diesem Ordner eine automatische Sicherung ist, und von wann.
    public static func tag(von url: URL) -> CalendarDate? {
        let name = url.lastPathComponent
        guard name.hasPrefix("habits-"), name.hasSuffix(".json") else { return nil }
        return CalendarDate(iso: String(name.dropFirst(7).dropLast(5)))
    }

    // MARK: - Lauf

    /// Bringt die Datei des heutigen Tages auf den Stand, sobald sich etwas
    /// geändert hat.
    ///
    /// **Eine Datei je Tag, aber nicht eine je Tag und dann nie wieder.** Wer
    /// den Mac morgens aufmacht und danach am Telefon weiterarbeitet, hätte
    /// sonst eine Tagessicherung mit dem Stand von acht Uhr — sie sähe aus wie
    /// ein Netz und wäre keines. Ändert sich nichts, wird auch nichts
    /// geschrieben; dafür sorgt der Vergleich weiter unten.
    ///
    /// Wirft nicht bei einem vollen oder unbeschreibbaren Ordner — der Aufrufer
    /// bekommt den Fehler und kann ihn zeigen; die App darüber anzuhalten wäre
    /// die falsche Reihenfolge der Sorgen.
    @discardableResult
    public static func lauf(
        store: LocalHabitAPI,
        ordner: URL,
        today: CalendarDate,
        generator: String
    ) async throws -> Ergebnis {
        guard try await store.automatischeSicherung() else { return .aus }

        let ziel = ordner.appendingPathComponent(dateiname(today))
        let datei = try await store.exportBackup(generator: generator)
        let daten = try BackupCoding.encode(datei)

        // Gegen die jüngste vorhandene Sicherung halten — das ist die von heute,
        // sobald es eine gibt, sonst die vom letzten Mal. Verglichen wird der
        // Inhalt, nicht die Bytes: `exportedAt` unterscheidet sich immer, und
        // daran soll sich nichts entscheiden.
        if let letzte = try vorhandene(in: ordner).last,
           try istGleich(daten, wie: letzte, stand: datei) {
            return .unveraendert(seit: letzte)
        }

        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        try daten.write(to: ziel, options: .atomic)
        try raeumeAuf(in: ordner, bis: today)
        return .geschrieben(ziel)
    }

    /// Alle automatischen Sicherungen im Ordner, nach Tag aufsteigend.
    public static func vorhandene(in ordner: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: ordner.path) else { return [] }
        return try FileManager.default
            .contentsOfDirectory(at: ordner, includingPropertiesForKeys: nil)
            .filter { tag(von: $0) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func istGleich(
        _ daten: Data, wie datei: URL, stand: BackupFile
    ) throws -> Bool {
        guard let alt = try? BackupCoding.decode(Data(contentsOf: datei)) else { return false }
        var vergleich = alt
        // Die beiden Felder, die sich bei jedem Lauf ändern, gleichsetzen —
        // dann sagt ein Unterschied etwas über den Bestand aus.
        vergleich.exportedAt = stand.exportedAt
        vergleich.generator = stand.generator
        return try BackupCoding.encode(vergleich) == daten
    }

    // MARK: - Aufräumen

    /// Behält die letzten Tage vollständig und darüber hinaus je Monat eine.
    ///
    /// Ein gleitendes Fenster allein wäre zu kurz: einen Fehler von vorletzter
    /// Woche bemerkt man, einen von vor einem halben Jahr manchmal erst, wenn
    /// die Zahlen nicht mehr stimmen. Alles aufzuheben wäre das andere Extrem —
    /// dreihundert fast gleiche Dateien im Jahr, unter denen die interessanten
    /// verschwinden.
    static func raeumeAuf(in ordner: URL, bis heute: CalendarDate) throws {
        let alle = try vorhandene(in: ordner)
        let behalten = zuBehalten(alle, bis: heute)
        for datei in alle where !behalten.contains(datei) {
            try? FileManager.default.removeItem(at: datei)
        }
    }

    /// Rein und ohne Dateisystem, damit die Regel prüfbar ist.
    static func zuBehalten(_ dateien: [URL], bis heute: CalendarDate) -> Set<URL> {
        let grenze = heute.adding(days: -(taeglicheTage - 1))
        var behalten: Set<URL> = []
        // Je Monat die älteste — die jüngeren desselben Monats sagen dasselbe
        // noch einmal, nur später.
        var aeltesteImMonat: [String: URL] = [:]

        for datei in dateien {
            guard let tag = tag(von: datei) else { continue }
            if tag >= grenze {
                behalten.insert(datei)
                continue
            }
            if tag < heute.addingMonths(-monatlicheMonate) { continue }
            let monat = String(datei.lastPathComponent.dropFirst(7).prefix(7))   // YYYY-MM
            if aeltesteImMonat[monat] == nil { aeltesteImMonat[monat] = datei }
        }
        return behalten.union(aeltesteImMonat.values)
    }
}

// MARK: - Schalter

public extension LocalHabitAPI {
    /// Ob automatisch gesichert wird. Vorgabe: ja.
    ///
    /// Etwas, das im Hintergrund Dateien anlegt, muss sich abstellen lassen —
    /// sonst ist es keine Hilfe, sondern eine Eigenmächtigkeit.
    func automatischeSicherung() async throws -> Bool {
        try await dbQueue.read { db in
            try LocalHabitAPI.readSetting(LocalHabitAPI.autoBackupKey, db: db) != "0"
        }
    }

    func setzeAutomatischeSicherung(_ an: Bool) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO app_setting (key, value, updated_at, dirty) VALUES (?, ?, ?, 1)
                ON CONFLICT (key) DO UPDATE SET value = excluded.value,
                                                updated_at = excluded.updated_at, dirty = 1
                """, arguments: [LocalHabitAPI.autoBackupKey, an ? "1" : "0", Date()])
        }
    }

    static let autoBackupKey = "auto_backup"
}
