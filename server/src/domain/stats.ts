/// Portiert aus `apple/HabitKit/Sources/HabitCore/Stats.swift`.

import type { CalendarDate, Weekday } from "./calendar.ts";
import { addDays, through, weekday, weekStart as wochenStart } from "./calendar.ts";
import type { DayException, Entry } from "./entry.ts";
import { removesDayFromSchedule } from "./entry.ts";
import type { Habit } from "./habit.ts";
import { isScheduled, ruleOn } from "./resolution.ts";
import { weeklyTarget } from "./schedule.ts";
import { status } from "./completion.ts";
import { type DayStatus, countsTowardRate, isCompleted } from "./dayStatus.ts";

/// Ob Streaks in Tagen oder in Wochen gezählt werden.
///
/// `timesPerWeek` wird wochenweise bewertet: „3× pro Woche" hat keine
/// Tages-Streaks, sondern Wochen-Streaks.
export type StreakUnit = "days" | "weeks";

/// Status jedes Tages eines Zeitraums. Ein einfaches Objekt statt einer `Map`:
/// der Schlüssel ist schon eine Zeichenkette, und so geht die Auswertung ohne
/// Umformung durch `JSON.stringify`.
export type DayStatusMap = Record<string, DayStatus>;

export type HabitStats = {
  currentStreak: number;
  longestStreak: number;
  streakUnit: StreakUnit;
  /// Erfüllt geteilt durch bewertet. `null`, wenn nichts zu bewerten war.
  completionRate: number | null;
  completedCount: number;
  evaluatedCount: number;
  /// Status jedes Tages im angefragten Zeitraum — Grundlage für Heatmap und Kalender.
  days: DayStatusMap;
  /// Je Wochentag der Anteil erledigter an geplanten Tagen. Fehlt ein Wochentag,
  /// gab es dafür keine Datengrundlage.
  weekdayBreakdown: Partial<Record<Weekday, number>>;
};

/// Zusammengeführte Sicht auf Einträge und Ausnahmen eines Habits.
type DayIndex = {
  entries: Record<string, Entry>;
  exceptions: Record<string, DayException>;
};

function dayIndex(habit: Habit, entries: Entry[], exceptions: DayException[]): DayIndex {
  const e: Record<string, Entry> = Object.create(null);
  for (const entry of entries) {
    if (entry.deletedAt == null && entry.habitId === habit.id) e[entry.date] = entry;
  }

  // Eine habit-spezifische Ausnahme schlägt die globale desselben Tages:
  // ein bewusster Ruhetag für genau diesen Habit ist die genauere Aussage.
  const x: Record<string, DayException> = Object.create(null);
  for (const ex of exceptions) {
    if (ex.deletedAt != null) continue;
    if (ex.habitId != null && ex.habitId !== habit.id) continue;
    const vorhanden = x[ex.date];
    if (vorhanden && vorhanden.habitId != null && ex.habitId == null) continue;
    x[ex.date] = ex;
  }

  return { entries: e, exceptions: x };
}

