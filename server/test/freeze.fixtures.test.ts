/// Die Freeze-Fixtures, gerechnet von der TypeScript-Domäne.
///
/// Das Gegenstück zu `FreezeFixtureTests.swift`.

import { test } from "node:test";
import assert from "node:assert/strict";

import type { CalendarDate } from "../src/domain/calendar.ts";
import type { DayStatus } from "../src/domain/dayStatus.ts";
import type { FocusOutcome, FocusRun } from "../src/domain/focus.ts";
import {
  type FreezeEntry, type FreezeReason,
  canFreeze, freezeBalance, pendingFreezeAwards,
} from "../src/domain/freeze.ts";
import { EPOCHE, loadFixtures } from "./fixtures.ts";

type Fixture = {
  name: string;
  today: CalendarDate;
  runs: {
    key: string;
    startsOn: CalendarDate;
    endsOn: CalendarDate;
    outcome: FocusOutcome;
  }[];
  ledger: {
    amount: number;
    reason: FreezeReason;
    /// Schlüssel des Laufs, der eingezahlt hat.
    focusRun?: string;
  }[];
  expected: {
    balance?: number;
    /// Schlüssel der Läufe, die noch einzahlen dürfen — in dieser Reihenfolge.
    pendingAwards?: string[];
    freezable?: { status: string; date: CalendarDate; can: boolean }[];
  };
};

/// Aus dem `code` einen Status bauen. `partial` trägt einen Fortschritt, den
/// `canFreeze` nicht ansieht — null genügt.
function statusOf(code: string): DayStatus {
  return code === "partial"
    ? { code: "partial", progress: 0 }
    : ({ code } as DayStatus);
}

const fixtures = loadFixtures<Fixture>("freeze");

test("spec/fixtures/freeze liegt am erwarteten Ort und ist nicht leer", () => {
  assert.ok(fixtures.length > 0, "Keine Fixtures gefunden");
});

for (const { file, fixture } of fixtures) {
  test(`${file} — ${fixture.name}`, () => {
    const runIds = new Map<string, string>();
    const runs: { run: FocusRun; outcome: FocusOutcome }[] = fixture.runs.map((spec, i) => {
      const id = `00000000-0000-0000-0000-${String(i + 1).padStart(12, "0")}`;
      runIds.set(spec.key, id);
      return {
        run: {
          id, userId: "local", title: null,
          startsOn: spec.startsOn, endsOn: spec.endsOn,
          habitIds: [], abandonedOn: null,
          createdAt: EPOCHE, updatedAt: EPOCHE,
        },
        outcome: spec.outcome,
      };
    });

    const ledger: FreezeEntry[] = fixture.ledger.map((b, i) => ({
      id: `buchung-${i}`, userId: "local",
      amount: b.amount, reason: b.reason,
      focusRunId: b.focusRun ? runIds.get(b.focusRun) ?? null : null,
      createdAt: EPOCHE,
    }));

    const e = fixture.expected;

    if (e.balance !== undefined) {
      assert.equal(freezeBalance(ledger), e.balance, "balance");
    }

    if (e.pendingAwards !== undefined) {
      const faellig = pendingFreezeAwards(runs, ledger);
      const schluessel = faellig.map((run) => {
        for (const [key, id] of runIds) if (id === run.id) return key;
        return run.id;
      });
      assert.deepEqual(schluessel, e.pendingAwards, "pendingAwards");
    }

    for (const fall of e.freezable ?? []) {
      assert.equal(canFreeze(statusOf(fall.status), fall.date, fixture.today), fall.can,
        `canFreeze(${fall.status}, ${fall.date})`);
    }
  });
}
