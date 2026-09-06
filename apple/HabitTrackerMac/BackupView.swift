import SwiftUI
import UniformTypeIdentifiers
import HabitCore
import HabitStore
import HabitSync
import HabitUI

/// Sichern und Wiederherstellen als Datei.
///
/// Zwei Wege nebeneinander, und beide werden gebraucht. **Von Hand** bestimmt
/// man Zeitpunkt, Umfang und Ort — das ist der Weg, wenn eine Sicherung
/// woandershin soll oder nur einzelne Habits umfasst. **Automatisch** läuft
/// täglich eine vollständige in einen festen Ordner, weil eine Sicherung, an
/// die man denken muss, genau dann fehlt, wenn man sie braucht.
///
/// Damit die automatische nicht im Verborgenen läuft, steht sie hier oben mit
/// Ordner, Datum und Anzahl — und mit einem Schalter. Etwas, das ungefragt
/// Dateien anlegt, muss sich abstellen lassen.
struct BackupView: View {
    @Environment(AppState.self) private var state

    @State private var exportDocument: BackupDocument?
    @State private var exportFilename = "habits"
    @State private var showExporter = false
    @State private var showImporter = false

    /// Auswahl für den Teil-Export. Leer heißt: alles.
    @State private var selection: Set<UUID> = []
    @State private var exportsSelection = false

    @State private var serverEingabe = ""
    @State private var tokenEingabe = ""
    @State private var pending: BackupFile?
    @State private var importMode: ImportMode = .merge
    @State private var lastReport: ImportReport?
    @State private var problem: String?

