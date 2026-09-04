import SwiftUI
import HabitCore
import HabitStore

/// Formular zum Anlegen und Bearbeiten eines Habits.
///
/// Beim Bearbeiten trennt es zwei Dinge, die leicht verwechselt werden:
/// eine *Änderung* des Zeitplans gilt ab heute und lässt den Verlauf in Ruhe,
/// eine *Korrektur* überschreibt die bestehende Regel. Ohne diese Wahl legt
/// jeder Tippfehler eine neue Version an.
public struct HabitEditorForm: View {
    public enum Mode: Equatable {
        case create
        case edit(Habit)
    }

    /// Wie eine geänderte Regel verbucht wird.
    enum RuleChangeMode: String, CaseIterable, Identifiable {
        case fromToday = "Ab heute"
        case retroactive = "Rückwirkend korrigieren"
        var id: String { rawValue }

        var explanation: String {
            switch self {
            case .fromToday:
                "Vergangene Tage behalten den bisherigen Zeitplan. Deine Streaks und Quoten bleiben unverändert."
            case .retroactive:
                "Der gesamte Verlauf wird mit dem neuen Zeitplan neu bewertet. Für Tippfehler gedacht, nicht für echte Änderungen."
            }
        }
    }

    let mode: Mode
    let tags: [Tag]
    let today: CalendarDate
    let onSave: (HabitDraft, HabitPatch?, HabitRule?, [UUID]) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var notes = ""
    @State private var kind: HabitKind = .binary
    @State private var scheduleKind: ScheduleKind = .daily
    @State private var weekdays: Set<Weekday> = [.monday, .wednesday, .friday]
    @State private var timesPerWeek = 3
    @State private var everyNDays = 2
    @State private var targetValue = 1.0
    @State private var targetUnit = ""
    @State private var comparison: Comparison = .atLeast
    @State private var timeOfDay: TimeOfDay?
    @State private var selectedTags: Set<UUID> = []
    @State private var colorHex = "#4F8DF7"
    @State private var symbol = "checkmark.circle"
    @State private var isChallenge = false
    @State private var startsOn: CalendarDate = CalendarDate.today()
    @State private var endsOn: CalendarDate = CalendarDate.today().adding(days: 29)
    @State private var ruleChange: RuleChangeMode = .fromToday

    enum ScheduleKind: String, CaseIterable, Identifiable {
        case daily = "Täglich"
        case weekdays = "Wochentage"
        case timesPerWeek = "Pro Woche"
        case everyNDays = "Im Abstand"
        var id: String { rawValue }
    }

