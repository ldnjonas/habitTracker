/// Sicherung ausgeben und einspielen.
///
/// Das Gegenstück zu `LocalHabitAPI+Backup.swift`, mit **einem bewussten
/// Unterschied**: `replace` löscht hier nicht hart, sondern setzt Grabsteine.
/// Im Client ist eine harte Löschung richtig — dort gibt es niemanden, dem die
/// Löschung noch mitzuteilen wäre. Auf dem Server gibt es den: ein Gerät mit
/// altem Cursor erführe nie, dass die Zeilen weg sind, und schöbe sie beim
/// nächsten Hochladen wieder herein.

import type { Db } from "./db.ts";
import { type Tabelle } from "./tables.ts";
import { NUTZER, ausDatenbank, jetzt, lies, schreibeHabitZubehoer, speichere, tabelleFuer } from "./rows.ts";
import {
  type BackupFile, type BackupProblem, type ImportMode, type ImportReport,
  emptyReport, isFatal, makeBackup, validate,
} from "./domain/backup.ts";
import { Fehler } from "./store.ts";

const HABIT = tabelleFuer("habits");
const TAG = tabelleFuer("tags");
const ENTRY = tabelleFuer("entries");
const EVENT = tabelleFuer("events");
const EXCEPTION = tabelleFuer("exceptions");
const DAY_LOG = tabelleFuer("dayLogs");
const FOCUS = tabelleFuer("focusRuns");
const FREEZE = tabelleFuer("freezes");

export const GENERATOR = "HabitTracker/1.0 (Server)";

// MARK: - Ausgeben

/// Schreibt den Bestand in eine Sicherungsdatei.
///
/// Ohne `habitIds` ist der Umfang `full`, sonst `habits`. Archivierte Habits
/// sind immer dabei — sie sind der Grund, warum man eine Sicherung überhaupt
/// aufhebt. Gelöschte Zeilen bleiben draußen: eine Sicherung beschreibt den
/// Bestand, nicht seine Geschichte.
export async function exportBackup(db: Db, habitIds?: string[]): Promise<BackupFile> {
  const auswahl = habitIds && habitIds.length > 0 ? new Set(habitIds) : null;

  const habitZeilen = await db.alle(
    `SELECT * FROM habit WHERE user_id = ? AND deleted_at IS NULL ORDER BY sort_order, name`,
    NUTZER);
  const habits = await Promise.all(habitZeilen
    .filter((z) => !auswahl || auswahl.has(String(z.id)))
    .map(async (z): Promise<Record<string, unknown>> => ({
      ...ausDatenbank(z, HABIT),
      ...await habitZubehoerFuerDatei(db, String(z.id)),
    })));

  const ids = new Set(habits.map((h) => String(h.id)));
  // Nur die Tags mitnehmen, die von den ausgewählten Habits benutzt werden —
  // eine Einzel-Habit-Sicherung soll nicht die ganze Sammlung mitschleppen.
  const benutzteTags = new Set(habits.flatMap((h) => h.tagIds as string[]));
  const tags = (await db.alle(
    `SELECT * FROM tag WHERE user_id = ? AND deleted_at IS NULL ORDER BY sort_order, name`,
    NUTZER,
  )).filter((z) => !auswahl || benutzteTags.has(String(z.id)))
   .map((z) => ausDatenbank(z, TAG));

  /// Ein Datensatz kommt nur mit, wenn sein Habit ebenfalls in der Datei steht —
  /// sonst fände er beim Einspielen keinen Bezugspunkt.
  const gehoertDazu = (habitId: unknown): boolean => {
    if (habitId === null || habitId === undefined) return auswahl === null;
    return ids.has(String(habitId));
  };

  const entries = (await db.alle(
    `SELECT * FROM entry WHERE user_id = ? AND deleted_at IS NULL ORDER BY habit_id, date`,
    NUTZER,
  )).filter((z) => gehoertDazu(z.habit_id)).map((z) => ausDatenbank(z, ENTRY));

  const events = (await db.alle(
    `SELECT * FROM entry_event WHERE deleted_at IS NULL ORDER BY habit_id, at`,
  )).filter((z) => gehoertDazu(z.habit_id)).map((z) => ausDatenbank(z, EVENT));

  const exceptions = (await db.alle(
    `SELECT * FROM day_exception WHERE user_id = ? AND deleted_at IS NULL ORDER BY date`,
    NUTZER,
  )).filter((z) => gehoertDazu(z.habit_id)).map((z) => ausDatenbank(z, EXCEPTION));

  // Journal, Läufe und Konto hängen an keinem Habit und gehören deshalb nur in
  // eine vollständige Sicherung.
  const nurVoll = async <T>(werte: () => Promise<T[]>): Promise<T[]> =>
    (auswahl ? [] : werte());

  const dayLogs = await nurVoll(async () => (await db.alle(
    `SELECT * FROM day_log WHERE user_id = ? AND deleted_at IS NULL ORDER BY date`, NUTZER,
  )).map((z) => ausDatenbank(z, DAY_LOG)));

  const focusRuns = await nurVoll(async () => (await db.alle(
    `SELECT * FROM focus_run WHERE user_id = ? AND deleted_at IS NULL ORDER BY starts_on`, NUTZER,
  )).map((z) => ausDatenbank(z, FOCUS)));

  const freezes = await nurVoll(async () => (await db.alle(
    `SELECT * FROM freeze_ledger WHERE user_id = ? ORDER BY created_at`, NUTZER,
  )).map((z) => ausDatenbank(z, FREEZE)));

  return makeBackup(GENERATOR, auswahl ? "habits" : "full", {
    habits, tags, entries, events, exceptions, dayLogs, focusRuns, freezes,
  } as unknown as Partial<BackupFile>);
}

