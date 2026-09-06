/// Der Bestand: lesen, schreiben, und die Regeln, die dabei gelten müssen.
///
/// Das Gegenstück zu `apple/HabitKit/Sources/HabitStore/LocalHabitAPI.swift`.
/// Die Endpunkte in `routes/` sind dünn und rufen nur hierher — die Invarianten
/// stehen an einer Stelle, damit die WebApp keine Zustände erzeugen kann, die
/// die Mac-App nie erzeugt.
///
/// **Jede Schreibung vergibt eine Sequenznummer.** Zeilen, die zu einer
/// Handlung gehören, teilen sich eine: eine kaskadierte Löschung ist ein
/// Vorgang, und ein Client soll sie nie halb sehen.

import type { Db } from "./db.ts";
import { type Tabelle } from "./tables.ts";
import {
  NUTZER, ausDatenbank, habitZubehoer, jetzt, lies, schreibeHabitZubehoer,
  setzeRegel, speichere, tabelleFuer,
} from "./rows.ts";

import { type CalendarDate, addDays, makeDate, requireDate } from "./domain/calendar.ts";
import type { DayException, DayLog, Entry, EntryEvent } from "./domain/entry.ts";
import type { Habit, Tag } from "./domain/habit.ts";
import type { HabitRule } from "./domain/schedule.ts";
import type { Timestamp } from "./domain/timestamp.ts";
import { type FocusRun, evaluate, isOpen } from "./domain/focus.ts";
import {
  type FreezeEntry, FREEZE_MAXIMUM, FREEZE_PER_COMPLETED_FOCUS,
  canFreeze, freezeBalance, pendingFreezeAwards,
} from "./domain/freeze.ts";
import { stats } from "./domain/stats.ts";
import { umgebung } from "./umgebung.ts";

// MARK: - Fehler

/// Ein Fehler mit Statuscode — Fastify liest `statusCode` von jedem Error.
///
/// Ohne das wäre eine falsche Anfrage eine 500: der Server räumte einen Fehler
/// ein, den der Client gemacht hat.
export class Fehler extends Error {
  readonly statusCode: number;
  /// Was die Antwort zusätzlich mitgeben soll — etwa die Liste der Befunde,
  /// an denen ein Import gescheitert ist. Eine Fehlermeldung, die nur „nicht
  /// einspielbar" sagt, hilft niemandem beim Beheben.
  readonly details?: unknown;

  constructor(status: number, nachricht: string, details?: unknown) {
    super(nachricht);
    this.name = "Fehler";
    this.statusCode = status;
    this.details = details;
  }
}

export const nichtGefunden = (was: string) => new Fehler(404, `${was} nicht gefunden`);

// MARK: - Tabellen

const HABIT = tabelleFuer("habits");
const TAG = tabelleFuer("tags");
const ENTRY = tabelleFuer("entries");
const EVENT = tabelleFuer("events");
const EXCEPTION = tabelleFuer("exceptions");
const DAY_LOG = tabelleFuer("dayLogs");
const FOCUS = tabelleFuer("focusRuns");
const FREEZE = tabelleFuer("freezes");

/// Die Tabellen, deren Zeilen ohne ihren Habit sinnlos sind.
///
/// Kürzer als die Liste im Client: dort stehen `habit_rule` und `habit_tag`
/// mit drin, weil sie eigene Grabsteine tragen. Hier gehören sie zum Habit und
/// haben gar keine Lebenszyklus-Spalten — sie kommen mit ihm und gehen mit ihm.
const HABIT_TABELLEN = ["entry", "entry_event", "day_exception"];

// MARK: - Heute

/// Der Tag, an dem der Server steht.
///
/// Aus der **lokalen** Zeit, nicht aus UTC: ein Habit wird um 23:30 abgehakt
/// und gehört dann zu diesem Tag und nicht zum nächsten. Welche Zeitzone das
/// ist, sagt `TZ` — siehe README.
export function heute(): CalendarDate {
  const d = new Date();
  return makeDate(d.getFullYear(), d.getMonth() + 1, d.getDate())!;
}

/// Wie weit zurück geschrieben werden darf. `0` heißt: unbegrenzt.
///
/// Ohne diese Grenze trägt man sich rückwirkend einen perfekten Monat ein und
/// die eigenen Zahlen sind nichts mehr wert.
export const NACHTRAGE_TAGE = Number(umgebung("HABIT_BACKFILL_DAYS") ?? 7);

/// Wirft, wenn ein Datum weiter zurückliegt als erlaubt.
///
/// Zukünftige Daten sind ebenfalls tabu — ein Habit lässt sich nicht im Voraus
/// abhaken.
export function pruefeNachtrage(datum: CalendarDate, today = heute()): void {
  const meldung = `${datum} liegt außerhalb der Nachtrage-Grenze von ${NACHTRAGE_TAGE} Tagen`;
  if (datum > today) throw new Fehler(422, `${datum} liegt in der Zukunft`);
  if (NACHTRAGE_TAGE <= 0) return;
  if (datum < addDays(today, -NACHTRAGE_TAGE)) throw new Fehler(422, meldung);
}