    /// Was im Sicherungsordner liegt. Beim Öffnen der Seite frisch gelesen —
    /// ein mitgeführter Zustand ginge irgendwann daneben, und der Ordner ist
    /// die Wahrheit.
    @State private var sicherungen: [URL] = []
    @State private var autoAn = true
    @State private var autoMeldung: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                syncSection
                autoSection
                exportSection
                importSection
                if let lastReport { reportSection(lastReport) }
            }
            // Wie die Übersicht: eine linksbündige Spalte fester Breite. Ein
            // `Form` zentriert sich in der Fensterbreite und lässt links die
            // halbe Seite leer.
            .frame(maxWidth: 640, alignment: .leading)
            .padding(20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if serverEingabe.isEmpty { serverEingabe = state.serverURL } }
        .navigationTitle("Sicherung")
        .fileExporter(isPresented: $showExporter, document: exportDocument,
                      contentType: .json, defaultFilename: exportFilename) { result in
            if case .failure(let error) = result { problem = String(describing: error) }
            exportDocument = nil
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json]) { result in
            handlePickedFile(result)
        }
        .sheet(item: $pending) { file in
            confirmImport(file)
        }
        .alert("Das hat nicht geklappt", isPresented: .constant(problem != nil)) {
            Button("OK") { problem = nil }
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: - Abgleich

    private var syncSection: some View {
        card("Abgleich") {
            if state.abgleichEingerichtet {
                LabeledContent("Server", value: state.serverURL)
                if let status = state.syncStatus {
                    LabeledContent("Zuletzt", value: status)
                }
                if let zeit = state.letzterAbgleich {
                    LabeledContent("Zeitpunkt",
                                   value: zeit.formatted(date: .omitted, time: .shortened))
                }
                HStack {
                    Button("Jetzt abgleichen") { Task { await state.syncNow() } }
                        .disabled(state.syncLäuft)
                    if state.syncLäuft { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Trennen", role: .destructive) { state.trenneAbgleich() }
                        .controlSize(.small)
                }
            } else {
                if state.abgleichBrauchtToken {
                    Label("Die Adresse ist gespeichert, das Token nicht mehr lesbar. Auf dem Mac passiert das nach einem Neubau: der Schlüsselbund bindet den Zugriff an die Signatur der App.",
                          systemImage: "key.slash")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Ohne Server bleibt alles auf diesem Mac. Mit Server sehen iPhone und Mac denselben Stand — der Server verwahrt nur Zeilen, gerechnet wird weiter hier.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("https://…", text: $serverEingabe)
                    .textFieldStyle(.roundedBorder)
                SecureField("Token", text: $tokenEingabe)
                    .textFieldStyle(.roundedBorder)
                Text("Das Token landet im Schlüsselbund, nicht in der Datenbank — die wandert in jede Sicherung.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Einrichten") {
                    state.richteAbgleichEin(url: serverEingabe, token: tokenEingabe)
                    tokenEingabe = ""
                }
                .disabled(serverEingabe.isEmpty || tokenEingabe.count < 16)
            }
        }
    }

    // MARK: - Export

    // MARK: - Automatisch

    private var autoSection: some View {
        card("Automatisch sichern") {
            Toggle("Täglich eine Sicherung anlegen", isOn: Binding(
                get: { autoAn },
                set: { neu in
                    autoAn = neu
                    Task {
                        try? await state.lokal?.setzeAutomatischeSicherung(neu)
                        if neu { await sichereJetzt() } else { await ladeSicherungen() }
                    }
                }))

            Text("Läuft beim Start der App und beim Tageswechsel. Hat sich seit der letzten Sicherung nichts geändert, wird keine neue geschrieben.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let letzte = sicherungen.last {
                LabeledContent("Letzte", value: AutoBackup.tag(von: letzte)?.longLabel ?? "—")
                LabeledContent("Aufbewahrt", value: "\(sicherungen.count) Stück")
            } else {
                Text(autoAn ? "Noch keine Sicherung angelegt." : "Ausgeschaltet.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text("Die letzten \(AutoBackup.taeglicheTage) Tage bleiben vollständig, davor je Monat eine, bis \(AutoBackup.monatlicheMonate) Monate zurück. Die Dateien liegen neben der Datenbank — das schützt vor Fehlgriffen, nicht vor dem Verlust der Festplatte.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let autoMeldung {
                Text(autoMeldung).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Jetzt sichern") { Task { await sichereJetzt() } }
                    .disabled(!autoAn)
                Spacer()
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [sicherungen.last ?? HabitTrackerApp.backupOrdner])
                }
                .controlSize(.small)
                .disabled(sicherungen.isEmpty)
            }
        }
        .task { await ladeSicherungen() }
    }

    private func ladeSicherungen() async {
        autoAn = (try? await state.lokal?.automatischeSicherung()) ?? true
        sicherungen = (try? AutoBackup.vorhandene(in: HabitTrackerApp.backupOrdner)) ?? []
    }

    /// Von Hand angestoßen — mit denselben Regeln wie automatisch.
    ///
    /// Der Knopf erzwingt also **keine** Datei: hat sich nichts geändert, sagt
    /// er das. Eine erzwungene Kopie desselben Stands wäre eine Datei, die
    /// nichts festhält, und sie verdrängte beim Aufräumen eine, die etwas
    /// festhält.
    private func sichereJetzt() async {
        guard let store = state.lokal else { return }
        do {
            let ergebnis = try await AutoBackup.lauf(
                store: store, ordner: HabitTrackerApp.backupOrdner,
                today: state.today, generator: HabitTrackerApp.generator)
            autoMeldung = switch ergebnis {
            case .geschrieben: nil
            case .unveraendert(let seit):
                "Seit dem \(AutoBackup.tag(von: seit)?.longLabel ?? "letzten Mal") hat sich nichts geändert."
            case .aus: "Ausgeschaltet."
            }
        } catch {
            autoMeldung = "Sicherung fehlgeschlagen: \(error.localizedDescription)"
        }
        await ladeSicherungen()
    }

    private var exportSection: some View {
        card("Exportieren") {
            Picker("Umfang", selection: $exportsSelection) {
                Text("Alles").tag(false)
                Text("Auswahl").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 200)

            Text(exportsSelection
                 ? "Schreibt die gewählten Habits samt Verlauf in eine JSON-Datei — geeignet, um einen einzelnen Streak auf ein anderes Gerät zu holen."
                 : "Schreibt alle Habits, Einträge, Tags, Ausnahmen und das Journal in eine JSON-Datei. Archivierte Habits sind dabei, gelöschte nicht.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if exportsSelection {
                if state.habits.isEmpty {
                    Text("Keine Habits vorhanden.").foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(state.habits) { habit in
                            Toggle(isOn: binding(for: habit.id)) {
                                Label {
                                    Text(habit.name)
                                } icon: {
                                    Image(systemName: habit.symbol)
                                        .foregroundStyle(Color(hex: habit.colorHex))
                                }
                            }
                        }
                    }
                    .padding(.leading, 2)
                }
            }

            Button("Sichern …") { Task { await prepareExport() } }
                .disabled(exportsSelection && selection.isEmpty)
        }
    }

    /// Karte im Stil der Übersichtsseite.
    private func card<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(get: { selection.contains(id) },
                set: { isOn in
                    if isOn { selection.insert(id) } else { selection.remove(id) }
                })
    }

    private func prepareExport() async {
        let ids: Set<UUID>? = exportsSelection ? selection : nil
        guard let file = await state.exportBackup(habitIds: ids) else { return }
        do {
            exportDocument = BackupDocument(data: try BackupCoding.encode(file))
            // Das Datum im Namen macht mehrere Sicherungen nebeneinander sortierbar.
            let stamp = state.today.description
            exportFilename = ids == nil
                ? "habits-\(stamp)"
                : "habits-auswahl-\(stamp)"
            showExporter = true
        } catch {
            problem = String(describing: error)
        }
    }

    // MARK: - Import

    private var importSection: some View {
        card("Importieren") {
            Text("Vor dem Einspielen wird gezeigt, was in der Datei steht und wie sie mit dem vorhandenen Bestand verrechnet wird.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Datei wählen …") { showImporter = true }
        }
    }

    private func handlePickedFile(_ result: Result<URL, any Error>) {
        switch result {
        case .failure(let error):
            problem = String(describing: error)
        case .success(let url):
            // Ohne Sandbox nicht nötig, aber die App soll auch dann noch lesen
            // können, wenn sie später eine bekommt.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let file = try BackupCoding.decode(try Data(contentsOf: url))
                let problems = HabitCore.validate(file)
                if let fatal = problems.first(where: \.isFatal) {
                    problem = fatal.description
                } else {
                    pending = file
                }
            } catch {
                problem = "Die Datei konnte nicht gelesen werden.\n\n\(error)"
            }
        }
    }

    private func confirmImport(_ file: BackupFile) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Sicherung einspielen").font(.title2).bold()

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Inhalt", value: file.summary)
                if let range = file.dateRange {
                    LabeledContent("Zeitraum",
                                   value: "\(range.from.shortLabel) – \(range.to.shortLabel)")
                }
                LabeledContent("Erstellt", value: file.exportedAt.formatted(date: .abbreviated,
                                                                            time: .shortened))
                LabeledContent("Von", value: file.generator)
            }
            .font(.callout)

            Divider()

            Picker("Vorgehen", selection: $importMode) {
                ForEach(ImportMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)

            Text(importMode.explanation)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if importMode == .replace {
                Label("Der bisherige Bestand wird gelöscht und landet nicht im Papierkorb.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if importMode == .replace && file.scope == .habits {
                Label("Diese Datei enthält nur einzelne Habits — „Ersetzen“ würde alle übrigen entfernen.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Abbrechen") { pending = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(importMode == .replace ? "Ersetzen" : "Einspielen") {
                    let file = file
                    pending = nil
                    Task { lastReport = await state.importBackup(file, mode: importMode) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    // MARK: - Ergebnis

    private func reportSection(_ report: ImportReport) -> some View {
        card("Zuletzt eingespielt") {
            LabeledContent("Ergebnis", value: report.summary)
            row("Habits", report.habits)
            row("Einträge", report.entries)
            if report.tags.total > 0 { row("Tags", report.tags) }
            if report.events.total > 0 { row("Zeitstempel", report.events) }
            if report.exceptions.total > 0 { row("Ausnahmen", report.exceptions) }
            if report.dayLogs.total > 0 { row("Journal", report.dayLogs) }

            ForEach(report.problems.indices, id: \.self) { index in
                Label(report.problems[index].description, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ label: String, _ counts: ImportReport.Counts) -> some View {
        LabeledContent(label) {
            Text("\(counts.inserted) neu · \(counts.updated) aktualisiert · \(counts.skipped) unverändert")
                .foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// Damit `.sheet(item:)` die zu bestätigende Datei tragen kann.
extension BackupFile: @retroactive Identifiable {
    public var id: String { "\(generator)-\(exportedAt.timeIntervalSince1970)" }
}
