/// Portiert aus `apple/HabitKit/Sources/HabitCore/Overview.swift`.

import type { CalendarDate } from "./calendar.ts";
import {
  addDays, addMonths, monthEnd, monthStart, through, weekEnd, weekStart,
} from "./calendar.ts";
import type { DayException, Entry } from "./entry.ts";
import { removesDayFromSchedule } from "./entry.ts";
import type { Habit } from "./habit.ts";
import { isRequired } from "./resolution.ts";
import { status } from "./completion.ts";
import { isCompleted } from "./dayStatus.ts";

/// Ein Tag über alle Habits hinweg zusammengefasst.
export type DaySummary = {
  date: CalendarDate;
  /// Wie viele Habits an diesem Tag erfüllt waren.
  completed: number;
  /// Wie viele an diesem Tag zählten — siehe `overview(...)` zur Definition.
  scheduled: number;
};

/// Anteil erledigter Habits, `null` wenn nichts anstand.
///
/// Ein Tag ohne Plan ist ausdrücklich nicht „0 %" — er hat kein Ergebnis.
export function share(summary: DaySummary): number | null {
  return summary.scheduled === 0 ? null : summary.completed / summary.scheduled;
}

/// Alles erledigt, was anstand. Tage ohne Plan zählen nicht als perfekt.
export function isPerfect(summary: DaySummary): boolean {
  return summary.scheduled > 0 && summary.completed === summary.scheduled;
}

/// Fasst alle Habits je Tag zusammen — Grundlage für die gesammelte Heatmap.
///
/// **Was in den Nenner kommt**, ist die einzige interessante Entscheidung hier.
/// Ein `timesPerWeek`-Habit ist an jedem Tag *planbar*, aber an keinem
/// verpflichtend. Zählte er täglich mit, würde ein 3×/Woche-Habit an vier von
/// sieben Tagen als „nicht erfüllt" erscheinen und die Übersicht dauerhaft
/// eintrüben, obwohl das Wochenziel erreicht ist.
///
/// Deshalb zählt ein Habit an einem Tag, wenn er dort **verpflichtend** war
/// oder wenn er **erfüllt** wurde. Ein an diesem Tag erledigter
/// `timesPerWeek`-Habit geht also in Zähler und Nenner ein, ein nicht
/// erledigter in keinen von beiden. Der Anteil kann dadurch nie über 100 %
/// steigen, und freiwillig Erledigtes wird belohnt statt ignoriert.
///
/// Pausierte und übersprungene Tage fallen für den jeweiligen Habit heraus,
/// eingefrorene bleiben im Nenner — ein Freeze rettet den Streak, schönt die
/// Statistik aber nicht.
export function overview(
  habits: Habit[],
  entries: Entry[],
  exceptions: DayException[],
  from: CalendarDate,
  to: CalendarDate,
  today: CalendarDate,
): Record<string, DaySummary> {
  // Einträge und Ausnahmen einmal indizieren statt je Tag zu filtern.
  const entriesByHabit = new Map<string, Record<string, Entry>>();
  for (const entry of entries) {
    if (entry.deletedAt != null) continue;
    let je = entriesByHabit.get(entry.habitId);
    if (!je) { je = Object.create(null) as Record<string, Entry>; entriesByHabit.set(entry.habitId, je); }
    je[entry.date] = entry;
  }

  const perHabit = new Map<string, Record<string, DayException>>();
  const global: Record<string, DayException> = Object.create(null);
  for (const exception of exceptions) {
    if (exception.deletedAt != null) continue;
    if (exception.habitId != null) {
      let je = perHabit.get(exception.habitId);
      if (!je) { je = Object.create(null) as Record<string, DayException>; perHabit.set(exception.habitId, je); }
      je[exception.date] = exception;
    } else {
      global[exception.date] = exception;
    }
  }

  const result: Record<string, DaySummary> = Object.create(null);

  for (const date of through(from, to)) {
    let completed = 0;
    let scheduled = 0;

    for (const habit of habits) {
      // Eine habit-spezifische Ausnahme ist die genauere Aussage als eine globale.
      const exception = perHabit.get(habit.id)?.[date] ?? global[date];

      const dayStatus = status(
        habit, entriesByHabit.get(habit.id)?.[date], exception, date, today);

      if (isCompleted(dayStatus)) {
        completed += 1;
        scheduled += 1;
      } else if (isRequired(habit, date)
                 && !(exception ? removesDayFromSchedule(exception.kind) : false)) {
        scheduled += 1;
      }
    }

    result[date] = { date, completed, scheduled };
  }

  return result;
}

