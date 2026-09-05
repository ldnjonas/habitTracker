/// Portiert aus `apple/HabitKit/Sources/HabitCore/Correlations.swift`.

import type { CalendarDate } from "./calendar.ts";
import { through } from "./calendar.ts";
import type { DayException, DayLog, Entry } from "./entry.ts";
import type { Habit } from "./habit.ts";
import { status } from "./completion.ts";
import type { DayStatus } from "./dayStatus.ts";

/// Eine Größe aus dem Tages-Journal.
export type JournalMetric = "mood" | "energy" | "sleepHours";

export const JOURNAL_METRICS: readonly JournalMetric[] = ["mood", "energy", "sleepHours"];

/// Der Wert dieses Tages, falls erfasst.
export function metricValue(metric: JournalMetric, log: DayLog): number | null {
  return log[metric] ?? null;
}

/// Wie deutlich ein Zusammenhang ist.
export type CorrelationStrength = "weak" | "moderate" | "strong";

/// Übliche Schwellen auf dem Betrag von `r`. Unter 0,2 wird gar nichts
/// berichtet — siehe `correlations(…)`.
export function strengthOf(coefficient: number): CorrelationStrength | null {
  const betrag = Math.abs(coefficient);
  if (betrag < 0.2) return null;
  if (betrag < 0.4) return "weak";
  if (betrag < 0.6) return "moderate";
  return "strong";
}

/// Ein gefundener Zusammenhang zwischen einem Habit und einer Journal-Größe.
///
/// Existiert nur, wenn er die Hürden aus `CorrelationRule` genommen hat — es
/// gibt keinen „schwachen" oder „unsicheren" Fall, den die Oberfläche noch
/// aussortieren müsste. Was hier ankommt, darf gezeigt werden.
export type Correlation = {
  habitId: string;
  metric: JournalMetric;
  /// Pearson, −1 bis 1.
  coefficient: number;
  strength: CorrelationStrength;
  /// Tage, an denen sowohl der Habit entschieden als auch die Größe erfasst war.
  dayCount: number;
  completedDays: number;
  completedAverage: number;
  missedAverage: number;
};

/// Um wie viel die Größe an erledigten Tagen höher liegt. Negativ heißt niedriger.
export function difference(korrelation: Correlation): number {
  return korrelation.completedAverage - korrelation.missedAverage;
}

// MARK: - Die Hürden, ab denen eine Aussage überhaupt gemacht wird

/// Gemeinsame Datenpunkte insgesamt.
export const CORRELATION_MINIMUM_DAYS = 14;
/// Und in **jeder** der beiden Gruppen.
///
/// Ohne diese zweite Hürde stünde hinter „an Tagen ohne Sport" womöglich ein
/// einziger Tag — ein Mittelwert aus einem Wert ist kein Mittelwert.
export const CORRELATION_MINIMUM_PER_GROUP = 5;
/// Untergrenze aus Sachgründen, unabhängig von der Datenmenge.
///
/// Bei sehr vielen Tagen wird auch ein Zusammenhang von 0,15 rechnerisch
/// bedeutsam — der Sache nach ist er es nicht.
export const CORRELATION_MINIMUM_COEFFICIENT = 0.2;

/// Die Zufallshürde, ausgedrückt als t-Wert.
///
/// Eine feste Schwelle auf `r` genügt nicht: bei 30 Tagen liegt die
/// Zufallsgrenze bei rund 0,36, bei 100 Tagen bei 0,26. Wer fest bei 0,2
/// abschneidet, meldet bei kleinen Mengen reines Rauschen als Befund — in der
/// Erprobung erschienen so sechs „Zusammenhänge", darunter einer mit einer
/// Größe, die als Zufallszahl erzeugt worden war.
///
/// 3,0 entspricht etwa p < 0,01 (zweiseitig) und ist damit strenger als
/// üblich. Das ist Absicht: über acht Habits und drei Größen werden zwei
/// Dutzend Paare gleichzeitig geprüft, und bei p < 0,05 wäre gut ein
/// Fehltreffer schon rechnerisch zu erwarten.
export const CORRELATION_CRITICAL_T = 3.0;

/// Der nötige Betrag von `r` bei dieser Zahl gemeinsamer Tage.
///
/// Aus `t = r · √(df / (1 − r²))` nach `r` aufgelöst.
export function requiredCoefficient(days: number): number {
  const df = days - 2;
  if (!(df > 0)) return 1;
  const t = CORRELATION_CRITICAL_T;
  return Math.max(CORRELATION_MINIMUM_COEFFICIENT, t / Math.sqrt(df + t * t));
}