// MARK: - Habits lesen

/// Eine Zeile plus ihre Regeln und Tags.
///
/// Die Umformung kommt aus `tables.ts` und liefert deshalb ein loses Objekt;
/// die Zusicherung, dass es ein `Habit` ist, gilt genau hier — an der Grenze
/// zwischen Datenbank und Domäne.
async function baueHabit(db: Db, zeile: Record<string, unknown>): Promise<Habit> {
  const objekt = ausDatenbank(zeile, HABIT);
  Object.assign(objekt, await habitZubehoer(db, String(zeile.id)));
  return objekt as unknown as Habit;
}

export async function listHabits(
  db: Db, optionen: { includeArchived?: boolean; tag?: string } = {},
): Promise<Habit[]> {
  let sql = `SELECT * FROM habit WHERE user_id = ? AND deleted_at IS NULL`;
  const werte: unknown[] = [NUTZER];
  if (!optionen.includeArchived) sql += ` AND archived_on IS NULL`;
  if (optionen.tag) {
    sql += ` AND id IN (SELECT habit_id FROM habit_tag WHERE tag_id = ?)`;
    werte.push(optionen.tag);
  }
  sql += ` ORDER BY sort_order, name`;
  return Promise.all((await db.alle(sql, ...werte)).map((zeile) => baueHabit(db, zeile)));
}

export async function habit(db: Db, id: string): Promise<Habit | null> {
  const zeile = await db.eine(
    `SELECT * FROM habit WHERE id = ? AND user_id = ? AND deleted_at IS NULL`, id, NUTZER);
  return zeile ? await baueHabit(db, zeile) : null;
}

export async function habitOderFehler(db: Db, id: string): Promise<Habit> {
  const gefunden = await habit(db, id);
  if (!gefunden) throw nichtGefunden(`Habit ${id}`);
  return gefunden;
}

// MARK: - Habits schreiben

export type HabitDraft = {
  name: string;
  notes?: string | null;
  kind?: string;
  rules: HabitRule[];
  colorHex?: string;
  symbol?: string;
  tagIds?: string[];
  timeOfDay?: string | null;
  preferredTime?: string | null;
  tracksTime?: boolean;
  startsOn?: CalendarDate | null;
  endsOn?: CalendarDate | null;
};

export async function createHabit(db: Db, entwurf: HabitDraft): Promise<Habit> {
  if (!entwurf.name?.trim()) throw new Fehler(422, "Ein Habit braucht einen Namen");
  if (!Array.isArray(entwurf.rules) || entwurf.rules.length === 0) {
    // Ohne Regel wäre er an keinem Tag auswertbar.
    throw new Fehler(422, "Ein Habit braucht mindestens einen Zeitplan");
  }

  return await db.inTransaktion(async () => {
    const zeit = jetzt();
    const id = crypto.randomUUID();
    const naechste = await db.eine(
      `SELECT COALESCE(MAX(sort_order), -1) + 1 AS n FROM habit WHERE deleted_at IS NULL`);

    const objekt: Record<string, unknown> = {
      id, userId: NUTZER,
      name: entwurf.name.trim(),
      notes: entwurf.notes ?? null,
      kind: entwurf.kind ?? "binary",
      colorHex: entwurf.colorHex ?? "#4F8DF7",
      symbol: entwurf.symbol ?? "checkmark.circle",
      sortOrder: Number(naechste?.n ?? 0),
      timeOfDay: entwurf.timeOfDay ?? null,
      preferredTime: entwurf.preferredTime ?? null,
      tracksTime: entwurf.tracksTime ?? false,
      startsOn: entwurf.startsOn ?? null,
      endsOn: entwurf.endsOn ?? null,
      archivedOn: null,
      healthKitLink: null,
      createdAt: zeit, updatedAt: zeit, deletedAt: null,
    };
    await speichere(db, HABIT, objekt, await db.naechsteSequenz());
    await schreibeHabitZubehoer(db, id, {
      rules: entwurf.rules,
      tagIds: entwurf.tagIds ?? [],
    });
    return await habitOderFehler(db, id);
  });
}

/// Was sich an einem Habit ändern lässt.
///
/// **Nicht** Zeitplan und Ziel: die sind versioniert und laufen über
/// `setRule`. Ohne diese Trennung legte jeder Tippfehler eine Version an und
/// der Verlauf würde zum Flickenteppich.
const AENDERBAR = [
  "name", "notes", "kind", "colorHex", "symbol", "sortOrder",
  "timeOfDay", "preferredTime", "tracksTime", "startsOn", "endsOn", "archivedOn",
] as const;

export async function updateHabit(db: Db, id: string, patch: Record<string, unknown>): Promise<Habit> {
  return await db.inTransaktion(async () => {
    const vorhanden = await lies(db, HABIT, id);
    if (!vorhanden || vorhanden.deletedAt) throw nichtGefunden(`Habit ${id}`);

    const objekt = { ...vorhanden };
    for (const feld of AENDERBAR) {
      if (feld in patch) objekt[feld] = patch[feld];
    }
    objekt.updatedAt = jetzt();
    await speichere(db, HABIT, objekt, await db.naechsteSequenz());
    return await habitOderFehler(db, id);
  });
}

