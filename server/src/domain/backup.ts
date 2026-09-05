/// Portiert aus `apple/HabitKit/Sources/HabitCore/Backup.swift`.
///
/// Diese Datei ist der einzige Ort, an dem beide Fassungen dieselben *Bytes*
/// erzeugen müssen und nicht bloß dieselben Zahlen: eine Sicherung, die der Mac
/// schreibt, muss der Server lesen können und umgekehrt.

import type { CalendarDate } from "./calendar.ts";
import type { DayException, DayLog, Entry, EntryEvent } from "./entry.ts";
import type { Habit, Tag } from "./habit.ts";
import type { FocusRun } from "./focus.ts";
import type { FreezeEntry } from "./freeze.ts";
import { type Timestamp, now, parseTimestamp } from "./timestamp.ts";

/// Erhöht sich, sobald sich das Format so ändert, dass ältere Leser scheitern
/// würden. Der Import weist unbekannte Versionen ab, statt zu raten.
export const CURRENT_FORMAT_VERSION = 1;

export type BackupScope =
  /// Der gesamte Bestand.
  | "full"
  /// Eine Auswahl einzelner Habits samt ihrem Verlauf.
  | "habits";

/// Eine Sicherungsdatei — der vollständige Bestand oder einzelne Habits.
///
/// Bewusst JSON aus genau den Domänentypen, die auch die API überträgt: die
/// Datei ist dadurch lesbar, diffbar und ohne Übersetzungsschicht verwertbar.
///
/// **Enthalten sind nur lebende Zeilen.** Grabsteine (`deletedAt`) sind eine
/// Angelegenheit des Sync-Protokolls, nicht der Sicherung — eine Sicherung
/// beschreibt den Bestand, nicht seine Geschichte.
export type BackupFile = {
  formatVersion: number;
  exportedAt: Timestamp;
  /// Wer die Datei geschrieben hat, z. B. `"HabitTracker/1.0 (macOS)"`.
  generator: string;
  scope: BackupScope;

  habits: Habit[];
  tags: Tag[];
  entries: Entry[];
  events: EntryEvent[];
  exceptions: DayException[];
  dayLogs: DayLog[];
  focusRuns: FocusRun[];
  freezes: FreezeEntry[];
};

export function makeBackup(
  generator: string, scope: BackupScope, inhalt: Partial<BackupFile> = {},
): BackupFile {
  return {
    formatVersion: CURRENT_FORMAT_VERSION,
    exportedAt: now(),
    generator,
    scope,
    habits: [], tags: [], entries: [], events: [],
    exceptions: [], dayLogs: [], focusRuns: [], freezes: [],
    ...inhalt,
  };
}

/// Zusammenfassung für die Bestätigung vor dem Import.
export function summary(file: BackupFile): string {
  const teile: string[] = [];
  const zaehle = (liste: unknown[], wort: string) => {
    if (liste.length > 0) teile.push(`${liste.length} ${wort}`);
  };
  zaehle(file.habits, "Habits");
  zaehle(file.tags, "Tags");
  zaehle(file.entries, "Einträge");
  zaehle(file.events, "Zeitstempel");
  zaehle(file.exceptions, "Ausnahmen");
  zaehle(file.dayLogs, "Journaltage");
  zaehle(file.focusRuns, "Fokus-Läufe");
  zaehle(file.freezes, "Freeze-Buchungen");
  return teile.length === 0 ? "leer" : teile.join(" · ");
}

/// Früheste und späteste Datumsangabe über alle Datensätze.
export function dateRange(file: BackupFile): { from: CalendarDate; to: CalendarDate } | null {
  const daten: CalendarDate[] = [
    ...file.entries.map((x) => x.date),
    ...file.events.map((x) => x.date),
    ...file.exceptions.map((x) => x.date),
    ...file.dayLogs.map((x) => x.date),
    ...file.focusRuns.map((x) => x.startsOn),
    ...file.focusRuns.map((x) => x.endsOn),
  ];
  if (daten.length === 0) return null;
  // Kalendertage sind Zeichenketten, die sich chronologisch sortieren.
  let from = daten[0]!, to = daten[0]!;
  for (const d of daten) {
    if (d < from) from = d;
    if (d > to) to = d;
  }
  return { from, to };
}

