import SwiftUI
import UniformTypeIdentifiers
import HabitCore
import HabitStore
import HabitUI

/// Eine Sicherungsdatei für `.fileExporter`.
struct BackupDocument: FileDocument {
    static let readableContentTypes = [UTType.json]

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Sichern und Wiederherstellen als Datei.
///
/// Bewusst ohne Automatik: der Nutzer bestimmt, wann und wohin gesichert wird.
/// Eine Sicherung, die im Verborgenen läuft, merkt man erst, wenn sie fehlt.
struct BackupView: View {
    @Environment(AppState.self) private var state

    @State private var exportDocument: BackupDocument?
    @State private var exportFilename = "habits"
    @State private var showExporter = false
    @State private var showImporter = false

    /// Auswahl für den Teil-Export. Leer heißt: alles.
    @State private var selection: Set<UUID> = []
    @State private var exportsSelection = false

    @State private var pending: BackupFile?
    @State private var importMode: ImportMode = .merge
    @State private var lastReport: ImportReport?
    @State private var problem: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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

    // MARK: - Export

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