/// Löscht einen Habit weich — samt allem, was an ihm hängt.
///
/// Die Fremdschlüssel tragen zwar `ON DELETE CASCADE`, das greift aber nur bei
/// einer harten Löschung. Hier wird weich gelöscht, also müssen die Grabsteine
/// der abhängigen Zeilen von Hand gesetzt werden: eine Löschung ohne Grabstein
/// ist für den Abgleich unsichtbar und käme auf einem zweiten Gerät nie an —
/// dort stünden die Einträge eines längst gelöschten Habits.
///
/// Alle Zeilen bekommen denselben Zeitstempel, dieselbe Sequenznummer und in
/// `deleted_with` die id des Habits. Daran erkennt `restore` später genau die
/// Zeilen, die mit diesem Habit gefallen sind — und lässt die in Ruhe, die
/// vorher einzeln gelöscht wurden.
export async function deleteHabit(db: Db, id: string): Promise<void> {
  await db.inTransaktion(async () => {
    const vorhanden = await lies(db, HABIT, id);
    if (!vorhanden) throw nichtGefunden(`Habit ${id}`);
    // War der Habit schon gelöscht, darf ein zweiter Aufruf die Herkunft der
    // Kinder nicht neu stempeln — sonst risse ein späteres Wiederherstellen
    // auch das zurück, was vorher einzeln gelöscht wurde.
    if (vorhanden.deletedAt) return;

    const zeit = jetzt();
    const seq = await db.naechsteSequenz();
    await db.schreibe(
      `UPDATE habit SET deleted_at = ?, updated_at = ?, server_seq = ?
       WHERE id = ? AND user_id = ?`,
      zeit, zeit, seq, id, NUTZER);

    for (const tabelle of HABIT_TABELLEN) {
      await db.schreibe(
        `UPDATE "${tabelle}"
         SET deleted_at = ?, updated_at = ?, deleted_with = ?, server_seq = ?
         WHERE habit_id = ? AND deleted_at IS NULL`,
        zeit, zeit, id, seq, id);
    }
  });
}

/// Setzt Zeitplan und Ziel ab einem Datum — Upsert über `(habitId, effectiveFrom)`.
export async function setRule(db: Db, habitId: string, regel: HabitRule): Promise<Habit> {
  if (!regel?.effectiveFrom || !regel.schedule) {
    throw new Fehler(422, "Eine Regel braucht effectiveFrom und schedule");
  }
  return await db.inTransaktion(async () => {
    await habitOderFehler(db, habitId);
    await setzeRegel(db, habitId, regel as unknown as Record<string, unknown>);
    await beruehreHabit(db, habitId);
    return await habitOderFehler(db, habitId);
  });
}

export async function deleteRule(db: Db, habitId: string, effectiveFrom: CalendarDate): Promise<Habit> {
  return await db.inTransaktion(async () => {
    await habitOderFehler(db, habitId);
    const uebrig = await db.eine(
      `SELECT COUNT(*) AS n FROM habit_rule WHERE habit_id = ? AND effective_from <> ?`,
      habitId, effectiveFrom);
    // Ohne Regel wäre der Habit an keinem Tag mehr auswertbar.
    if (Number(uebrig?.n ?? 0) === 0) {
      throw new Fehler(422, "Der letzte Zeitplan lässt sich nicht entfernen");
    }
    await db.schreibe(`DELETE FROM habit_rule WHERE habit_id = ? AND effective_from = ?`,
                habitId, effectiveFrom);
    await beruehreHabit(db, habitId);
    return await habitOderFehler(db, habitId);
  });
}

export async function setTags(db: Db, habitId: string, tagIds: string[]): Promise<Habit> {
  return await db.inTransaktion(async () => {
    await habitOderFehler(db, habitId);
    await db.schreibe(`DELETE FROM habit_tag WHERE habit_id = ?`, habitId);
    for (const tagId of tagIds) {
      await db.schreibe(`INSERT INTO habit_tag (habit_id, tag_id) VALUES (?, ?) ON CONFLICT DO NOTHING`,
                  habitId, tagId);
    }
    await beruehreHabit(db, habitId);
    return await habitOderFehler(db, habitId);
  });
}

/// Hebt `updated_at` des Habits an und gibt ihm eine neue Sequenznummer.
///
/// Nötig, weil Regeln und Tag-Zuordnungen beim Abgleich **mit** dem Habit
/// wandern und keine eigene Nummer tragen. Ohne diesen Anstoß bliebe eine
/// Zeitplanänderung für den Abgleich unsichtbar: der Habit sähe unverändert
/// aus, und das zweite Gerät bekäme weiter den alten Zeitplan.
async function beruehreHabit(db: Db, habitId: string): Promise<void> {
  await db.schreibe(
    `UPDATE habit SET updated_at = ?, server_seq = ? WHERE id = ? AND deleted_at IS NULL`,
    jetzt(), await db.naechsteSequenz(), habitId);
}

