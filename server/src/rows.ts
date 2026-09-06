/// Zeilen umformen und schreiben — die Schicht zwischen `tables.ts` und SQL.
///
/// Aus `sync.ts` herausgezogen, als die Ressourcen-Endpunkte dazukamen: beide
/// schreiben in dieselben Tabellen, und zwei Fassungen derselben Umformung sind
/// zwei Gelegenheiten, eine Spalte zu vergessen.
///
/// **Jede Schreibung geht hier durch und bekommt dabei eine Sequenznummer.**
/// Ohne die sähe der Mac nichts von dem, was im Browser passiert — die Zeile
/// stünde in der Datenbank und käme trotzdem in keinem Delta vor.

import type { Db, Zeile } from "./db.ts";
import { TABELLEN, type Spalte, type Tabelle } from "./tables.ts";
import { umgebung } from "./umgebung.ts";

/// Solange es nur ein statisches Token gibt, ist der Nutzer eine Konstante —
/// dieselbe, die der Client vor dem ersten Login benutzt (`Habit.localUserId`).
export const NUTZER = umgebung("HABIT_USER") ?? "local";

export function tabelleFuer(schluessel: string): Tabelle {
  const tabelle = TABELLEN.find((t) => t.schluessel === schluessel);
  if (!tabelle) throw new Error(`Unbekannte Tabelle: ${schluessel}`);
  return tabelle;
}

/// Zeitstempel in der Form, die auch die Sicherungsdatei benutzt.
export function jetzt(): string {
  return new Date().toISOString();
}

// MARK: - Umformen

export function ausDatenbank(zeile: Zeile, tabelle: Tabelle): Record<string, unknown> {
  const ergebnis: Record<string, unknown> = {};
  for (const spalte of tabelle.spalten) {
    const wert = zeile[spalte.spalte];
    if (wert === null || wert === undefined) continue;
    ergebnis[spalte.feld] =
      spalte.art === "bool" ? wert !== 0 :
      spalte.art === "json" ? JSON.parse(String(wert)) :
      wert;
  }
  return ergebnis;
}

export function fuerDatenbank(wert: unknown, spalte: Spalte): unknown {
  if (wert === null || wert === undefined) return null;
  if (spalte.art === "bool") return wert ? 1 : 0;
  if (spalte.art === "json") return JSON.stringify(wert);
  return wert as string | number;
}

// MARK: - Schreiben

/// Schreibt eine vollständige Zeile und gibt ihr die Sequenznummer.
///
/// `seq` kommt von außen, damit mehrere Zeilen einer Handlung dieselbe Nummer
/// tragen können: eine kaskadierte Löschung ist ein Vorgang, und ein Client
/// soll sie nie halb sehen.
export async function speichere(
  db: Db, tabelle: Tabelle, objekt: Record<string, unknown>, seq: number,
): Promise<void> {
  const werte = tabelle.spalten.map((s) => fuerDatenbank(objekt[s.feld], s));
  const namen = tabelle.spalten.map((s) => `"${s.spalte}"`);
  const platzhalter = tabelle.spalten.map(() => "?");

  await db.schreibe(
    `INSERT INTO "${tabelle.tabelle}" (${namen.join(", ")}, server_seq)
     VALUES (${platzhalter.join(", ")}, ?)
     ON CONFLICT (${tabelle.primaer.map((s) => `"${s}"`).join(", ")}) DO UPDATE SET
       ${namen.map((n) => `${n} = excluded.${n}`).join(", ")},
       server_seq = excluded.server_seq`,
    ...werte, seq);
}

/// Liest eine Zeile über ihren Primärschlüssel — auch eine gelöschte.
export async function lies(
  db: Db, tabelle: Tabelle, ...schluessel: unknown[]
): Promise<Record<string, unknown> | null> {
  const bedingung = tabelle.primaer.map((s) => `"${s}" = ?`).join(" AND ");
  const zeile = await db.eine(`SELECT * FROM "${tabelle.tabelle}" WHERE ${bedingung}`, ...schluessel);
  return zeile ? ausDatenbank(zeile, tabelle) : null;
}

