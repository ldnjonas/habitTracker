/// Portiert aus `apple/HabitKit/Sources/HabitCore/Models/Habit.swift`.

import type { CalendarDate } from "./calendar.ts";
import type { HabitRule } from "./schedule.ts";
import type { TimeOfDay } from "./weekday.ts";
import type { Timestamp } from "./timestamp.ts";

export type HabitKind =
  /// Erledigt oder nicht.
  | "binary"
  /// Menge gegen ein Ziel.
  | "quantity"
  /// Vermeidung — gemeldet werden nur Verstöße.
  | "avoid";

/// Woher ein Eintrag stammt. Wichtig, damit ein späterer HealthKit-Abgleich
/// niemals eine manuelle Korrektur überschreibt.
export type EntrySource = "manual" | "healthKit" | "shortcut" | "api" | "importedFile";

/// Verknüpfung zu Apple Health. In v1 nur im Modell, noch ohne Auswertung.
export type HealthKitLink = {
  typeIdentifier: string; // z. B. "HKQuantityTypeIdentifierStepCount"
  unit: string;           // z. B. "count"
  aggregation: string;    // "sum" | "max" | "latest"
};

export type Habit = {
  id: string;
  userId: string;
  name: string;
  notes?: string | null;
  kind: HabitKind;
  /// Nach `effectiveFrom` aufsteigend sortiert; siehe `ruleOn`.
  rules: HabitRule[];
  colorHex: string;
  symbol: string;
  sortOrder: number;
  tagIds: string[];
  timeOfDay?: TimeOfDay | null;
  preferredTime?: string | null; // "07:30"
  tracksTime: boolean;
  startsOn?: CalendarDate | null;
  endsOn?: CalendarDate | null;
  healthKitLink?: HealthKitLink | null;
  createdAt: Timestamp;
  updatedAt: Timestamp;
  deletedAt?: Timestamp | null;
  /// Archiviert ist nicht gelöscht: der Habit verschwindet aus „Heute",
  /// bleibt aber in Verlauf und Statistik erhalten.
  ///
  /// Bewusst ein Kalendertag und kein Zeitstempel — die Domäne muss ab welchem
  /// *Tag* nicht mehr geplant wird auswerten können, ohne eine Zeitzone zu kennen.
  archivedOn?: CalendarDate | null;
};

/// Platzhalter, solange die App ohne Server läuft. Steht ab Tag 1 in jeder
/// Zeile, damit der spätere Login keine Datenmigration braucht.
export const LOCAL_USER_ID = "local";

export function isArchived(habit: Habit): boolean {
  return habit.archivedOn != null;
}

export function isChallenge(habit: Habit): boolean {
  return habit.startsOn != null && habit.endsOn != null;
}

/// Stellt die Reihenfolge her, die `ruleOn` voraussetzt.
///
/// In Swift erledigt das der Initialisierer von `Habit`; hier ist ein Habit ein
/// einfaches Objekt, das genauso gut aus JSON kommen kann. Deshalb wird an der
/// Grenze sortiert — beim Einlesen, nicht bei jeder Auswertung.
export function sortRules(habit: Habit): Habit {
  return { ...habit, rules: [...habit.rules].sort((a, b) => (a.effectiveFrom < b.effectiveFrom ? -1 : a.effectiveFrom > b.effectiveFrom ? 1 : 0)) };
}

export type Tag = {
  id: string;
  userId: string;
  name: string;
  colorHex: string;
  sortOrder: number;
  createdAt: Timestamp;
  updatedAt: Timestamp;
  deletedAt?: Timestamp | null;
};