// MARK: - Kodierung

/// Liest eine Sicherungsdatei.
///
/// Fehlende Listen sind kein Fehler: eine Sicherung, die vor einer neuen
/// Tabelle geschrieben wurde, muss weiter lesbar bleiben — sonst wäre jede
/// Erweiterung ein Bruch. Aus demselben Grund darf eine fremd erzeugte Datei
/// leere Listen weglassen. Genau das macht auch der Decoder in Swift.
export function parseBackup(text: string): BackupFile {
  const roh = JSON.parse(text) as Record<string, unknown>;
  if (typeof roh !== "object" || roh === null) {
    throw new Error("Keine Sicherungsdatei: kein JSON-Objekt");
  }
  const version = roh["formatVersion"];
  if (typeof version !== "number") {
    throw new Error("Keine Sicherungsdatei: formatVersion fehlt");
  }
  const exportiert = typeof roh["exportedAt"] === "string"
    ? parseTimestamp(roh["exportedAt"])
    : null;
  if (!exportiert) {
    throw new Error("Keine Sicherungsdatei: exportedAt fehlt oder ist kein Zeitstempel");
  }

  const liste = <T>(schluessel: string): T[] => {
    const wert = roh[schluessel];
    return Array.isArray(wert) ? (wert as T[]) : [];
  };

  return {
    formatVersion: version,
    exportedAt: exportiert,
    generator: typeof roh["generator"] === "string" ? roh["generator"] : "unbekannt",
    scope: roh["scope"] === "habits" ? "habits" : "full",
    habits: liste<Habit>("habits"),
    tags: liste<Tag>("tags"),
    entries: liste<Entry>("entries"),
    events: liste<EntryEvent>("events"),
    exceptions: liste<DayException>("exceptions"),
    dayLogs: liste<DayLog>("dayLogs"),
    focusRuns: liste<FocusRun>("focusRuns"),
    freezes: liste<FreezeEntry>("freezes"),
  };
}

/// Schreibt eine Sicherungsdatei: eingerückt, mit sortierten Schlüsseln und
/// ohne leere Felder.
///
/// Alle drei Eigenschaften stehen so in `BackupCoding` auf der Swift-Seite.
/// Sortiert und eingerückt, damit eine Sicherung sich in Git oder einem
/// Diff-Werkzeug vergleichen lässt; ohne `null`, weil Swifts Encoder ein leeres
/// Optional gar nicht erst schreibt.
///
/// **Von Hand geschrieben statt mit `JSON.stringify(…, null, 2)`**, weil
/// Foundations `.prettyPrinted` ein Leerzeichen *vor* den Doppelpunkt setzt.
/// Eine Sicherung soll aber eine kanonische Form haben, gleich welche der
/// beiden Fassungen sie geschrieben hat — sonst sieht dieselbe Datei nach einem
/// Export aus dem Browser durchweg anders aus als nach einem vom Mac, obwohl
/// sich nichts geändert hat. Werte kommen weiterhin aus `JSON.stringify`, damit
/// Maskierung und Zahlformat nicht von Hand nachgebaut werden.
export function encodeBackup(file: BackupFile): string {
  return schreibeWert(aufbereiten(file), "");
}

function schreibeWert(wert: unknown, einzug: string): string {
  const innen = einzug + "  ";

  if (Array.isArray(wert)) {
    if (wert.length === 0) return "[\n\n" + einzug + "]";
    const teile = wert.map((eintrag) => innen + schreibeWert(eintrag, innen));
    return "[\n" + teile.join(",\n") + "\n" + einzug + "]";
  }

  if (wert !== null && typeof wert === "object") {
    const eintraege = Object.entries(wert as Record<string, unknown>);
    if (eintraege.length === 0) return "{\n\n" + einzug + "}";
    const teile = eintraege.map(
      ([schluessel, inhalt]) =>
        innen + JSON.stringify(schluessel) + " : " + schreibeWert(inhalt, innen));
    return "{\n" + teile.join(",\n") + "\n" + einzug + "}";
  }

  return JSON.stringify(wert);
}