// MARK: - Habits samt Zubehör

/// Regeln und Tag-Zuordnungen eines Habits.
///
/// Sie wandern mit ihm statt eigene Zeilen zu bilden — genau wie in der
/// Sicherungsdatei. Daraus folgt: **jede Änderung an ihnen muss `updated_at`
/// des Habits anheben**, sonst bliebe sie beim Abgleich unsichtbar.
export async function habitZubehoer(db: Db, habitId: string): Promise<{
  rules: Record<string, unknown>[]; tagIds: string[];
}> {
  const regeln = await db.alle(
    `SELECT * FROM habit_rule WHERE habit_id = ? ORDER BY effective_from`, habitId);
  const tags = await db.alle(`SELECT tag_id FROM habit_tag WHERE habit_id = ?`, habitId);
  return {
    rules: regeln.map((r) => ({
      effectiveFrom: r.effective_from,
      schedule: JSON.parse(String(r.schedule_payload)),
      ...(r.target_value !== null && r.target_unit !== null
        ? {
            target: {
              value: r.target_value, unit: r.target_unit,
              comparison: r.target_comparison ?? "atLeast",
            },
          }
        : {}),
    })),
    tagIds: tags.map((t) => String(t.tag_id)),
  };
}

/// Ersetzt Regeln und Tags eines Habits als Einheit.
///
/// Dieselbe Entscheidung wie beim Einspielen einer Sicherung: eine teilweise
/// übernommene Zeitplan-Historie wäre schwerer zu erklären als eine ersetzte.
export async function schreibeHabitZubehoer(
  db: Db, habitId: string, roh: Record<string, unknown>,
): Promise<void> {
  if (Array.isArray(roh.rules)) {
    await db.schreibe(`DELETE FROM habit_rule WHERE habit_id = ?`, habitId);
    for (const regel of roh.rules as Record<string, unknown>[]) {
      await setzeRegel(db, habitId, regel);
    }
  }
  if (Array.isArray(roh.tagIds)) {
    await db.schreibe(`DELETE FROM habit_tag WHERE habit_id = ?`, habitId);
    for (const tagId of roh.tagIds as string[]) {
      // Ein Tag, den der Server noch nicht kennt, würde am Fremdschlüssel
      // scheitern — hier gibt es keinen, die Zuordnung darf vorauseilen.
      await db.schreibe(`INSERT INTO habit_tag (habit_id, tag_id) VALUES (?, ?) ON CONFLICT DO NOTHING`,
                  habitId, tagId);
    }
  }
}

/// Eine einzelne Regelversion — Upsert über `(habit_id, effective_from)`.
///
/// Genau diese Adressierung trennt „ab heute ändern" von „Tippfehler
/// korrigieren": das eine legt eine Version an, das andere überschreibt eine.
export async function setzeRegel(
  db: Db, habitId: string, regel: Record<string, unknown>,
): Promise<void> {
  const ziel = regel.target as Record<string, unknown> | undefined | null;
  const plan = regel.schedule as Record<string, unknown>;
  await db.schreibe(
    `INSERT INTO habit_rule
       (habit_id, effective_from, schedule_kind, schedule_payload,
        target_value, target_unit, target_comparison)
     VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT (habit_id, effective_from) DO UPDATE SET
       schedule_kind = excluded.schedule_kind,
       schedule_payload = excluded.schedule_payload,
       target_value = excluded.target_value,
       target_unit = excluded.target_unit,
       target_comparison = excluded.target_comparison`,
    habitId, regel.effectiveFrom, plan?.kind ?? "daily", JSON.stringify(plan),
    ziel?.value ?? null, ziel?.unit ?? null, ziel?.comparison ?? null);
}