/// Vollständige Auswertung eines Habits über einen Zeitraum.
///
/// `today` wird übergeben statt ermittelt — die Domäne kennt keine Systemuhr,
/// dadurch sind alle Ergebnisse reproduzierbar und testbar.
export function stats(
  habit: Habit,
  entries: Entry[],
  exceptions: DayException[],
  from: CalendarDate,
  to: CalendarDate,
  today: CalendarDate,
): HabitStats {
  const index = dayIndex(habit, entries, exceptions);
  const range = through(from, to);

  const days: DayStatusMap = Object.create(null);
  for (const date of range) {
    days[date] = status(habit, index.entries[date], index.exceptions[date], date, today);
  }

  // Welche Regel gerade gilt, entscheidet über die Zähleinheit. Bei einem
  // Zeitplanwechsel mitten im Zeitraum wird also nach dem aktuellen Modus
  // bewertet — das ist die Frage, die der Nutzer beim Draufschauen stellt.
  const anchor = to < today ? to : today;
  const regel = ruleOn(habit, anchor);
  const unit: StreakUnit =
    regel && weeklyTarget(regel.schedule) != null ? "weeks" : "days";

  const wochentage = weekdayBreakdown(habit, days, range, today);

  if (unit === "days") {
    const evaluated = range.filter((d) => d <= today && countsTowardRate(days[d]!));
    const completed = evaluated.filter((d) => isCompleted(days[d]!));
    return {
      currentStreak: currentDayStreak(days, from, anchor, today),
      longestStreak: longestDayStreak(days, range, anchor),
      streakUnit: "days",
      completionRate: evaluated.length === 0 ? null : completed.length / evaluated.length,
      completedCount: completed.length,
      evaluatedCount: evaluated.length,
      days,
      weekdayBreakdown: wochentage,
    };
  }

  const weeks = weekSummaries(habit, days, from, to, today);
  // Nur abgeschlossene Wochen gehen in die Quote ein — eine angebrochene
  // Woche würde sie sonst systematisch nach unten ziehen.
  const finished = weeks.filter((w) => w.isOver);
  const hit = finished.filter(isFulfilledWeek);
  return {
    currentStreak: currentWeekStreak(weeks),
    longestStreak: longestWeekStreak(weeks),
    streakUnit: "weeks",
    completionRate: finished.length === 0 ? null : hit.length / finished.length,
    completedCount: hit.length,
    evaluatedCount: finished.length,
    days,
    weekdayBreakdown: wochentage,
  };
}

// MARK: - Tages-Streaks

function currentDayStreak(
  days: DayStatusMap, from: CalendarDate, anchor: CalendarDate, today: CalendarDate,
): number {
  let streak = 0;
  let date = anchor;
  while (date >= from) {
    switch (days[date]?.code) {
      case "completed":
        streak += 1;
        break;
      case "missed":
        return streak;
      case "partial":
        // Nur der laufende Tag kann `partial` sein; er ist noch nicht verloren.
        if (date !== today) return streak;
        break;
      default:
        break; // Ausnahme, nicht geplant, Zukunft, gar nichts:
               // unterbricht nicht und verlängert nicht
    }
    date = addDays(date, -1);
  }
  return streak;
}

function longestDayStreak(
  days: DayStatusMap, range: CalendarDate[], anchor: CalendarDate,
): number {
  let best = 0;
  let run = 0;
  for (const date of range) {
    if (date > anchor) continue;
    switch (days[date]?.code) {
      case "completed":
        run += 1;
        best = Math.max(best, run);
        break;
      case "missed":
        run = 0;
        break;
      default:
        break;
    }
  }
  return best;
}

// MARK: - Wochen-Streaks (timesPerWeek)

export type WeekSummary = {
  start: CalendarDate;
  completed: number;
  required: number;
  /// Geplante Tage, die noch kommen — nur in der laufenden Woche > 0.
  remaining: number;
  isOver: boolean;
  /// Komplett pausierte oder außerhalb des Habit-Zeitraums liegende Woche.
  isVoid: boolean;
};

export function isFulfilledWeek(week: WeekSummary): boolean {
  return week.completed >= week.required;
}

/// Ob das Wochenziel rechnerisch noch erreichbar ist.
export function isStillPossible(week: WeekSummary): boolean {
  return week.completed + week.remaining >= week.required;
}

/// Das an einem Tag gültige Wochenziel, `null` bei jedem anderen Zeitplan.
function wochenziel(habit: Habit, date: CalendarDate): number | null {
  const regel = ruleOn(habit, date);
  return regel ? weeklyTarget(regel.schedule) : null;
}

