import SwiftUI
import HabitCore

/// Zusammenhänge als Sätze, nicht als Zahlen.
///
/// „r = 0,72“ sagt niemandem etwas; „an Tagen mit Sport schläfst du im Schnitt
/// 42 Minuten länger“ schon. Der Koeffizient steht trotzdem daneben — wer ihn
/// lesen kann, soll ihn sehen.
public struct CorrelationCard: View {
    public var correlations: [Correlation]
    public var habitName: (UUID) -> String?
    public var habitColor: (UUID) -> Color

    public init(
        correlations: [Correlation],
        habitName: @escaping (UUID) -> String?,
        habitColor: @escaping (UUID) -> Color
    ) {
        self.correlations = correlations
        self.habitName = habitName
        self.habitColor = habitColor
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if correlations.isEmpty {
                Text("Noch keine belastbaren Zusammenhänge. Es braucht mindestens \(CorrelationRule.minimumDays) Tage, an denen sowohl ein Habit entschieden als auch etwas im Journal erfasst war — und in beiden Gruppen je \(CorrelationRule.minimumPerGroup).")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(correlations, id: \.self) { correlation in
                    row(correlation)
                    if correlation != correlations.last { Divider() }
                }

                // Die Einschränkung gehört zur Aussage, nicht ins Kleingedruckte
                // eines Handbuchs.
                Label("Das heißt: es fällt zusammen. Ob das eine das andere bewirkt, sagen diese Zahlen nicht — vielleicht gelingt an manchen Tagen ohnehin beides leichter.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private func row(_ correlation: Correlation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: correlation.metric.symbolName)
                .foregroundStyle(habitColor(correlation.habitId))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(sentence(correlation)).fixedSize(horizontal: false, vertical: true)
                Text("\(correlation.dayCount) gemeinsame Tage · \(strengthLabel(correlation.strength)) Zusammenhang · r = \(correlation.coefficient.formatted(.number.precision(.fractionLength(2))))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func sentence(_ c: Correlation) -> String {
        let name = habitName(c.habitId) ?? "diesem Habit"
        let hoeher = c.difference > 0
        let betrag = abs(c.difference)

        switch c.metric {
        case .sleepHours:
            return "An Tagen mit \(name) schläfst du im Schnitt \(formatMinutes(betrag * 60)) \(hoeher ? "länger" : "kürzer")."
        case .mood:
            return "An Tagen mit \(name) ist deine Stimmung im Schnitt \(punkte(betrag)) \(hoeher ? "besser" : "schlechter")."
        case .energy:
            return "An Tagen mit \(name) ist deine Energie im Schnitt \(punkte(betrag)) \(hoeher ? "höher" : "niedriger")."
        }
    }

    private func punkte(_ value: Double) -> String {
        let text = value.formatted(.number.precision(.fractionLength(1)))
        return "\(text) \(value == 1 ? "Punkt" : "Punkte")"
    }

    private func strengthLabel(_ strength: CorrelationStrength) -> String {
        switch strength {
        case .weak: "schwacher"
        case .moderate: "mittlerer"
        case .strong: "deutlicher"
        }
    }
}