function aufbereiten(wert: unknown): unknown {
  if (Array.isArray(wert)) return wert.map(aufbereiten);
  if (wert === null || typeof wert !== "object") return wert;
  const objekt = wert as Record<string, unknown>;
  const ergebnis: Record<string, unknown> = {};
  for (const schluessel of Object.keys(objekt).sort()) {
    const inhalt = objekt[schluessel];
    if (inhalt === null || inhalt === undefined) continue;
    ergebnis[schluessel] = aufbereiten(inhalt);
  }
  return ergebnis;
}

// MARK: - Prüfung

/// Was an einer Sicherungsdatei nicht stimmt.
///
/// Getrennt nach "Import unmöglich" und "Import möglich, aber erwähnenswert" —
/// eine Wiederherstellung soll nicht an einer Kleinigkeit scheitern, aber auch
/// nichts stillschweigend verschlucken.
export type BackupProblem =
  | { readonly code: "unsupportedVersion"; readonly found: number; readonly supported: number }
  | { readonly code: "habitWithoutRules"; readonly name: string }
  | { readonly code: "duplicateHabitId"; readonly habitId: string }
  | { readonly code: "duplicateEntry"; readonly habitId: string; readonly date: CalendarDate }
  | { readonly code: "orphanedRows"; readonly table: string; readonly count: number };

/// Ob dieses Problem den Import verhindert.
export function isFatal(problem: BackupProblem): boolean {
  switch (problem.code) {
    case "unsupportedVersion":
    case "habitWithoutRules":
    case "duplicateHabitId":
      return true;
    case "duplicateEntry":
    case "orphanedRows":
      return false;
  }
}

export function describeProblem(problem: BackupProblem): string {
  switch (problem.code) {
    case "unsupportedVersion":
      return `Dateiformat ${problem.found} ist neuer als unterstützt (${problem.supported}) — bitte die App aktualisieren`;
    case "habitWithoutRules":
      return `Habit „${problem.name}“ hat keinen Zeitplan`;
    case "duplicateHabitId":
      return `Habit ${problem.habitId} kommt mehrfach vor`;
    case "duplicateEntry":
      return `Mehrere Einträge für Habit ${problem.habitId} am ${problem.date} — der letzte gewinnt`;
    case "orphanedRows":
      return `${problem.count} Zeile(n) in ${problem.table} verweisen auf einen Habit, der weder in der Datei noch in der Datenbank steht — sie werden übersprungen`;
  }
}

/// Strukturprüfung ohne Datenbankzugriff.
///
/// Ob referenzierte Habits *existieren*, kann erst der Store beurteilen — er
/// kennt den vorhandenen Bestand. Hier steht nur, was die Datei aus sich heraus
/// widerlegt.
export function validate(file: BackupFile): BackupProblem[] {
  const problems: BackupProblem[] = [];

  if (file.formatVersion > CURRENT_FORMAT_VERSION) {
    problems.push({
      code: "unsupportedVersion",
      found: file.formatVersion,
      supported: CURRENT_FORMAT_VERSION,
    });
  }

  const gesehen = new Set<string>();
  for (const habit of file.habits) {
    if (gesehen.has(habit.id)) problems.push({ code: "duplicateHabitId", habitId: habit.id });
    gesehen.add(habit.id);
    if (habit.rules.length === 0) {
      problems.push({ code: "habitWithoutRules", name: habit.name });
    }
  }

  // Der natürliche Schlüssel muss eindeutig sein, sonst ist unklar, welcher
  // Tageswert gilt.
  const gesehenEintraege = new Set<string>();
  for (const entry of file.entries) {
    const key = `${entry.habitId} ${entry.date}`;
    if (gesehenEintraege.has(key)) {
      problems.push({ code: "duplicateEntry", habitId: entry.habitId, date: entry.date });
    }
    gesehenEintraege.add(key);
  }

  return problems;
}