/// Sucht Zusammenhänge zwischen Habits und dem Journal.
///
/// **Die Zurückhaltung ist Teil der Funktion.** Bei wenigen Tagen findet man in
/// Zufallsrauschen immer irgendeinen Zusammenhang; wird er angezeigt, glaubt man
/// ihn. Deshalb drei Hürden: mindestens `CORRELATION_MINIMUM_DAYS` gemeinsame
/// Tage, mindestens `CORRELATION_MINIMUM_PER_GROUP` in jeder Gruppe, und ein
/// Betrag über der Zufallsgrenze für *diese* Datenmenge — nicht über einer
/// festen Zahl. Wird eine Hürde gerissen, kommt kein abgeschwächtes Ergebnis,
/// sondern keins.
///
/// Und es bleibt bei „hängt zusammen": dass Sport den Schlaf verbessert, sagen
/// diese Daten nicht — vielleicht schläft man an Tagen besser, an denen ohnehin
/// alles leichter fällt.
export function correlations(
  habits: Habit[],
  entries: Entry[],
  dayLogs: DayLog[],
  exceptions: DayException[],
  from: CalendarDate,
  to: CalendarDate,
  today: CalendarDate,
): Correlation[] {
  const logsByDay: Record<string, DayLog> = Object.create(null);
  for (const log of dayLogs) {
    if (log.deletedAt != null) continue;
    // Der erste gewinnt — wie `uniquingKeysWith: { first, _ in first }`.
    if (!(log.date in logsByDay)) logsByDay[log.date] = log;
  }
  if (Object.keys(logsByDay).length === 0) return [];

  const result: Correlation[] = [];

  for (const habit of habits) {
    const statuses = dayStatuses(habit, entries, exceptions, from, to, today);

    for (const metric of JOURNAL_METRICS) {
      // Nur Tage, an denen beides feststeht: der Habit entschieden
      // (erledigt oder verpasst) und die Größe erfasst.
      const erledigt: number[] = [];
      const verpasst: number[] = [];
      for (const [date, status] of Object.entries(statuses)) {
        const log = logsByDay[date];
        if (!log) continue;
        const wert = metricValue(metric, log);
        if (wert == null) continue;
        if (status.code === "completed") erledigt.push(wert);
        else if (status.code === "missed") verpasst.push(wert);
      }

      const tage = erledigt.length + verpasst.length;
      if (tage < CORRELATION_MINIMUM_DAYS) continue;
      if (erledigt.length < CORRELATION_MINIMUM_PER_GROUP) continue;
      if (verpasst.length < CORRELATION_MINIMUM_PER_GROUP) continue;
      const r = pearson(erledigt, verpasst);
      if (r == null) continue;
      // Die Hürde sinkt mit wachsender Datenmenge — bei 30 Tagen braucht es
      // 0,49, bei 100 nur noch 0,29.
      if (Math.abs(r) < requiredCoefficient(tage)) continue;
      const staerke = strengthOf(r);
      if (!staerke) continue;

      result.push({
        habitId: habit.id, metric, coefficient: r, strength: staerke,
        dayCount: tage,
        completedDays: erledigt.length,
        completedAverage: erledigt.reduce((s, v) => s + v, 0) / erledigt.length,
        missedAverage: verpasst.reduce((s, v) => s + v, 0) / verpasst.length,
      });
    }
  }

  // Der deutlichste zuerst.
  return result.sort((a, b) => Math.abs(b.coefficient) - Math.abs(a.coefficient));
}

/// Pearson zwischen einer Ja/Nein-Größe (erledigt) und einer Zahl.
///
/// `null`, wenn die Journal-Werte keine Streuung haben — wer jeden Tag „3"
/// einträgt, hat keinen Zusammenhang, sondern eine Gewohnheit beim Eintragen.
export function pearson(erledigt: number[], verpasst: number[]): number | null {
  const x = [...erledigt.map(() => 1), ...verpasst.map(() => 0)];
  const y = [...erledigt, ...verpasst];
  const n = x.length;
  if (!(n > 1)) return null;

  const xMittel = x.reduce((s, v) => s + v, 0) / n;
  const yMittel = y.reduce((s, v) => s + v, 0) / n;
  let zaehler = 0, xQuadrat = 0, yQuadrat = 0;
  for (let i = 0; i < n; i++) {
    const dx = x[i]! - xMittel, dy = y[i]! - yMittel;
    zaehler += dx * dy;
    xQuadrat += dx * dx;
    yQuadrat += dy * dy;
  }
  if (!(xQuadrat > 0) || !(yQuadrat > 0)) return null;
  return zaehler / Math.sqrt(xQuadrat * yQuadrat);
}

/// Der Tagesstatus eines Habits über einen Zeitraum.
///
/// Eigene kleine Hilfsfunktion statt `stats(…)`, weil hier nur die Tage
/// gebraucht werden und nicht Streaks, Quote und Wochentagsverteilung dazu.
export function dayStatuses(
  habit: Habit,
  entries: Entry[],
  exceptions: DayException[],
  from: CalendarDate,
  to: CalendarDate,
  today: CalendarDate,
): Record<string, DayStatus> {
  const entriesByDay: Record<string, Entry> = Object.create(null);
  for (const entry of entries) {
    if (entry.deletedAt != null || entry.habitId !== habit.id) continue;
    entriesByDay[entry.date] = entry;
  }
  const perHabit: Record<string, DayException> = Object.create(null);
  const global: Record<string, DayException> = Object.create(null);
  for (const exception of exceptions) {
    if (exception.deletedAt != null) continue;
    if (exception.habitId === habit.id) perHabit[exception.date] = exception;
    else if (exception.habitId == null) global[exception.date] = exception;
  }

  const result: Record<string, DayStatus> = Object.create(null);
  for (const date of through(from, to)) {
    result[date] = status(
      habit, entriesByDay[date], perHabit[date] ?? global[date], date, today);
  }
  return result;
}
