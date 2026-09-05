/// Zugriff auf die geteilten Fixtures unter `spec/fixtures/`.
///
/// Dieselben Dateien liest `apple/HabitKit/Tests/HabitCoreTests/Fixture.swift`.
/// Das ist der Vertrag, der die Swift- und die TypeScript-Fassung der Domäne
/// davon abhält, auseinanderzulaufen: weicht eine Zahl ab, schlägt eine Seite
/// fehl — statt dass Mac und Browser stillschweigend Verschiedenes anzeigen.

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

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