    public init(
        mode: Mode,
        tags: [Tag],
        today: CalendarDate,
        onSave: @escaping (HabitDraft, HabitPatch?, HabitRule?, [UUID]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.mode = mode
        self.tags = tags
        self.today = today
        self.onSave = onSave
        self.onCancel = onCancel
    }

    public var body: some View {
        Form {
            Section("Habit") {
                TextField("Name", text: $name)
                TextField("Notiz", text: $notes, axis: .vertical)
                    .lineLimit(1...3)

                Picker("Art", selection: $kind) {
                    Text("Erledigt / nicht erledigt").tag(HabitKind.binary)
                    Text("Menge mit Ziel").tag(HabitKind.quantity)
                    Text("Vermeiden").tag(HabitKind.avoid)
                }
                if kind == .avoid {
                    Text("Erfüllt ist der Normalfall — du meldest nur Verstöße.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if kind == .quantity {
                Section("Ziel") {
                    Picker("Bedingung", selection: $comparison) {
                        Text("Mindestens").tag(Comparison.atLeast)
                        Text("Höchstens").tag(Comparison.atMost)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        TextField("Wert", value: $targetValue, format: .number)
                        TextField("Einheit", text: $targetUnit)
                            .frame(maxWidth: 120)
                    }
                }
            }

            Section("Zeitplan") {
                Picker("Rhythmus", selection: $scheduleKind) {
                    ForEach(ScheduleKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch scheduleKind {
                case .daily:
                    EmptyView()
                case .weekdays:
                    weekdayToggles
                case .timesPerWeek:
                    Stepper("\(timesPerWeek)× pro Woche", value: $timesPerWeek, in: 1...7)
                    Text("Der Tag ist egal — gezählt werden Wochen, nicht Tage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .everyNDays:
                    Stepper("Alle \(everyNDays) Tage", value: $everyNDays, in: 2...30)
                }

                Picker("Tageszeit", selection: $timeOfDay) {
                    Text("Egal").tag(TimeOfDay?.none)
                    ForEach(TimeOfDay.allCases, id: \.self) { time in
                        Label(time.label, systemImage: time.symbolName).tag(TimeOfDay?.some(time))
                    }
                }
            }

            if case .edit = mode, ruleChanged {
                Section("Zeitplan geändert") {
                    Picker("Gilt", selection: $ruleChange) {
                        ForEach(RuleChangeMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Text(ruleChange.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Darstellung") {
                SymbolPicker(symbol: $symbol, colorHex: colorHex)
                ColorSwatchPicker(colorHex: $colorHex)
                if !tags.isEmpty {
                    tagPicker
                }
            }

            Section {
                Toggle("Befristet", isOn: $isChallenge)
                if isChallenge {
                    DateRow(title: "Von", date: $startsOn)
                    DateRow(title: "Bis", date: $endsOn)
                    Text("Außerhalb des Zeitraums ist nichts geplant — gut für „30 Tage kein Zucker“.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Zeitraum")
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Abbrechen", role: .cancel, action: onCancel)
                Spacer()
                Button("Sichern", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
            .background(.bar)
        }
        .onAppear(perform: load)
    }

    // MARK: - Teilansichten

    private var weekdayToggles: some View {
        HStack(spacing: 6) {
            ForEach(Weekday.allCases, id: \.self) { weekday in
                let on = weekdays.contains(weekday)
                Button {
                    if on { weekdays.remove(weekday) } else { weekdays.insert(weekday) }
                } label: {
                    Text(weekday.shortLabel)
                        .font(.caption.weight(.medium))
                        .frame(width: 32, height: 26)
                        .background(on ? Color(hex: colorHex) : Color.secondary.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(on ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var tagPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(tags) { tag in
                    Button {
                        if selectedTags.contains(tag.id) { selectedTags.remove(tag.id) }
                        else { selectedTags.insert(tag.id) }
                    } label: {
                        TagChip(tag: tag, isSelected: selectedTags.contains(tag.id))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Laden und Sichern

    /// Ob sich Zeitplan oder Ziel gegenüber der aktuell gültigen Regel geändert haben.
    private var ruleChanged: Bool {
        guard case .edit(let habit) = mode,
              let current = habit.rule(on: today) else { return false }
        return current.schedule != buildSchedule() || current.target != buildTarget()
    }

    private func load() {
        guard case .edit(let habit) = mode else { return }
        name = habit.name
        notes = habit.notes ?? ""
        kind = habit.kind
        colorHex = habit.colorHex
        symbol = habit.symbol
        timeOfDay = habit.timeOfDay
        selectedTags = Set(habit.tagIds)

        if let rule = habit.rule(on: today) {
            switch rule.schedule {
            case .daily:
                scheduleKind = .daily
            case .weekdays(let days):
                scheduleKind = .weekdays
                weekdays = days
            case .timesPerWeek(let n):
                scheduleKind = .timesPerWeek
                timesPerWeek = n
            case .everyNDays(let n, _):
                scheduleKind = .everyNDays
                everyNDays = n
            }
            if let target = rule.target {
                targetValue = target.value
                targetUnit = target.unit
                comparison = target.comparison
            }
        }

        if let from = habit.startsOn, let to = habit.endsOn {
            isChallenge = true
            startsOn = from
            endsOn = to
        }
    }

    private func buildSchedule() -> Schedule {
        switch scheduleKind {
        case .daily: .daily
        case .weekdays: .weekdays(weekdays)
        case .timesPerWeek: .timesPerWeek(timesPerWeek)
        case .everyNDays: .everyNDays(n: everyNDays, anchor: startsOn)
        }
    }

    private func buildTarget() -> Target? {
        guard kind == .quantity else { return nil }
        return Target(value: targetValue,
                      unit: targetUnit.isEmpty ? "×" : targetUnit,
                      comparison: comparison)
    }

    private func save() {
        let schedule = buildSchedule()
        let target = buildTarget()

        switch mode {
        case .create:
            let draft = HabitDraft(
                name: name, kind: kind,
                rules: [HabitRule(effectiveFrom: isChallenge ? startsOn : today,
                                  schedule: schedule, target: target)],
                notes: notes.isEmpty ? nil : notes,
                colorHex: colorHex, symbol: symbol,
                tagIds: Array(selectedTags), timeOfDay: timeOfDay,
                startsOn: isChallenge ? startsOn : nil,
                endsOn: isChallenge ? endsOn : nil
            )
            onSave(draft, nil, nil, Array(selectedTags))

        case .edit(let habit):
            let patch = HabitPatch(
                name: name,
                notes: .some(notes.isEmpty ? nil : notes),
                colorHex: colorHex,
                symbol: symbol,
                timeOfDay: .some(timeOfDay),
                startsOn: .some(isChallenge ? startsOn : nil),
                endsOn: .some(isChallenge ? endsOn : nil)
            )
            // Bei „rückwirkend" wird die bestehende Regel überschrieben, bei
            // „ab heute" eine neue angelegt — beides derselbe Upsert, nur mit
            // unterschiedlichem effectiveFrom.
            let rule: HabitRule? = ruleChanged
                ? HabitRule(
                    effectiveFrom: ruleChange == .retroactive
                        ? (habit.rule(on: today)?.effectiveFrom ?? today)
                        : today,
                    schedule: schedule, target: target)
                : nil
            onSave(HabitDraft(name: name, rules: []), patch, rule, Array(selectedTags))
        }
    }
}

// MARK: - Kleinteile

/// Auswahl aus einer handverlesenen Liste statt aus allen SF Symbols —
/// eine vollständige Symbolsuche wäre ein eigenes Feature.
struct SymbolPicker: View {
    @Binding var symbol: String
    var colorHex: String

    static let choices = [
        "checkmark.circle", "figure.run", "book.fill", "drop.fill", "leaf.fill",
        "bed.double.fill", "fork.knife", "dumbbell.fill", "brain.head.profile",
        "pencil", "guitars.fill", "cup.and.saucer.fill", "sunrise.fill",
        "moon.stars.fill", "heart.fill", "pills.fill", "bicycle", "figure.walk",
        "sparkles", "iphone", "wineglass.fill", "cube.fill",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Symbol").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 11),
                      spacing: 4) {
                ForEach(Self.choices, id: \.self) { choice in
                    Button { symbol = choice } label: {
                        Image(systemName: choice)
                            .frame(width: 26, height: 26)
                            .background(symbol == choice
                                        ? Color(hex: colorHex).opacity(0.25)
                                        : Color.secondary.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct ColorSwatchPicker: View {
    @Binding var colorHex: String

    static let choices = [
        "#FF375F", "#FF9F0A", "#FFD60A", "#30D158", "#66D4CF",
        "#0A84FF", "#5E5CE6", "#BF5AF2", "#AC8E68", "#8E8E93",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Farbe").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(Self.choices, id: \.self) { hex in
                    Button { colorHex = hex } label: {
                        Circle()
                            .fill(Color(hex: hex))
                            .frame(width: 22, height: 22)
                            .overlay {
                                if colorHex == hex {
                                    Circle().strokeBorder(.primary, lineWidth: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Datumsauswahl, die zwischen `CalendarDate` und `Date` übersetzt.
///
/// Die Übersetzung passiert bewusst hier an der UI-Grenze und nicht in der
/// Domäne — `CalendarDate` soll keine Zeitzone kennen.
struct DateRow: View {
    var title: String
    @Binding var date: CalendarDate

    var body: some View {
        DatePicker(title, selection: Binding(
            get: {
                var components = DateComponents()
                components.year = date.year
                components.month = date.month
                components.day = date.day
                components.hour = 12          // Mittag: unempfindlich gegen Zeitzonen
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newValue in
                let c = Calendar.current.dateComponents([.year, .month, .day], from: newValue)
                if let parsed = CalendarDate(year: c.year!, month: c.month!, day: c.day!) {
                    date = parsed
                }
            }
        ), displayedComponents: .date)
    }
}
