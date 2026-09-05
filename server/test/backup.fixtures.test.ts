/// Die Sicherungs-Fixtures, gelesen und geschrieben von der TypeScript-Domäne.
///
/// Das Gegenstück zu `BackupFixtureTests.swift`. Hier geht es ausnahmsweise
/// nicht um Zahlen, sondern um **Bytes**: die als `canonical` markierten Dateien
/// hat die Mac-App geschrieben, und beide Fassungen müssen sie Zeichen für
/// Zeichen wieder herausgeben. Damit ist eine Sicherung dieselbe Datei, gleich
/// welche der beiden sie exportiert hat.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

import type { CalendarDate } from "../src/domain/calendar.ts";
import {
  type BackupScope,
  dateRange, encodeBackup, isFatal, parseBackup, summary, validate,
} from "../src/domain/backup.ts";
import { fixtureDir } from "./fixtures.ts";

type Expectation = {
  name: string;
  /// Ob die Datei Byte für Byte wieder herauskommen muss. Falsch bei einer von
  /// Hand geschriebenen Datei — die ist absichtlich unaufgeräumt.
  canonical: boolean;
  summary?: string;
  /// Wie überall: Schlüssel fehlt = nicht prüfen, `null` = muss null sein.
  dateRange?: { from: CalendarDate; to: CalendarDate } | null;
  formatVersion?: number;
  scope?: BackupScope;
  exportedAt?: string;
  counts?: Record<string, number>;
  problems?: { code: string; fatal: boolean }[];
};

const verzeichnis = fixtureDir("backup");

const dateien = readdirSync(verzeichnis)
  .filter((name) => name.endsWith(".json") && !name.endsWith(".expected.json"))
  .sort();

test("spec/fixtures/backup liegt am erwarteten Ort und ist nicht leer", () => {
  assert.ok(dateien.length > 0, "Keine Fixtures gefunden");
});

for (const datei of dateien) {
  const roh = readFileSync(join(verzeichnis, datei), "utf8");
  const erwartet = JSON.parse(
    readFileSync(join(verzeichnis, datei.replace(/\.json$/, ".expected.json")), "utf8"),
  ) as Expectation;

  test(`${datei} — ${erwartet.name}`, () => {
    const file = parseBackup(roh);

    if (erwartet.canonical) {
      assert.equal(encodeBackup(file), roh,
        "Die Datei kommt nicht Zeichen für Zeichen wieder heraus");
    }

    if (erwartet.formatVersion !== undefined) {
      assert.equal(file.formatVersion, erwartet.formatVersion, "formatVersion");
    }
    if (erwartet.scope !== undefined) assert.equal(file.scope, erwartet.scope, "scope");
    if (erwartet.exportedAt !== undefined) {
      assert.equal(file.exportedAt, erwartet.exportedAt, "exportedAt");
    }
    if (erwartet.summary !== undefined) {
      assert.equal(summary(file), erwartet.summary, "summary");
    }

    if (erwartet.dateRange === null) {
      assert.equal(dateRange(file), null, "dateRange müsste null sein");
    } else if (erwartet.dateRange !== undefined) {
      assert.deepEqual(dateRange(file), erwartet.dateRange, "dateRange");
    }

    for (const [tabelle, anzahl] of Object.entries(erwartet.counts ?? {})) {
      const liste = file[tabelle as keyof typeof file];
      assert.ok(Array.isArray(liste), `${tabelle} ist keine Liste`);
      assert.equal(liste.length, anzahl, `${tabelle}`);
    }

    if (erwartet.problems !== undefined) {
      const probleme = validate(file);
      assert.deepEqual(probleme.map((p) => ({ code: p.code, fatal: isFatal(p) })),
        erwartet.problems, "problems");
    }
  });
}