// MARK: - Tags

export async function listTags(db: Db): Promise<Tag[]> {
  return (await db.alle(
    `SELECT * FROM tag WHERE user_id = ? AND deleted_at IS NULL ORDER BY sort_order, name`,
    NUTZER,
  )).map((zeile) => ausDatenbank(zeile, TAG) as unknown as Tag);
}

export async function createTag(db: Db, name: string, colorHex = "#8E8E93"): Promise<Tag> {
  if (!name?.trim()) throw new Fehler(422, "Ein Tag braucht einen Namen");
  return await db.inTransaktion(async () => {
    const zeit = jetzt();
    const id = crypto.randomUUID();
    const naechste = await db.eine(
      `SELECT COALESCE(MAX(sort_order), -1) + 1 AS n FROM tag WHERE deleted_at IS NULL`);
    await speichere(db, TAG, {
      id, userId: NUTZER, name: name.trim(), colorHex,
      sortOrder: Number(naechste?.n ?? 0),
      createdAt: zeit, updatedAt: zeit, deletedAt: null,
    }, await db.naechsteSequenz());
    return await lies(db, TAG, id) as unknown as Tag;
  });
}

export async function updateTag(db: Db, id: string, patch: Record<string, unknown>): Promise<Tag> {
  return await db.inTransaktion(async () => {
    const vorhanden = await lies(db, TAG, id);
    if (!vorhanden || vorhanden.deletedAt) throw nichtGefunden(`Tag ${id}`);
    const objekt = { ...vorhanden };
    for (const feld of ["name", "colorHex", "sortOrder"]) {
      if (feld in patch) objekt[feld] = patch[feld];
    }
    objekt.updatedAt = jetzt();
    await speichere(db, TAG, objekt, await db.naechsteSequenz());
    return await lies(db, TAG, id) as unknown as Tag;
  });
}