// MARK: - Import

/// Wie eine Sicherung eingespielt wird.
export type ImportMode =
  /// Zusammenführen: Bekanntes wird aktualisiert, wenn die Datei neuer ist,
  /// Unbekanntes angelegt. Nichts wird gelöscht.
  ///
  /// Das ist die Betriebsart für "einen einzelnen Habit dazuholen" und dieselbe
  /// Regel, nach der auch der Abgleich entscheidet.
  | "merge"
  /// Ersetzen: Der bisherige Bestand wird verworfen und durch die Datei
  /// ersetzt. Für die Wiederherstellung nach einer Neuinstallation.
  | "replace";

export function importModeLabel(mode: ImportMode): string {
  return mode === "merge" ? "Zusammenführen" : "Ersetzen";
}

export function importModeExplanation(mode: ImportMode): string {
  return mode === "merge"
    ? "Vorhandenes wird nur überschrieben, wenn die Datei neuer ist. Nichts geht verloren."
    : "Der gesamte bisherige Bestand wird gelöscht und durch die Datei ersetzt.";
}

export type ImportCounts = {
  inserted: number;
  updated: number;
  /// Übersprungen, weil der vorhandene Datensatz neuer war.
  skipped: number;
};

export function emptyCounts(): ImportCounts {
  return { inserted: 0, updated: 0, skipped: 0 };
}

export function countsTotal(counts: ImportCounts): number {
  return counts.inserted + counts.updated + counts.skipped;
}

/// Die Tabellen, über die ein Import Buch führt — an einer Stelle aufgezählt,
/// damit eine neue Tabelle nicht an drei Orten nachgetragen werden muss.
export const IMPORT_TABELLEN = [
  "habits", "tags", "entries", "events",
  "exceptions", "dayLogs", "focusRuns", "freezes",
] as const;

export type ImportTabelle = (typeof IMPORT_TABELLEN)[number];

/// Was ein Import tatsächlich getan hat.
export type ImportReport = {
  mode: ImportMode;
  counts: Record<ImportTabelle, ImportCounts>;
  /// Nicht fatale Auffälligkeiten, die dem Nutzer angezeigt werden sollten.
  problems: BackupProblem[];
};

export function emptyReport(mode: ImportMode): ImportReport {
  const counts = {} as Record<ImportTabelle, ImportCounts>;
  for (const tabelle of IMPORT_TABELLEN) counts[tabelle] = emptyCounts();
  return { mode, counts, problems: [] };
}

export function totalInserted(report: ImportReport): number {
  return IMPORT_TABELLEN.reduce((summe, t) => summe + report.counts[t].inserted, 0);
}
export function totalUpdated(report: ImportReport): number {
  return IMPORT_TABELLEN.reduce((summe, t) => summe + report.counts[t].updated, 0);
}
export function totalSkipped(report: ImportReport): number {
  return IMPORT_TABELLEN.reduce((summe, t) => summe + report.counts[t].skipped, 0);
}

export function reportSummary(report: ImportReport): string {
  const teile: string[] = [];
  const neu = totalInserted(report);
  const aktualisiert = totalUpdated(report);
  const unveraendert = totalSkipped(report);
  if (neu > 0) teile.push(`${neu} neu`);
  if (aktualisiert > 0) teile.push(`${aktualisiert} aktualisiert`);
  if (unveraendert > 0) teile.push(`${unveraendert} unverändert`);
  return teile.length === 0 ? "Nichts zu tun" : teile.join(" · ");
}

/// Die Datei kann nicht eingespielt werden.
export class BackupError extends Error {
  // Ausgeschrieben statt als Parameter-Eigenschaft: das wäre Syntax, die Node
  // beim Entfernen der Typen nicht wegkürzen kann.
  readonly problems: BackupProblem[];

  constructor(problems: BackupProblem[]) {
    super("Die Datei kann nicht eingespielt werden:\n"
      + problems.map((p) => `• ${describeProblem(p)}`).join("\n"));
    this.name = "BackupError";
    this.problems = problems;
  }
}
