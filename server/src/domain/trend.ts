/// Portiert aus `apple/HabitKit/Sources/HabitCore/Trend.swift`.

import type { CalendarDate } from "./calendar.ts";
import { addDays } from "./calendar.ts";
import type { DayException, Entry } from "./entry.ts";
import type { Habit } from "./habit.ts";
import { stats } from "./stats.ts";

/// Kurzfristige Entwicklung eines Habits.
///
/// `delta` ist die Differenz in Prozentpunkten (0...1) und bei `declining`
/// ebenfalls positiv — wie in Swift, wo beide Fälle den Betrag tragen.
export type Trend =
  /// Deutlich besser als im Vergleichszeitraum.
  | { readonly code: "improving"; readonly delta: number }
  | { readonly code: "stable" }
  /// Deutlich schlechter — das ist der Moment, in dem Eingreifen noch hilft.
  | { readonly code: "declining"; readonly delta: number };

/// Ab wie vielen Prozentpunkten Unterschied eine Richtung behauptet wird.
export const trendThreshold = 0.15;
/// Wie viele bewertete Einheiten je Seite mindestens vorliegen müssen.
export const trendMinimumSamples = 5;

/// Vergleicht die letzten `window` Tage mit den `window` davor.
///
/// Der heutige Tag bleibt außen vor: er ist noch nicht vorbei und würde den
/// aktuellen Zeitraum systematisch nach unten ziehen.
///
/// Gibt `null` zurück, wenn die Datenbasis auf einer der beiden Seiten zu dünn
/// ist — lieber keine Aussage als eine aus drei Tagen abgeleitete.
export function trend(
  habit: Habit,
  entries: Entry[],
  exceptions: DayException[],
  today: CalendarDate,
  window = 14,
): Trend | null {
  const recentEnd = addDays(today, -1);
  const recentStart = addDays(recentEnd, -(window - 1));
  const priorEnd = addDays(recentStart, -1);
  const priorStart = addDays(priorEnd, -(window - 1));

  const recent = stats(habit, entries, exceptions, recentStart, recentEnd, today);
  const prior = stats(habit, entries, exceptions, priorStart, priorEnd, today);

  if (recent.evaluatedCount < trendMinimumSamples) return null;
  if (prior.evaluatedCount < trendMinimumSamples) return null;
  if (recent.completionRate == null || prior.completionRate == null) return null;

  const delta = recent.completionRate - prior.completionRate;
  if (delta > trendThreshold) return { code: "improving", delta };
  if (delta < -trendThreshold) return { code: "declining", delta: -delta };
  return { code: "stable" };
}