/// Kennzahlen über alle Habits für die Kopfzeile der Übersicht.
export type OverviewStats = {
  /// Tage, an denen alles Anstehende erledigt war.
  perfectDays: number;
  /// Tage mit Plan, unabhängig vom Ergebnis.
  daysWithPlan: number;
  /// Summe aller Erledigungen im Zeitraum.
  totalCompletions: number;
  /// Aktuelle Serie perfekter Tage, endend heute.
  perfectStreak: number;
  /// Höchste Zahl an Erledigungen an einem Tag — Maßstab für die Farbskala.
  busiestDay: number;
};

export function overviewStats(
  summaries: Record<string, DaySummary>,
  from: CalendarDate,
  to: CalendarDate,
  today: CalendarDate,
): OverviewStats {
  const ende = to < today ? to : today;
  const past = through(from, ende).map((d) => summaries[d]).filter((s) => s !== undefined);

  let streak = 0;
  let date = ende;
  while (date >= from) {
    const summary = summaries[date];
    if (!summary) break;
    if (isPerfect(summary)) {
      streak += 1;
    } else if (summary.scheduled === 0) {
      // Ein Tag ohne Plan unterbricht nichts — es gab nichts zu verpassen.
    } else if (date === today && summary.completed < summary.scheduled) {
      // Der laufende Tag ist noch nicht verloren.
    } else {
      break;
    }
    date = addDays(date, -1);
  }

  return {
    perfectDays: past.filter(isPerfect).length,
    daysWithPlan: past.filter((s) => s.scheduled > 0).length,
    totalCompletions: past.reduce((summe, s) => summe + s.completed, 0),
    perfectStreak: streak,
    busiestDay: past.reduce((groesste, s) => Math.max(groesste, s.completed), 0),
  };
}

// MARK: - Farbstufen

/// Wonach sich die Sättigung eines Tages in der Übersichts-Heatmap richtet.
export type IntensityScale =
  /// Wie viele Habits erledigt wurden — das GitHub-Vorbild.
  | "count"
  /// Welcher Anteil des an diesem Tag Anstehenden erledigt wurde.
  | "share";

/// In welche von fünf Farbstufen ein Tag fällt: 0 = leer, 4 = am kräftigsten.
///
/// Bewusst hier und nicht in der View: die WebApp muss dieselbe Einstufung
/// treffen, sonst zeigen Mac und Browser für denselben Bestand verschiedene
/// Bilder. Wie Stufe 3 dann *aussieht*, ist Sache der jeweiligen Oberfläche.
///
/// `busiestDay` ist die Bezugsgröße für `count` — die höchste Zahl an
/// Erledigungen im gezeigten Zeitraum. Damit skaliert sich das Bild selbst:
/// wer sechs Habits führt, bekommt dieselbe Bandbreite wie jemand mit zweien.
export function intensityLevel(
  summary: DaySummary, scale: IntensityScale, busiestDay: number,
): number {
  if (scale === "count") {
    if (!(busiestDay > 0) || !(summary.completed > 0)) return 0;
    const ratio = summary.completed / busiestDay;
    return Math.min(4, Math.max(1, Math.ceil(ratio * 4)));
  }
  const anteil = share(summary);
  if (anteil == null || !(anteil > 0)) return 0;
  return Math.min(4, Math.max(1, Math.ceil(anteil * 4)));
}

// MARK: - Ausschnitt

/// Welcher Zeitraum in der Übersicht gezeigt wird.
export type OverviewSpan = "week" | "month" | "year";

/// Der abgedeckte Zeitraum um einen Ankertag herum.
///
/// Woche und Monat rasten am Kalender ein (Montag bis Sonntag, Erster bis
/// Letzter). Das Jahr sind die 53 Wochen, die auf die Ankerwoche enden —
/// dieselbe Bandbreite, die das GitHub-Vorbild zeigt, und immer an einer
/// Wochengrenze, damit die sieben Zeilen der Heatmap aufgehen.
export function spanRange(
  span: OverviewSpan, anchor: CalendarDate,
): { from: CalendarDate; to: CalendarDate } {
  switch (span) {
    case "week": return { from: weekStart(anchor), to: weekEnd(anchor) };
    case "month": return { from: monthStart(anchor), to: monthEnd(anchor) };
    case "year": return { from: addDays(weekStart(anchor), -7 * 52), to: weekEnd(anchor) };
  }
}

/// Der Anker, `steps` Ausschnitte weiter (negativ: zurück).
export function spanShift(
  span: OverviewSpan, anchor: CalendarDate, steps: number,
): CalendarDate {
  switch (span) {
    case "week": return addDays(anchor, 7 * steps);
    case "month": return addMonths(anchor, steps);
    case "year": return addMonths(anchor, 12 * steps);
  }
}

/// Wie viele Tage der Ausschnitt höchstens umfasst — für das Nachladen.
export function spanMaximumDays(span: OverviewSpan): number {
  switch (span) {
    case "week": return 7;
    case "month": return 31;
    case "year": return 371;
  }
}
