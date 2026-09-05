/// Portiert aus `apple/HabitKit/Sources/HabitCore/Resolution.swift`.
///
/// In Swift sind das Methoden auf `Habit`; hier freie Funktionen, deren erstes
/// Argument der Habit ist. Die Reihenfolge und die Namen bleiben gleich.

import type { CalendarDate } from "./calendar.ts";
import { daysUntil, weekday } from "./calendar.ts";
import type { Habit } from "./habit.ts";
import type { HabitRule, Target } from "./schedule.ts";
import { requiresSpecificDays } from "./schedule.ts";

/// Die an diesem Tag gültige Regel: die letzte, deren `effectiveFrom` nicht
/// in der Zukunft liegt.
///
/// `null` bedeutet, dass der Tag vor der ersten Regel liegt — dann gab es den
/// Habit an diesem Tag schlicht noch nicht.
export function ruleOn(habit: Habit, date: CalendarDate): HabitRule | null {
  let ergebnis: HabitRule | null = null;
  for (const regel of habit.rules) {
    // `rules` ist aufsteigend sortiert, die letzte passende gewinnt.
    if (regel.effectiveFrom <= date) ergebnis = regel;
  }
  return ergebnis;
}

/// Das an diesem Tag gültige Ziel.
export function targetOn(habit: Habit, date: CalendarDate): Target | null {
  return ruleOn(habit, date)?.target ?? null;
}

/// Ob der Habit an diesem Tag überhaupt zur Debatte steht — ohne Ausnahmen.
///
/// Bei `timesPerWeek` ist das jeder Tag: erledigt werden darf an jedem, die
/// Bewertung passiert wochenweise.
export function isScheduled(habit: Habit, date: CalendarDate): boolean {
  if (habit.startsOn != null && date < habit.startsOn) return false;
  if (habit.endsOn != null && date > habit.endsOn) return false;
  if (habit.archivedOn != null && date > habit.archivedOn) return false;
  const regel = ruleOn(habit, date);
  if (!regel) return false;

  switch (regel.schedule.kind) {
    case "daily":
      return true;
    case "weekdays":
      return regel.schedule.days.includes(weekday(date));
    case "timesPerWeek":
      return true;
    case "everyNDays": {
      const { n, anchor } = regel.schedule;
      if (!(n > 0) || date < anchor) return false;
      return daysUntil(anchor, date) % n === 0;
    }
  }
}

/// Ob ein Tag ohne Erfüllung als verpasst gilt.
///
/// Trennt `timesPerWeek` ab: dort ist ein leerer Dienstag kein Versäumnis,
/// wenn Montag, Mittwoch und Freitag erledigt wurden.
export function isRequired(habit: Habit, date: CalendarDate): boolean {
  if (!isScheduled(habit, date)) return false;
  const regel = ruleOn(habit, date);
  return regel ? requiresSpecificDays(regel.schedule) : false;
}

/// Ob der Wert eines Tages das damals gültige Ziel erfüllt.
export function isFulfilled(habit: Habit, value: number, date: CalendarDate): boolean {
  switch (habit.kind) {
    case "binary":
      return value >= 1;
    case "avoid":
      // Kein Eintrag heißt Erfolg — gemeldet werden nur Verstöße.
      return value === 0;
    case "quantity": {
      const ziel = targetOn(habit, date);
      if (!ziel) return value > 0;
      return ziel.comparison === "atLeast" ? value >= ziel.value : value <= ziel.value;
    }
  }
}

/// Fortschritt eines Tages als 0...1 — für den Ring in der Heute-Ansicht.
export function progress(habit: Habit, value: number, date: CalendarDate): number {
  switch (habit.kind) {
    case "binary":
      return value >= 1 ? 1 : 0;
    case "avoid":
      return value === 0 ? 1 : 0;
    case "quantity": {
      const ziel = targetOn(habit, date);
      if (!ziel || !(ziel.value > 0)) return value > 0 ? 1 : 0;
      if (ziel.comparison === "atLeast") return Math.min(1, Math.max(0, value / ziel.value));
      // Beim Limit ist „weniger" besser: voll, solange nichts verbraucht ist.
      return value <= ziel.value ? 1 : 0;
    }
  }
}
