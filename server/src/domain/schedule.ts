/// Portiert aus `apple/HabitKit/Sources/HabitCore/Models/Schedule.swift`.
///
/// Swifts `enum` mit assoziierten Werten wird zur unterschiedenen Vereinigung
/// über `kind` — und zwar genau in der Form, die Swifts `Codable` schon
/// schreibt. Damit ist der Typ zugleich das Übertragungsformat, ohne Umweg.

import type { CalendarDate, Weekday } from "./calendar.ts";

/// Wann ein Habit fällig ist.
export type Schedule =
  /// Jeden Tag.
  | { kind: "daily" }
  /// An festen Wochentagen.
  | { kind: "weekdays"; days: Weekday[] }
  /// n-mal pro Woche, der Tag ist egal. Wird wochenweise ausgewertet.
  | { kind: "timesPerWeek"; n: number }
  /// Alle n Tage, gerechnet ab `anchor`.
  | { kind: "everyNDays"; n: number; anchor: CalendarDate };

/// Ob ein einzelner Tag verpflichtend ist.
///
/// Bei `timesPerWeek` ist er das nicht: der Habit darf an jedem Tag erledigt
/// werden, deshalb ist ein Tag ohne Eintrag dort kein verpasster Tag, sondern
/// gar kein geplanter. Bewertet wird die Woche, nicht der Tag.
export function requiresSpecificDays(schedule: Schedule): boolean {
  return schedule.kind !== "timesPerWeek";
}

/// Wie viele Tage einer Woche erledigt sein müssen. Nur bei `timesPerWeek`
/// von Null verschieden.
export function weeklyTarget(schedule: Schedule): number | null {
  return schedule.kind === "timesPerWeek" ? schedule.n : null;
}

/// Wie ein Zielwert zu lesen ist.
export type Comparison =
  /// „mindestens" — 2 Liter Wasser trinken.
  | "atLeast"
  /// „höchstens" — maximal 30 Minuten Social Media.
  | "atMost";

export type Target = {
  value: number;
  unit: string;
  comparison: Comparison;
};

/// Zeitplan und Ziel gelten ab einem Datum.
///
/// Vergangene Tage werden mit der damals gültigen Regel bewertet. Ohne diese
/// Versionierung würde eine Zielerhöhung von 2 L auf 3 L rückwirkend alle
/// erfüllten Tage als verfehlt erscheinen lassen.
export type HabitRule = {
  effectiveFrom: CalendarDate;
  schedule: Schedule;
  target?: Target | null;
};
