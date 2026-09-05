/// Portiert aus `apple/HabitKit/Sources/HabitCore/Totals.swift`.

import type { CalendarDate } from "./calendar.ts";
import { daysUntil, weekStart } from "./calendar.ts";
import type { Entry, EntryEvent } from "./entry.ts";
import type { Habit } from "./habit.ts";
import { epochMs } from "./timestamp.ts";

/// Was in einem Zeitraum zusammengekommen ist.
///
/// Beantwortet „wie viel habe ich diese Woche gemacht?" — eine andere Frage als
/// der Streak („wie lange schon?") und als die Quote („wie verlässlich?").
/// Bei einer Mengen- oder Zeit-Erfassung ist es oft die einzige, die zählt:
/// ob die fünf Stunden auf drei oder fünf Tage fielen, ist gleichgültig.
export type PeriodTotal = {
  from: CalendarDate;
  to: CalendarDate;
  /// Summe in der Einheit des Habits — bei Zeiterfassung Minuten.
  total: number;
  byDay: Record<string, number>;
  /// Schlüssel ist der Montag der jeweiligen Woche.
  byWeek: Record<string, number>;
  /// Tage mit einem Wert größer als null.
  activeDays: number;
  /// Zahl der Sitzungen, falls der Habit welche führt.
  sessionCount: number;
};

export function dayCount(total: PeriodTotal): number {
  return daysUntil(total.from, total.to) + 1;
}

/// Schnitt über die Tage **mit** Aktivität, nicht über alle.
///
/// Ein Schnitt über alle Tage beantwortet nichts: er sinkt, sobald man den
/// Zeitraum vergrößert, ohne dass sich am Verhalten etwas geändert hat.
export function averagePerActiveDay(total: PeriodTotal): number | null {
  return total.activeDays > 0 ? total.total / total.activeDays : null;
}

/// Summiert die Tageswerte eines Habits über einen Zeitraum.
///
/// Gelesen wird `Entry.value` und nicht die Sitzungen: der Store hält
/// `entry.value == Σ events` ohnehin aufrecht, und nur so zählen auch Habits
/// mit, die ihre Werte direkt eintragen statt über Sitzungen.
export function periodTotal(
  habit: Habit,
  entries: Entry[],
  events: EntryEvent[],
  from: CalendarDate,
  to: CalendarDate,
): PeriodTotal {
  const byDay: Record<string, number> = Object.create(null);
  for (const entry of entries) {
    if (entry.deletedAt != null || entry.habitId !== habit.id) continue;
    if (entry.date < from || entry.date > to) continue;
    byDay[entry.date] = (byDay[entry.date] ?? 0) + entry.value;
  }

  const byWeek: Record<string, number> = Object.create(null);
  for (const [date, value] of Object.entries(byDay)) {
    const montag = weekStart(date as CalendarDate);
    byWeek[montag] = (byWeek[montag] ?? 0) + value;
  }

  const relevanteSitzungen = events.filter(
    (e) => e.deletedAt == null && e.habitId === habit.id && e.date >= from && e.date <= to);

  const werte = Object.values(byDay);
  return {
    from, to,
    total: werte.reduce((summe, v) => summe + v, 0),
    byDay,
    byWeek,
    activeDays: werte.filter((v) => v > 0).length,
    sessionCount: relevanteSitzungen.length,
  };
}

/// Die Sitzungen eines Tages, nach Startzeit sortiert.
export function sessions(
  habit: Habit, date: CalendarDate, events: EntryEvent[],
): EntryEvent[] {
  return events
    .filter((e) => e.deletedAt == null && e.habitId === habit.id && e.date === date)
    .sort((a, b) => epochMs(a.at) - epochMs(b.at));
}