/// Löscht einen Tag weich.
///
/// Die Zuordnungen bleiben stehen — anders als im Client, wo sie eigene
/// Grabsteine bekommen. Hier tragen sie keine, gehören zum Habit und kommen
/// mit einem wiederhergestellten Tag von selbst zurück. Ein gelöschter Tag
/// wird beim Anzeigen ohnehin nicht mehr aufgelöst.
export async function deleteTag(db: Db, id: string): Promise<void> {
  await db.inTransaktion(async () => {
    const zeit = jetzt();
    await db.schreibe(
      `UPDATE tag SET deleted_at = ?, updated_at = ?, server_seq = ?
       WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
      zeit, zeit, await db.naechsteSequenz(), id, NUTZER);
  });
}

// MARK: - Einträge

export async function listEntries(
  db: Db, from: CalendarDate, to: CalendarDate, habitId?: string,
): Promise<Entry[]> {
  let sql = `SELECT * FROM entry
             WHERE user_id = ? AND deleted_at IS NULL AND date BETWEEN ? AND ?`;
  const werte: unknown[] = [NUTZER, from, to];
  if (habitId) { sql += ` AND habit_id = ?`; werte.push(habitId); }
  sql += ` ORDER BY date, habit_id`;
  return (await db.alle(sql, ...werte)).map((z) => ausDatenbank(z, ENTRY) as unknown as Entry);
}

/// Setzt den Tageswert — der zentrale Schreibvorgang der App.
///
/// Adressiert über den natürlichen Schlüssel `(habitId, date)` und nicht über
/// eine id: deshalb ist ein nach Verbindungsabbruch doppelt gesendeter Aufruf
/// unschädlich, und zwei Geräte, die denselben Tag abhaken, geraten nicht in
/// Streit.
export async function upsertEntry(
  db: Db, habitId: string, datum: CalendarDate,
  wert: { value: number; note?: string | null; source?: string },
  today = heute(),
): Promise<Entry> {
  if (typeof wert?.value !== "number" || !Number.isFinite(wert.value)) {
    throw new Fehler(422, "value muss eine Zahl sein");
  }
  return await db.inTransaktion(async () => {
    await habitOderFehler(db, habitId);
    pruefeNachtrage(datum, today);
    return await schreibeEintrag(db, habitId, datum, wert, await db.naechsteSequenz());
  });
}

/// Ohne Transaktion und ohne Prüfungen — für Aufrufer, die beides schon haben.
async function schreibeEintrag(
  db: Db, habitId: string, datum: CalendarDate,
  wert: { value: number; note?: string | null; source?: string },
  seq: number,
): Promise<Entry> {
  const zeit = jetzt();
  const vorhanden = await db.eine(
    `SELECT * FROM entry WHERE habit_id = ? AND date = ?`, habitId, datum);

  const objekt: Record<string, unknown> = vorhanden
    ? { ...ausDatenbank(vorhanden, ENTRY) }
    : { id: crypto.randomUUID(), habitId, date: datum, createdAt: zeit };

  objekt.userId = NUTZER;
  objekt.value = wert.value;
  objekt.note = wert.note ?? null;
  objekt.source = wert.source ?? "manual";
  objekt.updatedAt = zeit;
  // Ein Wiedereintrag hebt den Grabstein auf.
  objekt.deletedAt = null;

  await speichere(db, ENTRY, objekt, seq);
  await db.schreibe(`UPDATE entry SET deleted_with = NULL WHERE id = ?`, objekt.id);
  return await lies(db, ENTRY, objekt.id) as unknown as Entry;
}

export async function deleteEntry(db: Db, habitId: string, datum: CalendarDate): Promise<void> {
  await db.inTransaktion(async () => {
    const zeit = jetzt();
    await db.schreibe(
      `UPDATE entry SET deleted_at = ?, updated_at = ?, deleted_with = NULL, server_seq = ?
       WHERE habit_id = ? AND date = ? AND deleted_at IS NULL`,
      zeit, zeit, await db.naechsteSequenz(), habitId, datum);
  });
}

// MARK: - Sitzungen

export async function listEvents(
  db: Db, habitId: string, from: CalendarDate, to: CalendarDate,
): Promise<EntryEvent[]> {
  return (await db.alle(
    `SELECT * FROM entry_event
     WHERE habit_id = ? AND deleted_at IS NULL AND date BETWEEN ? AND ?
     ORDER BY at`,
    habitId, from, to,
  )).map((z) => ausDatenbank(z, EVENT) as unknown as EntryEvent);
}

/// Setzt eine Sitzung; der Tageswert des betroffenen Tages wird in derselben
/// Transaktion neu gerechnet.
export async function upsertEvent(
  db: Db, habitId: string, eventId: string,
  roh: Record<string, unknown>, today = heute(),
): Promise<EntryEvent> {
  const datum = requireDate(String(roh.date ?? ""));
  const beginn = String(roh.at ?? "");
  if (!beginn || Number.isNaN(Date.parse(beginn))) {
    throw new Fehler(422, "at muss ein Zeitstempel sein");
  }
  const ende = roh.endsAt == null ? null : String(roh.endsAt);
  // Ein Ende vor dem Start ist kein Grenzfall, sondern ein Tippfehler.
  if (ende && Date.parse(ende) <= Date.parse(beginn)) {
    throw new Fehler(422, "Das Ende liegt vor dem Beginn");
  }

  return await db.inTransaktion(async () => {
    await habitOderFehler(db, habitId);
    pruefeNachtrage(datum, today);
    const seq = await db.naechsteSequenz();
    const zeit = jetzt();
    const vorhanden = await lies(db, EVENT, eventId);

    // Bei einer Sitzung mit Ende zählt die Dauer in Minuten, nicht der
    // mitgeschickte Wert: zwei Felder, die dasselbe sagen, driften auseinander.
    const wert = ende
      ? (Date.parse(ende) - Date.parse(beginn)) / 60_000
      : Number(roh.value ?? 0);

    await speichere(db, EVENT, {
      id: eventId, habitId, date: datum,
      at: beginn, endsAt: ende, value: wert,
      note: roh.note ?? null, source: roh.source ?? "manual",
      createdAt: vorhanden?.createdAt ?? zeit, updatedAt: zeit, deletedAt: null,
    }, seq);
    await db.schreibe(`UPDATE entry_event SET deleted_with = NULL WHERE id = ?`, eventId);

    await rechneEintragNeu(db, habitId, datum, seq);
    return await lies(db, EVENT, eventId) as unknown as EntryEvent;
  });
}

export async function deleteEvent(db: Db, habitId: string, eventId: string): Promise<void> {
  await db.inTransaktion(async () => {
    const vorhanden = await lies(db, EVENT, eventId);
    if (!vorhanden || vorhanden.habitId !== habitId) throw nichtGefunden(`Sitzung ${eventId}`);
    const seq = await db.naechsteSequenz();
    const zeit = jetzt();
    await db.schreibe(
      `UPDATE entry_event SET deleted_at = ?, updated_at = ?, deleted_with = NULL, server_seq = ?
       WHERE id = ? AND deleted_at IS NULL`,
      zeit, zeit, seq, eventId);
    await rechneEintragNeu(db, habitId, vorhanden.date as CalendarDate, seq);
  });
}

/// Hält die Invariante `entry.value == Σ events`.
///
/// Bewusst hier und nicht beim Aufrufer: die Summe darf nie auseinanderlaufen,
/// und die Streak-Engine liest ausschließlich `entry.value`.
async function rechneEintragNeu(db: Db, habitId: string, datum: CalendarDate, seq: number): Promise<void> {
  const zeile = await db.eine(
    `SELECT COALESCE(SUM(value), 0) AS summe, COUNT(*) AS anzahl FROM entry_event
     WHERE habit_id = ? AND date = ? AND deleted_at IS NULL`,
    habitId, datum);
  const anzahl = Number(zeile?.anzahl ?? 0);

  if (anzahl === 0) {
    // Ohne Sitzungen gibt es auch keinen abgeleiteten Tageswert mehr.
    const zeit = jetzt();
    await db.schreibe(
      `UPDATE entry SET deleted_at = ?, updated_at = ?, server_seq = ?
       WHERE habit_id = ? AND date = ? AND deleted_at IS NULL`,
      zeit, zeit, seq, habitId, datum);
    return;
  }
  await schreibeEintrag(db, habitId, datum, { value: Number(zeile?.summe ?? 0) }, seq);
}

// MARK: - Journal

export async function listDayLogs(db: Db, from: CalendarDate, to: CalendarDate): Promise<DayLog[]> {
  return (await db.alle(
    `SELECT * FROM day_log
     WHERE user_id = ? AND deleted_at IS NULL AND date BETWEEN ? AND ? ORDER BY date`,
    NUTZER, from, to,
  )).map((z) => ausDatenbank(z, DAY_LOG) as unknown as DayLog);
}

export async function dayLog(db: Db, datum: CalendarDate): Promise<DayLog | null> {
  const zeile = await db.eine(
    `SELECT * FROM day_log WHERE user_id = ? AND date = ? AND deleted_at IS NULL`,
    NUTZER, datum);
  return zeile ? (ausDatenbank(zeile, DAY_LOG) as unknown as DayLog) : null;
}

export async function upsertDayLog(
  db: Db, datum: CalendarDate, entwurf: Record<string, unknown>,
): Promise<DayLog> {
  return await db.inTransaktion(async () => {
    const zeit = jetzt();
    const vorhanden = await lies(db, DAY_LOG, NUTZER, datum);
    await speichere(db, DAY_LOG, {
      userId: NUTZER, date: datum,
      mood: entwurf.mood ?? null,
      energy: entwurf.energy ?? null,
      sleepHours: entwurf.sleepHours ?? null,
      note: entwurf.note ?? null,
      createdAt: vorhanden?.createdAt ?? zeit,
      updatedAt: zeit,
      deletedAt: null,
    }, await db.naechsteSequenz());
    return (await dayLog(db, datum))!;
  });
}

// MARK: - Ausnahmen

export async function listExceptions(
  db: Db, from: CalendarDate, to: CalendarDate,
): Promise<DayException[]> {
  return (await db.alle(
    `SELECT * FROM day_exception
     WHERE user_id = ? AND deleted_at IS NULL AND date BETWEEN ? AND ? ORDER BY date`,
    NUTZER, from, to,
  )).map((z) => ausDatenbank(z, EXCEPTION) as unknown as DayException);
}

export async function createException(
  db: Db, roh: Record<string, unknown>,
): Promise<DayException> {
  const datum = requireDate(String(roh.date ?? ""));
  const art = String(roh.kind ?? "");
  if (!["frozen", "paused", "skipped"].includes(art)) {
    throw new Fehler(422, `Unbekannte Ausnahmeart: ${art}`);
  }
  return await db.inTransaktion(async () => {
    const habitId = roh.habitId == null ? null : String(roh.habitId);
    if (habitId) await habitOderFehler(db, habitId);
    const zeit = jetzt();
    const id = roh.id ? String(roh.id) : crypto.randomUUID();
    await speichere(db, EXCEPTION, {
      id, userId: NUTZER, habitId, date: datum, kind: art,
      reason: roh.reason ?? null,
      createdAt: zeit, updatedAt: zeit, deletedAt: null,
    }, await db.naechsteSequenz());
    return await lies(db, EXCEPTION, id) as unknown as DayException;
  });
}

export async function deleteException(db: Db, id: string): Promise<void> {
  await db.inTransaktion(async () => {
    const zeit = jetzt();
    await db.schreibe(
      `UPDATE day_exception
       SET deleted_at = ?, updated_at = ?, deleted_with = NULL, server_seq = ?
       WHERE id = ? AND user_id = ? AND deleted_at IS NULL`,
      zeit, zeit, await db.naechsteSequenz(), id, NUTZER);
  });
}

// MARK: - Papierkorb

export type TrashItem = {
  table: "habit" | "tag" | "entry";
  rowId: string;
  deletedAt: Timestamp;
  label: string;
};

/// Grabsteine leben 90 Tage (der Abgleich braucht sie), wiederherstellbar sind
/// aber nur die letzten 30 — ein späteres Restore würde sonst etwas zurückholen,
/// das andere Geräte längst verarbeitet haben.
const PAPIERKORB_TAGE = 30;

export async function trash(db: Db): Promise<TrashItem[]> {
  const grenze = new Date(Date.now() - PAPIERKORB_TAGE * 86_400_000).toISOString();
  const eintraege: TrashItem[] = [];

  for (const z of await db.alle(
    `SELECT id, name, deleted_at FROM habit
     WHERE user_id = ? AND deleted_at IS NOT NULL AND deleted_at >= ?`, NUTZER, grenze)) {
    eintraege.push({ table: "habit", rowId: String(z.id),
                     deletedAt: String(z.deleted_at) as Timestamp, label: String(z.name) });
  }

  for (const z of await db.alle(
    `SELECT id, name, deleted_at FROM tag
     WHERE user_id = ? AND deleted_at IS NOT NULL AND deleted_at >= ?`, NUTZER, grenze)) {
    eintraege.push({ table: "tag", rowId: String(z.id),
                     deletedAt: String(z.deleted_at) as Timestamp, label: String(z.name) });
  }

  // `deleted_with IS NULL` lässt die Einträge weg, die mit ihrem Habit gefallen
  // sind: sie kommen mit ihm zurück, nicht einzeln. Sonst stünde statt eines
  // gelöschten Habits dessen ganzer Verlauf im Papierkorb.
  for (const z of await db.alle(
    `SELECT id, date, deleted_at FROM entry
     WHERE user_id = ? AND deleted_at IS NOT NULL AND deleted_at >= ? AND deleted_with IS NULL`,
    NUTZER, grenze)) {
    eintraege.push({ table: "entry", rowId: String(z.id),
                     deletedAt: String(z.deleted_at) as Timestamp,
                     label: `Eintrag vom ${z.date}` });
  }

  return eintraege.sort((a, b) => (a.deletedAt < b.deletedAt ? 1 : -1));
}

export async function restore(db: Db, item: { table: string; rowId: string }): Promise<void> {
  const tabellen: Record<string, Tabelle> = { habit: HABIT, tag: TAG, entry: ENTRY };
  const tabelle = tabellen[item.table];
  if (!tabelle) throw new Fehler(422, `Aus ${item.table} lässt sich nichts wiederherstellen`);

  await db.inTransaktion(async () => {
    const zeit = jetzt();
    const seq = await db.naechsteSequenz();
    await db.schreibe(
      `UPDATE "${tabelle.tabelle}" SET deleted_at = NULL, updated_at = ?, server_seq = ?
       WHERE id = ?`,
      zeit, seq, item.rowId);

    // Nimmt genau die Löschungen zurück, die mit diesem Habit zusammen geschahen.
    if (item.table === "habit") {
      for (const abhaengig of HABIT_TABELLEN) {
        await db.schreibe(
          `UPDATE "${abhaengig}"
           SET deleted_at = NULL, updated_at = ?, deleted_with = NULL, server_seq = ?
           WHERE deleted_with = ?`,
          zeit, seq, item.rowId);
      }
    }
  });
}

// MARK: - Fokus

export async function focusRuns(db: Db): Promise<FocusRun[]> {
  return (await db.alle(
    `SELECT * FROM focus_run WHERE user_id = ? AND deleted_at IS NULL ORDER BY starts_on DESC`,
    NUTZER,
    // `habit_ids` liegt als JSON-Text in der Spalte; `tables.ts` kennt sie als
    // solche und `ausDatenbank` gibt sie schon als Liste zurück.
  )).map((z) => ({ habitIds: [], ...ausDatenbank(z, FOCUS) }) as unknown as FocusRun);
}

/// Alle Läufe ausgewertet, der jüngste zuerst.
///
/// Die Einträge werden **einmal** über das umspannende Fenster aller Läufe
/// geladen, nicht je Lauf: bei zwanzig Läufen wären das sonst zwanzig Abfragen
/// für weitgehend dieselben Zeilen.
export async function focusProgress(db: Db, today = heute()) {
  const runs = await focusRuns(db);
  if (runs.length === 0) return [];

  const from = runs.reduce((f, r) => (r.startsOn < f ? r.startsOn : f), runs[0]!.startsOn);
  const to = runs.reduce((t, r) => (r.endsOn > t ? r.endsOn : t), runs[0]!.endsOn);

  const habits = await listHabits(db, { includeArchived: true });
  const entries = await listEntries(db, from, to);
  const exceptions = await listExceptions(db, from, to);

  return runs.map((run) => evaluate(run, habits, entries, exceptions, today));
}

export async function startFocus(
  db: Db, tage: number, habitIds: string[] = [], titel?: string | null, today = heute(),
): Promise<FocusRun> {
  if (!Number.isInteger(tage) || tage < 1) {
    throw new Fehler(422, "Ein Fokus dauert mindestens einen Tag");
  }
  return await db.inTransaktion(async () => {
    // Einen noch heilen Lauf darf ein neuer nicht still verdrängen. Einen
    // bereits gerissenen schon — sofort neu anfangen zu dürfen ist der Sinn
    // eines Fokus, nicht bis zum Fensterende warten zu müssen.
    const offen = (await focusProgress(db, today)).find((p) => isOpen(p.outcome));
    if (offen) {
      throw new Fehler(409,
        `Es läuft bereits ein Fokus bis ${offen.run.endsOn}`);
    }

    const zeit = jetzt();
    const id = crypto.randomUUID();
    await speichere(db, FOCUS, {
      id, userId: NUTZER, title: titel ?? null,
      startsOn: today, endsOn: addDays(today, tage - 1),
      habitIds, abandonedOn: null,
      createdAt: zeit, updatedAt: zeit, deletedAt: null,
    }, await db.naechsteSequenz());
    return (await focusRuns(db)).find((r) => r.id === id)!;
  });
}

export async function abandonFocus(db: Db, id: string, today = heute()): Promise<FocusRun> {
  return await db.inTransaktion(async () => {
    const zeit = jetzt();
    await db.schreibe(
      `UPDATE focus_run SET abandoned_on = ?, updated_at = ?, server_seq = ?
       WHERE id = ? AND user_id = ? AND deleted_at IS NULL AND abandoned_on IS NULL`,
      today, zeit, await db.naechsteSequenz(), id, NUTZER);
    const lauf = (await focusRuns(db)).find((r) => r.id === id);
    if (!lauf) throw nichtGefunden(`Fokus ${id}`);
    return lauf;
  });
}

export async function deleteFocus(db: Db, id: string): Promise<void> {
  await db.inTransaktion(async () => {
    const vorhanden = await lies(db, FOCUS, id);
    if (!vorhanden || vorhanden.deletedAt) throw nichtGefunden(`Fokus ${id}`);
    const zeit = jetzt();
    await db.schreibe(
      `UPDATE focus_run SET deleted_at = ?, updated_at = ?, server_seq = ?
       WHERE id = ? AND user_id = ?`,
      zeit, zeit, await db.naechsteSequenz(), id, NUTZER);
  });
}

// MARK: - Freeze-Konto

export async function freezeLedger(db: Db): Promise<FreezeEntry[]> {
  return (await db.alle(
    `SELECT * FROM freeze_ledger WHERE user_id = ? ORDER BY created_at DESC`, NUTZER,
  )).map((z) => ausDatenbank(z, FREEZE) as unknown as FreezeEntry);
}

/// Bucht ein, was durchgezogene Läufe verdient haben.
///
/// Idempotent über `focusRunId`: derselbe Lauf zahlt genau einmal ein, egal wie
/// oft dies aufgerufen wird. Deshalb darf es beim Lesen des Kontos mitlaufen —
/// der Stand hinkt sonst hinterher, bis jemand zufällig den Fokus-Tab öffnet.
export async function awardPendingFreezes(db: Db, today = heute()): Promise<number> {
  const faellig = pendingFreezeAwards(
    (await focusProgress(db, today)).map((p) => ({ run: p.run, outcome: p.outcome })),
    await freezeLedger(db));
  if (faellig.length === 0) return 0;

  await db.inTransaktion(async () => {
    const zeit = jetzt();
    const seq = await db.naechsteSequenz();
    for (const run of faellig) {
      await speichere(db, FREEZE, {
        id: crypto.randomUUID(), userId: NUTZER,
        amount: FREEZE_PER_COMPLETED_FOCUS, reason: "focusCompleted",
        habitId: null, date: null, focusRunId: run.id, createdAt: zeit,
      }, seq);
    }
  });
  return faellig.length;
}

export async function freezeKonto(db: Db, today = heute()) {
  await awardPendingFreezes(db, today);
  const ledger = await freezeLedger(db);
  return { balance: freezeBalance(ledger), maximum: FREEZE_MAXIMUM, ledger };
}

/// Löst einen Freeze für einen verpassten Tag ein.
///
/// Zwei Buchungen in einem Zug: die Ausnahme, die den Streak hält, und der
/// Abzug vom Konto. Getrennt könnten sie auseinanderlaufen — ein geretteter Tag
/// ohne Abzug wäre ein Freeze umsonst.
export async function applyFreeze(
  db: Db, habitId: string, datum: CalendarDate, today = heute(),
): Promise<DayException> {
  const gefunden = await habitOderFehler(db, habitId);

  await awardPendingFreezes(db, today);
  if (freezeBalance(await freezeLedger(db)) <= 0) {
    throw new Fehler(409, "Kein Guthaben");
  }

  // Nur ein wirklich verpasster Tag. Ein erfüllter braucht keine Rettung, und
  // der laufende ist noch nicht verloren.
  const auswertung = stats(
    gefunden, await listEntries(db, datum, datum, habitId),
    await listExceptions(db, datum, datum), datum, datum, today);
  const status = auswertung.days[datum] ?? { code: "notScheduled" as const };
  if (!canFreeze(status, datum, today)) {
    throw new Fehler(422, `Der ${datum} lässt sich nicht einfrieren (${status.code})`);
  }
  pruefeNachtrage(datum, today);

  return await db.inTransaktion(async () => {
    const zeit = jetzt();
    const seq = await db.naechsteSequenz();
    const id = crypto.randomUUID();
    await speichere(db, EXCEPTION, {
      id, userId: NUTZER, habitId, date: datum, kind: "frozen",
      reason: "Streak Freeze",
      createdAt: zeit, updatedAt: zeit, deletedAt: null,
    }, seq);
    await speichere(db, FREEZE, {
      id: crypto.randomUUID(), userId: NUTZER, amount: -1, reason: "applied",
      habitId, date: datum, focusRunId: null, createdAt: zeit,
    }, seq);
    return await lies(db, EXCEPTION, id) as unknown as DayException;
  });
}
