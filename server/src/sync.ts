import type { Db, Zeile } from "./db.ts";
import { TABELLEN, type Spalte, type Tabelle } from "./tables.ts";

export type Delta = Record<string, unknown[]> & {
  nextSeq?: number;
  hasMore?: boolean;
};

/// Wie weit die Uhr eines Clients vorgehen darf, bevor der Server sie
/// zurechtstutzt.
///
/// Bei Last-Write-Wins entscheidet `updatedAt`, welche Fassung gewinnt. Ein
/// Gerät mit falsch gestellter Uhr gewänne sonst dauerhaft jeden Konflikt —
/// und niemand käme darauf, dass das die Ursache ist.
const UHR_TOLERANZ_MS = 5 * 60 * 1000;

/// Solange es nur ein statisches Token gibt, ist der Nutzer eine Konstante —
/// dieselbe, die der Client vor dem ersten Login benutzt (`Habit.localUserId`).
export const NUTZER = process.env.HABIT_USER ?? "local";

// MARK: - Umformen

function ausDatenbank(zeile: Zeile, tabelle: Tabelle): Record<string, unknown> {
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

function fuerDatenbank(wert: unknown, spalte: Spalte): unknown {
  if (wert === null || wert === undefined) return null;
  if (spalte.art === "bool") return wert ? 1 : 0;
  if (spalte.art === "json") return JSON.stringify(wert);
  return wert as string | number;
}

// MARK: - Lesen

/// Alle Zeilen mit `server_seq > since`, **einschließlich Grabsteinen**.
///
/// Ohne die Grabsteine käme eine Löschung nie beim anderen Gerät an — dort
/// stünde der Eintrag weiter, und niemand wüsste, warum.
///
/// Die Grenze `limit` gilt über alle Tabellen zusammen, weil die Folge
/// tabellenübergreifend läuft: es wird bis zu einer Sequenznummer gelesen und
/// nicht bis zu einer Zeilenzahl je Tabelle. Sonst könnte ein Delta mitten in
/// einer Sequenznummer abschneiden und der Client hielte etwas für vollständig,
/// das es nicht ist.
export function leseDelta(db: Db, since: number, limit = 500): Delta {
  const hoechste = db.aktuelleSequenz();
  const grenze = Math.min(hoechste, since + limit);

  const delta: Delta = {};
  for (const tabelle of TABELLEN) {
    const zeilen = db.alle(
      `SELECT * FROM "${tabelle.tabelle}" WHERE server_seq > ? AND server_seq <= ? ORDER BY server_seq`,
      since, grenze);
    delta[tabelle.schluessel] = zeilen.map((zeile) => {
      const objekt = ausDatenbank(zeile, tabelle);
      if (tabelle.tabelle === "habit") {
        Object.assign(objekt, habitZubehoer(db, String(zeile.id)));
      }
      return objekt;
    });
  }

  delta.nextSeq = grenze;
  delta.hasMore = grenze < hoechste;
  return delta;
}

/// Regeln und Tag-Zuordnungen eines Habits. Sie wandern mit ihm statt eigene
/// Zeilen im Delta zu bilden — genau wie in der Sicherungsdatei.
function habitZubehoer(db: Db, habitId: string) {
  const regeln = db.alle(
    `SELECT * FROM habit_rule WHERE habit_id = ? ORDER BY effective_from`, habitId);
  const tags = db.alle(`SELECT tag_id FROM habit_tag WHERE habit_id = ?`, habitId);
  return {
    rules: regeln.map((r) => ({
      effectiveFrom: r.effective_from,
      schedule: JSON.parse(String(r.schedule_payload)),
      ...(r.target_value !== null && r.target_unit !== null
        ? { target: { value: r.target_value, unit: r.target_unit,
                      comparison: r.target_comparison ?? "atLeast" } }
        : {}),
    })),
    tagIds: tags.map((t) => t.tag_id),
  };
}

// MARK: - Schreiben

export type Bericht = { angenommen: number; verworfen: number; nextSeq: number };

/// Wendet ein Delta an und gibt den neuen Cursor zurück.
///
/// Der Server vergibt die Sequenznummer und setzt `updatedAt` auf **seine**
/// Zeit. Die Uhr eines Clients ist nicht vertrauenswürdig, und genau sie
/// entscheidet bei Last-Write-Wins.
export function schreibeDelta(
  db: Db, delta: Delta, jetzt = new Date(), nutzer = NUTZER,
): Bericht {
  let angenommen = 0;
  let verworfen = 0;

  db.inTransaktion(() => {
    for (const tabelle of TABELLEN) {
      const zeilen = delta[tabelle.schluessel];
      if (!Array.isArray(zeilen)) continue;
      for (const roh of zeilen) {
        if (schreibeZeile(db, tabelle, roh as Record<string, unknown>, jetzt, nutzer)) angenommen++;
        else verworfen++;
      }
    }
  });

  return { angenommen, verworfen, nextSeq: db.aktuelleSequenz() };
}

function schreibeZeile(
  db: Db, tabelle: Tabelle, roh: Record<string, unknown>, jetzt: Date, nutzer: string,
): boolean {
  // Wem die Zeile gehört, bestimmt der Server aus dem Token — nicht der Client.
  //
  // Zwei Gründe. Erstens tragen einige Domänentypen gar kein `userId`: ein
  // `Entry` in Swift kennt nur seinen Habit, die Zuordnung steht in der
  // Datenbankzeile. Zweitens dürfte ein Client sonst Zeilen für einen anderen
  // Nutzer schreiben, sobald es mehr als einen gibt.
  if (tabelle.spalten.some((s) => s.feld === "userId")) roh = { ...roh, userId: nutzer };
  const schluesselWerte = tabelle.primaer.map((spalte) => {
    const feld = tabelle.spalten.find((s) => s.spalte === spalte)!.feld;
    return roh[feld];
  });
  if (schluesselWerte.some((w) => w === undefined || w === null)) return false;

  const bedingung = tabelle.primaer.map((s) => `"${s}" = ?`).join(" AND ");
  const vorhanden = db.eine(
    `SELECT * FROM "${tabelle.tabelle}" WHERE ${bedingung}`, ...schluesselWerte);

  // Das Freeze-Konto wird nur angehängt: eine vorhandene Buchung bleibt, wie
  // sie ist. Eine Korrektur ist dort eine Gegenbuchung, keine Änderung.
  if (!tabelle.loeschbar && vorhanden) return false;

  let stempel = String(roh.updatedAt ?? roh.createdAt ?? jetzt.toISOString());
  if (tabelle.loeschbar) {
    // Eine Uhr, die zu weit vorgeht, wird auf die Serverzeit gestutzt — sonst
    // gewänne dieses Gerät jeden künftigen Konflikt.
    if (Date.parse(stempel) > jetzt.getTime() + UHR_TOLERANZ_MS) {
      stempel = jetzt.toISOString();
    }
    if (vorhanden && String(vorhanden.updated_at) >= stempel) return false;
  }

  const werte = tabelle.spalten.map((spalte) =>
    spalte.feld === "updatedAt" ? stempel : fuerDatenbank(roh[spalte.feld], spalte));
  const namen = tabelle.spalten.map((s) => `"${s.spalte}"`);
  const platzhalter = tabelle.spalten.map(() => "?");

  db.schreibe(
    `INSERT INTO "${tabelle.tabelle}" (${namen.join(", ")}, server_seq)
     VALUES (${platzhalter.join(", ")}, ?)
     ON CONFLICT (${tabelle.primaer.map((s) => `"${s}"`).join(", ")}) DO UPDATE SET
       ${namen.map((n) => `${n} = excluded.${n}`).join(", ")},
       server_seq = excluded.server_seq`,
    ...werte, db.naechsteSequenz());

  if (tabelle.tabelle === "habit") {
    schreibeHabitZubehoer(db, String(schluesselWerte[0]), roh);
  }
  return true;
}

/// Regeln und Tags werden mit dem Habit als Einheit ersetzt.
///
/// Dieselbe Entscheidung wie beim Einspielen einer Sicherung: eine teilweise
/// übernommene Zeitplan-Historie wäre schwerer zu erklären als eine ersetzte.
function schreibeHabitZubehoer(db: Db, habitId: string, roh: Record<string, unknown>): void {
  if (Array.isArray(roh.rules)) {
    db.schreibe(`DELETE FROM habit_rule WHERE habit_id = ?`, habitId);
    for (const regel of roh.rules as Record<string, unknown>[]) {
      const ziel = regel.target as Record<string, unknown> | undefined;
      const plan = regel.schedule as Record<string, unknown>;
      db.schreibe(
        `INSERT INTO habit_rule
           (habit_id, effective_from, schedule_kind, schedule_payload,
            target_value, target_unit, target_comparison)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
        habitId, regel.effectiveFrom, plan?.kind ?? "daily", JSON.stringify(plan),
        ziel?.value ?? null, ziel?.unit ?? null, ziel?.comparison ?? null);
    }
  }
  if (Array.isArray(roh.tagIds)) {
    db.schreibe(`DELETE FROM habit_tag WHERE habit_id = ?`, habitId);
    for (const tagId of roh.tagIds as string[]) {
      // Ein Tag, den der Server noch nicht kennt, würde am Fremdschlüssel
      // scheitern — hier gibt es keinen, die Zuordnung darf vorauseilen.
      db.schreibe(`INSERT OR IGNORE INTO habit_tag (habit_id, tag_id) VALUES (?, ?)`,
                  habitId, tagId);
    }
  }
}
