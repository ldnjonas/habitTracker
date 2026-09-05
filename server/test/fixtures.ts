/// Zugriff auf die geteilten Fixtures unter `spec/fixtures/` und die Bausteine,
/// aus denen sie ihre Domänen-Objekte zusammensetzen.
///
/// Dieselben Dateien liest `apple/HabitKit/Tests/HabitCoreTests/Fixture.swift`.
/// Das ist der Vertrag, der die Swift- und die TypeScript-Fassung der Domäne
/// davon abhält, auseinanderzulaufen: weicht eine Zahl ab, schlägt eine Seite
/// fehl — statt dass Mac und Browser stillschweigend Verschiedenes anzeigen.

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

import type { CalendarDate } from "../src/domain/calendar.ts";
import type { DayException, Entry, ExceptionKind } from "../src/domain/entry.ts";
import type { Habit, HabitKind } from "../src/domain/habit.ts";
import { LOCAL_USER_ID, sortRules } from "../src/domain/habit.ts";
import type { HabitRule } from "../src/domain/schedule.ts";
import type { Timestamp } from "../src/domain/timestamp.ts";

/// Repo-Wurzel: von `server/test` zwei Ebenen hoch.
export const FIXTURE_ROOT = join(import.meta.dirname, "..", "..", "spec", "fixtures");

export function fixtureDir(art: string): string {
  return join(FIXTURE_ROOT, art);
}

/// Die JSON-Dateien einer Art, nach Namen sortiert — dieselbe Reihenfolge wie
/// in Swift, damit sich Fehlermeldungen beider Seiten nebeneinanderlegen lassen.
export function loadFixtures<T>(art: string): { file: string; fixture: T }[] {
  return readdirSync(fixtureDir(art))
    .filter((name) => name.endsWith(".json"))
    .sort()
    .map((file) => ({
      file,
      fixture: JSON.parse(readFileSync(join(fixtureDir(art), file), "utf8")) as T,
    }));
}

// MARK: - Bausteine

/// Die Zeitstempel spielen in diesen Auswertungen keine Rolle — die Domäne
/// rechnet mit Kalendertagen. Ein fester Wert hält die Fixtures frei davon.
export const EPOCHE = "1970-01-01T00:00:00.000Z" as Timestamp;

/// Feste, aus der Position abgeleitete IDs: die Fixtures benennen Habits mit
/// einem kurzen Schlüssel, beide Seiten machen daraus dieselbe UUID.
export function fixtureHabitId(index: number): string {
  return `00000000-0000-0000-0000-${String(index + 1).padStart(12, "0")}`;
}

/// Wie ein Habit in einem Fixture beschrieben wird.
export type HabitSpec = {
  key?: string;
  name?: string;
  kind: HabitKind;
  rules: HabitRule[];
  tracksTime?: boolean;
  startsOn?: CalendarDate;
  endsOn?: CalendarDate;
  archivedOn?: CalendarDate;
};

export function buildHabit(spec: HabitSpec, id: string, fallbackName: string): Habit {
  return sortRules({
    id,
    userId: LOCAL_USER_ID,
    name: spec.name ?? fallbackName,
    kind: spec.kind,
    rules: spec.rules,
    colorHex: "#4F8DF7",
    symbol: "checkmark.circle",
    sortOrder: 0,
    tagIds: [],
    tracksTime: spec.tracksTime ?? false,
    startsOn: spec.startsOn ?? null,
    endsOn: spec.endsOn ?? null,
    archivedOn: spec.archivedOn ?? null,
    createdAt: EPOCHE,
    updatedAt: EPOCHE,
  });
}

/// Baut die Habits eines Fixtures und gibt zugleich die Zuordnung
/// Schlüssel → ID zurück, über die Einträge und Ausnahmen sie finden.
export function buildHabits(specs: HabitSpec[]): { habits: Habit[]; ids: Map<string, string> } {
  const ids = new Map<string, string>();
  const habits = specs.map((spec, i) => {
    const id = fixtureHabitId(i);
    if (spec.key) ids.set(spec.key, id);
    return buildHabit(spec, id, spec.key ?? `Habit ${i + 1}`);
  });
  return { habits, ids };
}

export function buildEntry(
  habitId: string, date: CalendarDate, value: number, index: number,
): Entry {
  return {
    id: `entry-${index}`, habitId, date, value,
    source: "manual", createdAt: EPOCHE, updatedAt: EPOCHE,
  };
}

export function buildException(
  habitId: string | null, date: CalendarDate, kind: ExceptionKind, index: number,
): DayException {
  return {
    id: `exception-${index}`, habitId, date, kind,
    createdAt: EPOCHE, updatedAt: EPOCHE,
  };
}
