/// Portiert aus `apple/HabitKit/Sources/HabitCore/DayStatus.swift`.
///
/// Swifts `enum` mit assoziierten Werten wird zur unterschiedenen Vereinigung.
/// Unterschieden wird über `code` — genau die Zeichenkette, die dort schon für
/// Fixtures und Serialisierung gedacht war. Damit ist `.excepted(kind)` hier
/// nicht verschachtelt, sondern trägt die Ausnahmeart direkt als `code`.

import type { ExceptionKind } from "./entry.ts";

/// Wie ein einzelner Tag für einen Habit ausgegangen ist.
export type DayStatus =
  /// Ziel erreicht.
  | { readonly code: "completed" }
  /// Heute, noch nicht fertig. `progress` ist der Fortschritt (0...1).
  /// Ein *vergangener* Tag ist nie `partial`, sondern `missed` — halb erledigt
  /// ist rückblickend nicht erledigt.
  | { readonly code: "partial"; readonly progress: number }
  /// Geplanter Tag in der Vergangenheit ohne Erfüllung.
  | { readonly code: "missed" }
  /// Ausnahme: eingefroren, pausiert oder bewusst übersprungen.
  | { readonly code: ExceptionKind }
  /// An diesem Tag war der Habit nicht fällig.
  | { readonly code: "notScheduled" }
  /// Liegt in der Zukunft.
  | { readonly code: "future" };

export const COMPLETED: DayStatus = { code: "completed" };
export const MISSED: DayStatus = { code: "missed" };
export const NOT_SCHEDULED: DayStatus = { code: "notScheduled" };
export const FUTURE: DayStatus = { code: "future" };

export function partial(progress: number): DayStatus {
  return { code: "partial", progress };
}

export function excepted(kind: ExceptionKind): DayStatus {
  return { code: kind };
}

/// Zählt für Streak und Completion-Rate als Erfolg.
export function isCompleted(status: DayStatus): boolean {
  return status.code === "completed";
}

/// Ob dieser Tag im Nenner der Completion-Rate landet.
///
/// Ein eingefrorener Tag zählt weiter als verpasst — ein Freeze rettet den
/// Streak, schönt aber nicht die Statistik. Urlaub und Ruhetage fallen ganz
/// heraus, weil sie nie vorgesehen waren.
///
/// Der laufende Tag ist noch nicht entschieden. Zählte er mit, stünde die
/// Quote jeden Morgen schlechter da und erholte sich erst am Abend.
export function countsTowardRate(status: DayStatus): boolean {
  switch (status.code) {
    case "completed": case "missed": case "frozen": return true;
    case "partial": case "paused": case "skipped":
    case "notScheduled": case "future": return false;
  }
}
