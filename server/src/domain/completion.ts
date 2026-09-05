/// Portiert aus `apple/HabitKit/Sources/HabitCore/Completion.swift`.

import type { CalendarDate } from "./calendar.ts";
import type { DayException, Entry } from "./entry.ts";
import { removesDayFromSchedule } from "./entry.ts";
import type { Habit } from "./habit.ts";
import { isFulfilled, isRequired, isScheduled, progress } from "./resolution.ts";
import {
  COMPLETED, FUTURE, MISSED, NOT_SCHEDULED,
  type DayStatus, excepted, partial,
} from "./dayStatus.ts";

/// Bewertet einen einzelnen Tag.
///
/// Die Reihenfolge der Prüfungen ist bedeutungstragend:
/// Zukunft schlägt Ausnahme, Ausnahme schlägt Zeitplan, Erfüllung schlägt Freeze.
export function status(
  habit: Habit,
  entry: Entry | null | undefined,
  exception: DayException | null | undefined,
  date: CalendarDate,
  today: CalendarDate,
): DayStatus {
  if (date > today) return FUTURE;

  // Urlaub und Ruhetage nehmen den Tag komplett aus dem Zeitplan — auch dann,
  // wenn er sonst gar nicht geplant gewesen wäre. Das hält die Anzeige ehrlich.
  if (exception && removesDayFromSchedule(exception.kind)) return excepted(exception.kind);

  if (!isScheduled(habit, date)) return NOT_SCHEDULED;

  const value = entry?.value ?? 0;
  if (isFulfilled(habit, value, date)) return COMPLETED;

  // Der laufende Tag ist noch nicht verloren.
  if (date === today) return partial(progress(habit, value, date));

  if (exception && exception.kind === "frozen") return excepted("frozen");

  // Bei `timesPerWeek` ist ein leerer Tag kein Versäumnis, sondern nur ein Tag,
  // an dem nichts passiert ist — bewertet wird dort die Woche.
  return isRequired(habit, date) ? MISSED : NOT_SCHEDULED;
}
