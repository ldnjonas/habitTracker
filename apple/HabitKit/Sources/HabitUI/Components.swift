import SwiftUI
import HabitCore

// MARK: - Fortschrittsring

/// Ring, der den Tagesfortschritt zeigt und bei Erfüllung ein Häkchen trägt.
public struct ProgressRing: View {
    public var progress: Double
    public var color: Color
    public var symbol: String
    public var size: CGFloat = 28

    public init(progress: Double, color: Color, symbol: String, size: CGFloat = 28) {
        self.progress = progress
        self.color = color
        self.symbol = symbol
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: size * 0.11)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: progress >= 1 ? "checkmark" : symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(progress >= 1 ? color : color.opacity(0.75))
        }
        .frame(width: size, height: size)
        .animation(.snappy(duration: 0.25), value: progress)
    }
}

// MARK: - Statuspunkt

/// Eine Zelle in Heatmap und Monatskalender.
public struct DayStatusDot: View {
    public var status: DayStatus
    public var color: Color
    public var size: CGFloat
    public var cornerRadius: CGFloat

    public init(status: DayStatus, color: Color, size: CGFloat = 11, cornerRadius: CGFloat = 2.5) {
        self.status = status
        self.color = color
        self.size = size
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fill)
            .overlay {
                // Verpasste geplante Tage bekommen eine Kontur statt einer Füllung:
                // sichtbar, ohne mit der Farbe der erledigten zu konkurrieren.
                if case .missed = status {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                }
            }
            .frame(width: size, height: size)
    }

    private var fill: Color {
        let opacity = status.fillOpacity()
        if opacity > 0 { return color.opacity(opacity) }
        switch status {
        case .notScheduled, .future: return Color.secondary.opacity(0.08)
        default: return Color.secondary.opacity(0.12)
        }
    }
}

// MARK: - Tag-Plakette

public struct TagChip: View {
    public var tag: Tag
    public var isSelected: Bool

    public init(tag: Tag, isSelected: Bool = false) {
        self.tag = tag
        self.isSelected = isSelected
    }

    public var body: some View {
        let color = Color(hex: tag.colorHex)
        Text(tag.name)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(isSelected ? 0.9 : 0.15), in: Capsule())
            .foregroundStyle(isSelected ? .white : color)
    }
}

// MARK: - Trend

public struct TrendBadge: View {
    public var trend: Trend

    public init(trend: Trend) { self.trend = trend }

    public var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .help(helpText)
    }

    private var text: String {
        switch trend {
        case .improving(let delta): "+\(Int((delta * 100).rounded()))"
        case .stable: "stabil"
        case .declining(let delta): "−\(Int((delta * 100).rounded()))"
        }
    }

    private var symbol: String {
        switch trend {
        case .improving: "arrow.up.right"
        case .stable: "equal"
        case .declining: "arrow.down.right"
        }
    }

    private var color: Color {
        switch trend {
        case .improving: .green
        case .stable: .secondary
        case .declining: .orange
        }
    }

    private var helpText: String {
        "Die letzten 14 Tage im Vergleich zu den 14 davor, in Prozentpunkten"
    }
}

// MARK: - Mengensteuerung

/// Plus/Minus für Habits mit Mengenziel.
public struct QuantityStepper: View {
    public var value: Double
    public var unit: String
    public var step: Double
    public var onChange: (Double) -> Void

    public init(value: Double, unit: String, step: Double, onChange: @escaping (Double) -> Void) {
        self.value = value
        self.unit = unit
        self.step = step
        self.onChange = onChange
    }

    public var body: some View {
        HStack(spacing: 6) {
            Button { onChange(-step) } label: {
                Image(systemName: "minus")
            }
            .disabled(value <= 0)

            Text("\(number(value)) \(unit)")
                .font(.callout.monospacedDigit())
                .frame(minWidth: 70)

            Button { onChange(step) } label: {
                Image(systemName: "plus")
            }
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
    }
}

// MARK: - Habit-Zeile

/// Eine Zeile in der Heute-Ansicht — mit der Bedienung, die zum Typ passt.
public struct HabitRowView: View {
    public var habit: Habit
    public var date: CalendarDate
    public var status: DayStatus
    public var value: Double
    public var streak: Int
    public var trend: Trend?
    public var tags: [Tag]
    public var onToggle: () -> Void
    public var onAdjust: (Double) -> Void
    /// Ziffer des Tastenkürzels, falls es eines gibt. Ohne sichtbare Ziffer
    /// wäre das Kürzel eine Funktion, von der man wissen muss, dass es sie gibt.
    public var shortcutNumber: Int?

    public init(
        habit: Habit, date: CalendarDate, status: DayStatus, value: Double,
        streak: Int, trend: Trend?, tags: [Tag], shortcutNumber: Int? = nil,
        onToggle: @escaping () -> Void, onAdjust: @escaping (Double) -> Void
    ) {
        self.habit = habit
        self.date = date
        self.status = status
        self.value = value
        self.streak = streak
        self.trend = trend
        self.tags = tags
        self.shortcutNumber = shortcutNumber
        self.onToggle = onToggle
        self.onAdjust = onAdjust
    }

    private var color: Color { Color(hex: habit.colorHex) }
    private var progress: Double { habit.progress(value: value, on: date) }