export function weekSummaries(
  habit: Habit, days: DayStatusMap,
  from: CalendarDate, to: CalendarDate, today: CalendarDate,
): WeekSummary[] {
  const result: WeekSummary[] = [];
  let start = wochenStart(from);
  const last = wochenStart(to < today ? to : today);

  while (start <= last) {
    const weekDays = through(start, addDays(start, 6));
    let scheduled = 0;
    let completed = 0;
    let remaining = 0;

    for (const date of weekDays) {
      const status = days[date];
      if (!status) continue;
      switch (status.code) {
        case "completed":
          scheduled += 1;
          completed += 1;
          break;
        case "missed":
        case "frozen":
          scheduled += 1;
          break;
        case "partial":
          // Heute: zählt zur Woche und ist noch erreichbar.
          scheduled += 1;
          remaining += 1;
          break;
        case "future":
          if (isScheduled(habit, date)) { scheduled += 1; remaining += 1; }
          break;
        case "notScheduled":
          // Bei timesPerWeek ist jeder Tag im aktiven Zeitraum planbar;
          // `notScheduled` heißt hier: außerhalb des Habits oder pausiert.
          if (isScheduled(habit, date)) scheduled += 1;
          break;
        case "paused":
        case "skipped":
          break; // nimmt den Tag aus der Woche
      }
    }

    // Fällt der Wochenanfang vor die erste Regel, entscheidet der letzte Tag
    // der Woche — sonst hätte die Anfangswoche eines Habits gar kein Ziel.
    const spaeter = addDays(start, 6);
    const n = wochenziel(habit, start) ?? wochenziel(habit, spaeter < to ? spaeter : to) ?? 0;

    // Pausierte Tage senken das Wochenziel anteilig — nach einer halben
    // Urlaubswoche noch drei Einheiten zu verlangen wäre unfair.
    const required = scheduled === 0 ? 0 : Math.max(1, Math.floor((n * scheduled) / 7));

    result.push({
      start,
      completed,
      required,
      remaining,
      isOver: addDays(start, 6) < today,
      isVoid: scheduled === 0 || n === 0,
    });
    start = addDays(start, 7);
  }
  return result;
}

function currentWeekStreak(weeks: WeekSummary[]): number {
  let streak = 0;
  for (const week of [...weeks].reverse()) {
    if (week.isVoid) continue;                                  // pausierte Woche überspringt
    if (isFulfilledWeek(week)) { streak += 1; continue; }
    if (!week.isOver && isStillPossible(week)) continue;        // läuft noch
    return streak;
  }
  return streak;
}

function longestWeekStreak(weeks: WeekSummary[]): number {
  let best = 0;
  let run = 0;
  for (const week of weeks) {
    if (week.isVoid) continue;
    if (isFulfilledWeek(week)) {
      run += 1;
      best = Math.max(best, run);
    } else if (week.isOver) {
      run = 0;
    } else if (!isStillPossible(week)) {
      run = 0;
    }
  }
  return best;
}

// MARK: - Wochentage

/// Anteil erledigter an geplanten Tagen je Wochentag.
///
/// Nenner sind alle vergangenen Tage, an denen der Habit planbar war — bei
/// `timesPerWeek` also jeder Tag im aktiven Zeitraum. Dadurch beantwortet die
/// Auswertung für beide Zeitplan-Arten dieselbe Frage: „an welchem Wochentag
/// klappt es?"
export function weekdayBreakdown(
  habit: Habit, days: DayStatusMap, range: CalendarDate[], today: CalendarDate,
): Partial<Record<Weekday, number>> {
  const total = new Map<Weekday, number>();
  const hit = new Map<Weekday, number>();

  for (const date of range) {
    if (date >= today) continue;
    const status = days[date];
    if (!status) continue;
    // Ein Freeze bleibt drin — er rettet den Streak, nimmt den Tag aber nicht
    // aus dem Zeitplan. Urlaub und Ruhetag fallen heraus.
    if ((status.code === "frozen" || status.code === "paused" || status.code === "skipped")
        && removesDayFromSchedule(status.code)) continue;
    if (!isScheduled(habit, date)) continue;
    const tag = weekday(date);
    total.set(tag, (total.get(tag) ?? 0) + 1);
    if (isCompleted(status)) hit.set(tag, (hit.get(tag) ?? 0) + 1);
  }

  const ergebnis: Partial<Record<Weekday, number>> = {};
  for (const [tag, anzahl] of total) ergebnis[tag] = (hit.get(tag) ?? 0) / anzahl;
  return ergebnis;
}
