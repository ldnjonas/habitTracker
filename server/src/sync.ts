import type { Db } from "./db.ts";
import { TABELLEN, type Tabelle } from "./tables.ts";
import {
  NUTZER, ausDatenbank, fuerDatenbank, habitZubehoer, schreibeHabitZubehoer,
} from "./rows.ts";

export { NUTZER };

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
export async function leseDelta(db: Db, since: number, limit = 500): Promise<Delta> {
  const hoechste = await db.aktuelleSequenz();
  const grenze = Math.min(hoechste, since + limit);

  const delta: Delta = {};
  for (const tabelle of TABELLEN) {
    const zeilen = await db.alle(
      `SELECT * FROM "${tabelle.tabelle}" WHERE server_seq > ? AND server_seq <= ? ORDER BY server_seq`,
      since, grenze);
    delta[tabelle.schluessel] = await Promise.all(zeilen.map(async (zeile) => {
      const objekt = ausDatenbank(zeile, tabelle);
      if (tabelle.tabelle === "habit") {
        Object.assign(objekt, await habitZubehoer(db, String(zeile.id)));
      }
      return objekt;
    }));
  }

  delta.nextSeq = grenze;
  delta.hasMore = grenze < hoechste;
  return delta;
}

// MARK: - Schreiben

export type Bericht = { angenommen: number; verworfen: number; nextSeq: number };

/// Wendet ein Delta an und gibt den neuen Cursor zurück.
///
/// Der Server vergibt die Sequenznummer und setzt `updatedAt` auf **seine**
/// Zeit. Die Uhr eines Clients ist nicht vertrauenswürdig, und genau sie
/// entscheidet bei Last-Write-Wins.
export async function schreibeDelta(
  db: Db, delta: Delta, jetzt = new Date(), nutzer = NUTZER,
): Promise<Bericht> {
  let angenommen = 0;
  let verworfen = 0;

  await db.inTransaktion(async () => {
    for (const tabelle of TABELLEN) {
      const zeilen = delta[tabelle.schluessel];
      if (!Array.isArray(zeilen)) continue;
      for (const roh of zeilen) {
        if (await schreibeZeile(db, tabelle, roh as Record<string, unknown>, jetzt, nutzer)) angenommen++;
        else verworfen++;
      }
    }
  });

  return { angenommen, verworfen, nextSeq: await db.aktuelleSequenz() };
}

async function schreibeZeile(
  db: Db, tabelle: Tabelle, roh: Record<string, unknown>, jetzt: Date, nutzer: string,
): Promise<boolean> {
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
  const vorhanden = await db.eine(
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

  await db.schreibe(
    `INSERT INTO "${tabelle.tabelle}" (${namen.join(", ")}, server_seq)
     VALUES (${platzhalter.join(", ")}, ?)
     ON CONFLICT (${tabelle.primaer.map((s) => `"${s}"`).join(", ")}) DO UPDATE SET
       ${namen.map((n) => `${n} = excluded.${n}`).join(", ")},
       server_seq = excluded.server_seq`,
    ...werte, await db.naechsteSequenz());

  if (tabelle.tabelle === "habit") {
    await schreibeHabitZubehoer(db, String(schluesselWerte[0]), roh);
  }
  return true;
}