/// Regeln und Tags für die Datei — ohne die Spalten, die nur intern gelten.
async function habitZubehoerFuerDatei(db: Db, habitId: string) {
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

// MARK: - Einspielen

type Entscheidung = "insert" | "update" | "skip";

/// Wer gewinnt, wenn eine Zeile schon da ist.
///
/// Beim Zusammenführen entscheidet `updatedAt` — dieselbe Last-Write-Wins-Regel,
/// nach der auch der Abgleich arbeitet. Beim Ersetzen gewinnt immer die Datei.
function entscheide(
  vorhanden: unknown, neu: unknown, modus: ImportMode,
): Entscheidung {
  if (vorhanden === null || vorhanden === undefined) return "insert";
  if (modus === "replace") return "update";
  return Date.parse(String(neu)) > Date.parse(String(vorhanden)) ? "update" : "skip";
}

/// Spielt eine Sicherungsdatei ein.
///
/// Läuft in **einer** Transaktion: entweder ist am Ende alles drin oder nichts.
/// Ein halb eingespieltes Backup wäre schlimmer als ein fehlgeschlagenes. Alle
/// Zeilen teilen sich eine Sequenznummer — ein Import ist ein Vorgang.
///
/// Die `userId` aus der Datei wird verworfen und durch die des angemeldeten
/// Nutzers ersetzt, damit sich eine Sicherung in ein anderes Konto einspielen
/// lässt.
export async function importBackup(db: Db, datei: BackupFile, modus: ImportMode): Promise<ImportReport> {
  const probleme = validate(datei);
  const schwer = probleme.filter(isFatal);
  if (schwer.length > 0) throw new Fehler(422, "Die Datei ist nicht einspielbar", schwer);

  return await db.inTransaktion(async () => {
    const bericht = emptyReport(modus);
    bericht.problems = [...probleme];
    const seq = await db.naechsteSequenz();
    const zeit = jetzt();

    if (modus === "replace") await ersetzeBestand(db, datei, seq, zeit);

    // --- Tags zuerst: `habit_tag` verweist auf sie.
    for (const tag of datei.tags) {
      const vorhanden = await lies(db, TAG, tag.id);
      const wahl = entscheide(vorhanden?.updatedAt, tag.updatedAt, modus);
      if (wahl === "skip") { bericht.counts.tags.skipped += 1; continue; }
      await speichere(db, TAG, { ...tag, userId: NUTZER }, seq);
      bericht.counts.tags[wahl === "insert" ? "inserted" : "updated"] += 1;
    }

    // Welche Tags nach dem Einspielen wirklich existieren.
    const bekannteTags = new Set(
      (await db.alle(`SELECT id FROM tag`)).map((z) => String(z.id)));

    // --- Habits samt Regeln und Tag-Zuordnung.
    let verworfeneTags = 0;
    for (const habit of datei.habits) {
      const vorhanden = await lies(db, HABIT, habit.id);
      const wahl = entscheide(vorhanden?.updatedAt, habit.updatedAt, modus);
      if (wahl === "skip") { bericht.counts.habits.skipped += 1; continue; }

      await speichere(db, HABIT, { ...habit, userId: NUTZER } as unknown as Record<string, unknown>, seq);
      bericht.counts.habits[wahl === "insert" ? "inserted" : "updated"] += 1;

      const brauchbar = habit.tagIds.filter((id) => bekannteTags.has(id));
      verworfeneTags += habit.tagIds.length - brauchbar.length;
      await schreibeHabitZubehoer(db, habit.id, { rules: habit.rules, tagIds: brauchbar });
    }
    if (verworfeneTags > 0) {
      bericht.problems.push({ code: "orphanedRows", table: "habit_tag", count: verworfeneTags });
    }

    // Bezugspunkt für alles Weitere: ein Eintrag ohne Habit ist nicht
    // speicherbar — die Fremdschlüsselbedingung würde ihn ohnehin abweisen.
    const bekannteHabits = new Set(
      (await db.alle(`SELECT id FROM habit`)).map((z) => String(z.id)));

    // --- Einträge: über den natürlichen Schlüssel, nicht über die id.
    //
    // Zwei Geräte, die denselben Tag abgehakt haben, erzeugen zwei verschiedene
    // ids für denselben Sachverhalt. Würde hier nach id gesucht, liefe der
    // Import in die Eindeutigkeitsbedingung von (habit_id, date). Die vorhandene
    // id bleibt deshalb bestehen.
    let verwaisteEintraege = 0;
    for (const entry of datei.entries) {
      if (!bekannteHabits.has(entry.habitId)) { verwaisteEintraege += 1; continue; }
      const vorhanden = await db.eine(
        `SELECT * FROM entry WHERE habit_id = ? AND date = ?`, entry.habitId, entry.date);
      const alt = vorhanden ? ausDatenbank(vorhanden, ENTRY) : null;
      const wahl = entscheide(alt?.updatedAt, entry.updatedAt, modus);
      if (wahl === "skip") { bericht.counts.entries.skipped += 1; continue; }
      await speichere(db, ENTRY, {
        ...entry, id: alt?.id ?? entry.id, userId: NUTZER,
      } as unknown as Record<string, unknown>, seq);
      bericht.counts.entries[wahl === "insert" ? "inserted" : "updated"] += 1;
    }
    meldeVerwaiste(bericht.problems, "entry", verwaisteEintraege);

    // --- Zeitstempel-Detail.
    let verwaisteEvents = 0;
    for (const event of datei.events) {
      if (!bekannteHabits.has(event.habitId)) { verwaisteEvents += 1; continue; }
      const vorhanden = await lies(db, EVENT, event.id);
      const wahl = entscheide(vorhanden?.updatedAt, event.updatedAt, modus);
      if (wahl === "skip") { bericht.counts.events.skipped += 1; continue; }
      await speichere(db, EVENT, event as unknown as Record<string, unknown>, seq);
      bericht.counts.events[wahl === "insert" ? "inserted" : "updated"] += 1;
    }
    meldeVerwaiste(bericht.problems, "entry_event", verwaisteEvents);

    // --- Ausnahmen. Über die id, nicht über (habitId, date): an einem Tag
    // können ein Freeze und eine Pause nebeneinander stehen.
    let verwaisteAusnahmen = 0;
    for (const ausnahme of datei.exceptions) {
      if (ausnahme.habitId != null && !bekannteHabits.has(ausnahme.habitId)) {
        verwaisteAusnahmen += 1; continue;
      }
      const vorhanden = await lies(db, EXCEPTION, ausnahme.id);
      const wahl = entscheide(vorhanden?.updatedAt, ausnahme.updatedAt, modus);
      if (wahl === "skip") { bericht.counts.exceptions.skipped += 1; continue; }
      await speichere(db, EXCEPTION, {
        ...ausnahme, userId: NUTZER,
      } as unknown as Record<string, unknown>, seq);
      bericht.counts.exceptions[wahl === "insert" ? "inserted" : "updated"] += 1;
    }
    meldeVerwaiste(bericht.problems, "day_exception", verwaisteAusnahmen);

    // --- Journal, Schlüssel (userId, date).
    for (const log of datei.dayLogs) {
      const vorhanden = await lies(db, DAY_LOG, NUTZER, log.date);
      const wahl = entscheide(vorhanden?.updatedAt, log.updatedAt, modus);
      if (wahl === "skip") { bericht.counts.dayLogs.skipped += 1; continue; }
      await speichere(db, DAY_LOG, { ...log, userId: NUTZER } as unknown as Record<string, unknown>, seq);
      bericht.counts.dayLogs[wahl === "insert" ? "inserted" : "updated"] += 1;
    }

    // --- Fokus-Läufe. Ohne Fremdschlüssel auf Habits: ein Lauf hat
    // stattgefunden, auch wenn ein beteiligter Habit inzwischen weg ist.
    for (const lauf of datei.focusRuns) {
      const vorhanden = await lies(db, FOCUS, lauf.id);
      const wahl = entscheide(vorhanden?.updatedAt, lauf.updatedAt, modus);
      if (wahl === "skip") { bericht.counts.focusRuns.skipped += 1; continue; }
      await speichere(db, FOCUS, { ...lauf, userId: NUTZER } as unknown as Record<string, unknown>, seq);
      bericht.counts.focusRuns[wahl === "insert" ? "inserted" : "updated"] += 1;
    }

    // --- Freeze-Buchungen. Über die id, und nie aktualisiert: eine Buchung
    // ändert sich nicht, eine Korrektur ist eine Gegenbuchung.
    for (const buchung of datei.freezes) {
      if (await lies(db, FREEZE, buchung.id)) { bericht.counts.freezes.skipped += 1; continue; }
      await speichere(db, FREEZE, {
        ...buchung, userId: NUTZER,
      } as unknown as Record<string, unknown>, seq);
      bericht.counts.freezes.inserted += 1;
    }

    return bericht;
  });
}

function meldeVerwaiste(probleme: BackupProblem[], tabelle: string, anzahl: number): void {
  if (anzahl > 0) probleme.push({ code: "orphanedRows", table: tabelle, count: anzahl });
}

/// Setzt Grabsteine auf alles, was die Datei nicht enthält.
///
/// **Kein `DELETE`.** Der Client löscht beim Ersetzen hart, weil dort niemand
/// mehr zu informieren ist. Hier schon: ein Gerät mit altem Cursor erführe von
/// einer harten Löschung nie und schöbe die Zeilen beim nächsten Hochladen
/// zurück. Das Freeze-Konto bleibt ganz unangetastet — es trägt weder
/// `updated_at` noch einen Grabstein, und eine Buchung wird nicht
/// zurückgenommen.
async function ersetzeBestand(db: Db, datei: BackupFile, seq: number, zeit: string): Promise<void> {
  const behalten: [Tabelle, Set<string>][] = [
    [HABIT, new Set(datei.habits.map((h) => h.id))],
    [TAG, new Set(datei.tags.map((t) => t.id))],
    [ENTRY, new Set(datei.entries.map((e) => e.id))],
    [EVENT, new Set(datei.events.map((e) => e.id))],
    [EXCEPTION, new Set(datei.exceptions.map((e) => e.id))],
    [FOCUS, new Set(datei.focusRuns.map((f) => f.id))],
  ];

  for (const [tabelle, ids] of behalten) {
    for (const zeile of await db.alle(
      `SELECT id FROM "${tabelle.tabelle}" WHERE deleted_at IS NULL`)) {
      if (ids.has(String(zeile.id))) continue;
      await db.schreibe(
        `UPDATE "${tabelle.tabelle}" SET deleted_at = ?, updated_at = ?, server_seq = ?
         WHERE id = ?`,
        zeit, zeit, seq, zeile.id);
    }
  }

  const tage = new Set<string>(datei.dayLogs.map((l) => l.date));
  for (const zeile of await db.alle(
    `SELECT date FROM day_log WHERE user_id = ? AND deleted_at IS NULL`, NUTZER)) {
    if (tage.has(String(zeile.date))) continue;
    await db.schreibe(
      `UPDATE day_log SET deleted_at = ?, updated_at = ?, server_seq = ?
       WHERE user_id = ? AND date = ?`,
      zeit, zeit, seq, NUTZER, zeile.date);
  }
}