    public var body: some View {
        Group {
            // Auf einem Telefon konkurrieren Name, Trend und Mengensteuerung um
            // dieselben Punkte. Statt den Zeitplan buchstabenweise umzubrechen,
            // rutscht die Steuerung dann unter den Namen. Auf dem Mac ist Platz —
            // dort wählt `ViewThatFits` weiterhin die einzeilige Fassung.
            if hatSteuerung {
                ViewThatFits(in: .horizontal) {
                    einzeilig
                    zweizeilig
                }
            } else {
                einzeilig
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Hat diese Zeile überhaupt eine Steuerung rechts? Nur dann lohnt der
    /// zweite Anlauf — eine leere zweite Reihe wäre bloß Luft.
    private var hatSteuerung: Bool {
        switch habit.kind {
        case .quantity: habit.target(on: date) != nil
        case .avoid: true
        case .binary: false
        }
    }

    private var einzeilig: some View {
        HStack(spacing: 12) {
            kürzel
            haken
            beschriftung
            Spacer(minLength: 8)
            if let trend { TrendBadge(trend: trend) }
            control
        }
    }

    private var zweizeilig: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                kürzel
                haken
                beschriftung
                Spacer(minLength: 8)
                if let trend { TrendBadge(trend: trend) }
            }
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                control
            }
        }
    }

    @ViewBuilder
    private var kürzel: some View {
        if let shortcutNumber {
            Text("\(shortcutNumber)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 10)
                .help("Mit der Taste \(shortcutNumber) abhaken")
        }
    }

    private var haken: some View {
        Button(action: onToggle) {
            ProgressRing(progress: progress, color: color, symbol: habit.symbol, size: 30)
        }
        .buttonStyle(.plain)
        .help(status.isCompleted ? "Zurücknehmen" : "Erledigt")
    }

    private var beschriftung: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(habit.name)
                .font(.body.weight(.medium))
                .strikethrough(status.isCompleted && habit.kind != .avoid, color: .secondary)
                .lineLimit(1)

            HStack(spacing: 6) {
                if streak > 0 {
                    Label("\(streak)", systemImage: "flame.fill")
                        .foregroundStyle(.orange)
                }
                Text(habit.rule(on: date)?.schedule.label ?? "")
                ForEach(tags) { tag in
                    TagChip(tag: tag)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            // Eine Zeile, die umbricht, wäre keine Zeile mehr: lieber abschneiden.
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private var control: some View {
        switch habit.kind {
        case .quantity:
            if let target = habit.target(on: date) {
                QuantityStepper(value: value, unit: target.unit,
                                step: stepSize(for: target), onChange: onAdjust)
            }
        case .avoid:
            // Kein Abhaken: bei Vermeidung ist Erfolg der Normalzustand, gemeldet
            // wird nur der Verstoß.
            Button {
                onAdjust(1)
            } label: {
                Label(value > 0 ? "\(Int(value))×" : "Verstoß", systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(value > 0 ? .orange : .secondary)
        case .binary:
            EmptyView()
        }
    }

    /// Schrittweite passend zur Größenordnung: 0,5 bei Litern, 500 bei Schritten.
    private func stepSize(for target: Target) -> Double {
        switch target.value {
        case ..<5: 0.5
        case ..<100: 5
        case ..<1000: 50
        default: 500
        }
    }
}

// MARK: - Fließreihe

/// Eine Reihe, die umbricht, statt ihre Kinder zu quetschen.
///
/// SwiftUI hat dafür nichts Eingebautes: eine `HStack` verteilt den vorhandenen
/// Platz und drückt Text notfalls auf einen Buchstaben pro Zeile — auf einem
/// Telefon passiert das schnell. Hier bekommt jedes Kind seine ideale Breite,
/// und was nicht mehr hinpasst, rutscht eine Zeile tiefer.
public struct FlowLayout: Layout {
    public var spacing: CGFloat
    public var lineSpacing: CGFloat

    public init(spacing: CGFloat = 20, lineSpacing: CGFloat = 12) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    public func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let verfuegbar = proposal.width ?? .infinity
        let zeilen = umbrich(subviews, in: verfuegbar)
        let hoehe = zeilen.reduce(0) { $0 + $1.hoehe }
            + lineSpacing * CGFloat(max(0, zeilen.count - 1))
        return CGSize(width: min(verfuegbar, zeilen.map(\.breite).max() ?? 0), height: hoehe)
    }

    public func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for zeile in umbrich(subviews, in: bounds.width) {
            var x = bounds.minX
            for index in zeile.indizes {
                let groesse = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y),
                                      proposal: ProposedViewSize(groesse))
                x += groesse.width + spacing
            }
            y += zeile.hoehe + lineSpacing
        }
    }

    private struct Zeile {
        var indizes: [Int] = []
        var breite: CGFloat = 0
        var hoehe: CGFloat = 0
    }

    private func umbrich(_ subviews: Subviews, in breite: CGFloat) -> [Zeile] {
        var zeilen: [Zeile] = []
        var aktuell = Zeile()
        for index in subviews.indices {
            let groesse = subviews[index].sizeThatFits(.unspecified)
            let mitDiesem = aktuell.indizes.isEmpty
                ? groesse.width : aktuell.breite + spacing + groesse.width
            // Ein einzelnes Kind, das allein schon zu breit ist, bleibt trotzdem
            // in seiner Zeile — sonst entstünde eine leere.
            if !aktuell.indizes.isEmpty && mitDiesem > breite {
                zeilen.append(aktuell)
                aktuell = Zeile(indizes: [index], breite: groesse.width, hoehe: groesse.height)
            } else {
                aktuell.indizes.append(index)
                aktuell.breite = mitDiesem
                aktuell.hoehe = max(aktuell.hoehe, groesse.height)
            }
        }
        if !aktuell.indizes.isEmpty { zeilen.append(aktuell) }
        return zeilen
    }
}
