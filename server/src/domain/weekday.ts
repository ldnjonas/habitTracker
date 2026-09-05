/// Portiert aus `apple/HabitKit/Sources/HabitCore/Models/Weekday.swift`.
///
/// Der Typ `Weekday` selbst steht in `calendar.ts` — dort wird er gerechnet,
/// und `calendar.ts` soll von nichts abhängen. Hier steht, was ihn *deutet*.

import type { Weekday } from "./calendar.ts";
export type { Weekday };

export const WOCHENTAGE: readonly Weekday[] = [1, 2, 3, 4, 5, 6, 7];

export function isWeekend(tag: Weekday): boolean {
  return tag === 6 || tag === 7;
}

/// Grober Tagesabschnitt. Sortiert die Heute-Ansicht und ist später die
/// Grundlage dafür, wann ein Reminder feuert.
export type TimeOfDay = "morning" | "afternoon" | "evening" | "night";

export const TAGESZEITEN: readonly TimeOfDay[] = ["morning", "afternoon", "evening", "night"];

/// Position in `TAGESZEITEN` — der Ersatz für Swifts `Comparable`.
export function timeOfDayOrder(zeit: TimeOfDay): number {
  return TAGESZEITEN.indexOf(zeit);
}
