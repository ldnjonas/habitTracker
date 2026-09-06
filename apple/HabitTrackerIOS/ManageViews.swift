import SwiftUI
import UniformTypeIdentifiers
import HabitCore
import HabitStore
import HabitUI

// MARK: - Abgleich

/// Server einrichten und abgleichen.
///
/// Ohne Server bleibt alles auf diesem Telefon. Mit Server sehen iPhone, Mac
/// und Browser denselben Stand — der Server verwahrt nur Zeilen, gerechnet wird
/// weiter hier. Genau das ist der Unterschied zur WebApp: die App **hat** die
/// Daten, sie fragt nicht danach.
struct SyncView: View {
    @Environment(AppState.self) private var state

    @State private var serverEingabe = ""
    @State private var tokenEingabe = ""

    var body: some View {
        Form {
            if state.abgleichEingerichtet {
                Section("Server") {
                    LabeledContent("Adresse", value: state.serverURL)
                    if let status = state.syncStatus {
                        LabeledContent("Zuletzt", value: status)
                    }
                    if let zeit = state.letzterAbgleich {
                        LabeledContent("Zeitpunkt",
                                       value: zeit.formatted(date: .omitted, time: .shortened))
                    }
                }
                Section {
                    Button {
                        Task { await state.syncNow() }
                    } label: {
                        HStack {
                            Label("Jetzt abgleichen", systemImage: "arrow.triangle.2.circlepath")
                            if state.syncLäuft {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(state.syncLäuft)

                    Button("Trennen", role: .destructive) { state.trenneAbgleich() }
                }
            } else {
                if state.abgleichBrauchtToken {
                    Section {
                        Label("Die Adresse ist gespeichert, das Token nicht mehr lesbar. Das passiert nach einem Neubau: der Schlüsselbund bindet den Zugriff an die Signatur der App.",
                              systemImage: "key.slash")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section {
                    TextField("https://…", text: $serverEingabe)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Token", text: $tokenEingabe)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Einrichten")
                } footer: {
                    Text("Das Token landet im Schlüsselbund, nicht in der Datenbank — die wandert in jede Sicherung.")
                }
                Section {
                    Button("Einrichten") {
                        state.richteAbgleichEin(url: serverEingabe, token: tokenEingabe)
                        tokenEingabe = ""
                    }
                    .disabled(serverEingabe.isEmpty || tokenEingabe.count < 16)
                }
            }
        }
        .navigationTitle("Abgleich")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { serverEingabe = state.serverURL }
    }
}

// MARK: - Sicherung

/// Sichern und Wiederherstellen als Datei.
///
/// Anders als auf dem Mac gibt es hier **keine tägliche automatische
/// Sicherung**: ein Telefon ist nicht der Ort, an dem man sie aufhebt, und der
/// Server hat den Bestand ohnehin.
struct BackupDestination: View {
    @Environment(AppState.self) private var state

    @State private var exportDocument: BackupDocument?
    @State private var exportFilename = "habits"
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var importMode: ImportMode = .merge
    @State private var lastReport: ImportReport?
    @State private var problem: String?

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await bereiteExportVor() }
                } label: {
                    Label("Sicherung erstellen …", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("Sichern")
            } footer: {
                Text("Dieselbe Datei, die die Mac-App schreibt — lesbar, vergleichbar und in beide Richtungen verwendbar. Enthalten sind nur lebende Zeilen; Grabsteine gehören zum Abgleich, nicht zur Sicherung.")
            }

            Section {
                Picker("Art", selection: $importMode) {
                    Text(ImportMode.merge.label).tag(ImportMode.merge)
                    Text(ImportMode.replace.label).tag(ImportMode.replace)
                }
                .pickerStyle(.segmented)

                Text(importMode.explanation)
                    .font(.caption).foregroundStyle(.secondary)

                Button {
                    showImporter = true
                } label: {
                    Label("Datei wählen …", systemImage: "square.and.arrow.down")
                }
            } header: {
                Text("Einspielen")
            }

            if let bericht = lastReport {
                Section("Eingespielt") {
                    LabeledContent("Ergebnis", value: bericht.summary)
                    ForEach(bericht.problems, id: \.self) { problem in
                        Text(problem.description)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if let problem {
                Section {
                    Text(problem).font(.callout).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Sicherung")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $showExporter, document: exportDocument,
                      contentType: .json, defaultFilename: exportFilename) { ergebnis in
            if case .failure(let fehler) = ergebnis { problem = String(describing: fehler) }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json]) { ergebnis in
            Task { await spieleEin(ergebnis) }
        }
    }

    private func bereiteExportVor() async {
        guard let datei = await state.exportBackup() else { return }
        exportFilename = "habits-\(state.today)"
        exportDocument = BackupDocument(data: (try? BackupCoding.encode(datei)) ?? Data())
        showExporter = true
    }

    private func spieleEin(_ ergebnis: Result<URL, Error>) async {
        do {
            let url = try ergebnis.get()
            // Eine Datei aus der Dateien-App liegt außerhalb des Containers;
            // ohne diesen Zugriff kommt man nicht an ihren Inhalt.
            let erlaubt = url.startAccessingSecurityScopedResource()
            defer { if erlaubt { url.stopAccessingSecurityScopedResource() } }

            let datei = try BackupCoding.decode(Data(contentsOf: url))
            lastReport = await state.importBackup(datei, mode: importMode)
            problem = nil
        } catch {
            problem = String(describing: error)
            lastReport = nil
        }
    }
}

// MARK: - Papierkorb

struct TrashDestination: View {
    @Environment(AppState.self) private var state
    @State private var items: [TrashItem] = []

    var body: some View {
        ScrollView {
            TrashView(items: items) { item in
                Task {
                    try? await state.api.restore(item)
                    await state.reload()
                    await lade()
                }
            }
            .padding(16)
        }
        .navigationTitle("Papierkorb")
        .navigationBarTitleDisplayMode(.inline)
        .task { await lade() }
    }

    private func lade() async {
        items = (try? await state.api.trash()) ?? []
    }
}

// MARK: - Tags

struct TagsView: View {
    @Environment(AppState.self) private var state
    @State private var neuerName = ""

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("Neuer Tag", text: $neuerName)
                    Button("Anlegen") {
                        let name = neuerName.trimmingCharacters(in: .whitespaces)
                        neuerName = ""
                        Task { await state.createTag(name: name, colorHex: "#8E8E93") }
                    }
                    .disabled(neuerName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if state.tags.isEmpty {
                Section {
                    Text("Noch keine Tags. Sie gruppieren Habits für die Filter.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Section("Vorhanden") {
                    ForEach(state.tags) { tag in
                        HStack {
                            TagChip(tag: tag)
                            Spacer()
                            Text("\(anzahl(tag)) Habits")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Tags")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func anzahl(_ tag: Tag) -> Int {
        state.habits.filter { $0.tagIds.contains(tag.id) }.count
    }
}
