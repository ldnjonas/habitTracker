/// Was der Abgleich überträgt — an genau einer Stelle beschrieben.
///
/// Lesen und Schreiben des Deltas laufen beide über diese Liste. Zwei getrennte
/// Aufzählungen wären zwei Gelegenheiten, eine Tabelle zu vergessen; genau so
/// entsteht ein Abgleich, der eine Sorte Daten stillschweigend fallen lässt.
///
/// Die Nutzlast trägt bewusst dieselben Formen wie die Sicherungsdatei
/// (`BackupFile` in HabitCore): ein Habit kommt samt seinen Regeln und Tags,
/// nicht als drei getrennte Tabellen. Der Client hat die passenden Typen damit
/// schon, und die Zerlegung in Tabellen bleibt Sache des Servers.

export type Spalte = {
  /// Name im JSON.
  feld: string;
  /// Name in der Datenbank.
  spalte: string;
  /// Wie der Wert für SQLite aufbereitet wird.
  art?: "bool" | "json";
};

export type Tabelle = {
  /// Schlüssel im Delta, z. B. "entries".
  schluessel: string;
  tabelle: string;
  /// Spalten des Primärschlüssels.
  primaer: string[];
  spalten: Spalte[];
  /// Ob die Zeile einen Grabstein tragen kann. Das Freeze-Konto kann nicht.
  loeschbar: boolean;
};

const zeitstempel: Spalte[] = [
  { feld: "createdAt", spalte: "created_at" },
  { feld: "updatedAt", spalte: "updated_at" },
  { feld: "deletedAt", spalte: "deleted_at" },
];

export const TABELLEN: Tabelle[] = [
  {
    schluessel: "habits",
    tabelle: "habit",
    primaer: ["id"],
    loeschbar: true,
    spalten: [
      { feld: "id", spalte: "id" },
      { feld: "userId", spalte: "user_id" },
      { feld: "name", spalte: "name" },
      { feld: "notes", spalte: "notes" },
      { feld: "kind", spalte: "kind" },
      { feld: "colorHex", spalte: "color_hex" },
      { feld: "symbol", spalte: "symbol" },
      { feld: "sortOrder", spalte: "sort_order" },
      { feld: "timeOfDay", spalte: "time_of_day" },
      { feld: "preferredTime", spalte: "preferred_time" },
      { feld: "tracksTime", spalte: "tracks_time", art: "bool" },
      { feld: "startsOn", spalte: "starts_on" },
      { feld: "endsOn", spalte: "ends_on" },
      { feld: "archivedOn", spalte: "archived_on" },
      { feld: "healthKitLink", spalte: "health_kit_link", art: "json" },
      ...zeitstempel,
    ],
  },
  {
    schluessel: "tags",
    tabelle: "tag",
    primaer: ["id"],
    loeschbar: true,
    spalten: [
      { feld: "id", spalte: "id" },
      { feld: "userId", spalte: "user_id" },
      { feld: "name", spalte: "name" },
      { feld: "colorHex", spalte: "color_hex" },
      { feld: "sortOrder", spalte: "sort_order" },
      ...zeitstempel,
    ],
  },
  {
    schluessel: "entries",
    tabelle: "entry",
    primaer: ["id"],
    loeschbar: true,
    spalten: [
      { feld: "id", spalte: "id" },
      { feld: "userId", spalte: "user_id" },
      { feld: "habitId", spalte: "habit_id" },
      { feld: "date", spalte: "date" },
      { feld: "value", spalte: "value" },
      { feld: "note", spalte: "note" },
      { feld: "source", spalte: "source" },
      ...zeitstempel,
    ],
  },
  {
    schluessel: "events",
    tabelle: "entry_event",
    primaer: ["id"],
    loeschbar: true,
    spalten: [
      { feld: "id", spalte: "id" },
      { feld: "habitId", spalte: "habit_id" },
      { feld: "date", spalte: "date" },
      { feld: "at", spalte: "at" },
      { feld: "endsAt", spalte: "ends_at" },
      { feld: "value", spalte: "value" },
      { feld: "note", spalte: "note" },
      { feld: "source", spalte: "source" },
      ...zeitstempel,
    ],
  },
  {
    schluessel: "exceptions",
    tabelle: "day_exception",
    primaer: ["id"],
    loeschbar: true,
    spalten: [
      { feld: "id", spalte: "id" },
      { feld: "userId", spalte: "user_id" },
      { feld: "habitId", spalte: "habit_id" },
      { feld: "date", spalte: "date" },
      { feld: "kind", spalte: "kind" },
      { feld: "reason", spalte: "reason" },
      ...zeitstempel,
    ],
  },
  {
    schluessel: "dayLogs",
    tabelle: "day_log",
    primaer: ["user_id", "date"],
    loeschbar: true,
    spalten: [
      { feld: "userId", spalte: "user_id" },
      { feld: "date", spalte: "date" },
      { feld: "mood", spalte: "mood" },
      { feld: "energy", spalte: "energy" },
      { feld: "sleepHours", spalte: "sleep_hours" },
      { feld: "note", spalte: "note" },
      ...zeitstempel,
    ],
  },
  {
    schluessel: "focusRuns",
    tabelle: "focus_run",
    primaer: ["id"],
    loeschbar: true,
    spalten: [
      { feld: "id", spalte: "id" },
      { feld: "userId", spalte: "user_id" },
      { feld: "title", spalte: "title" },
      { feld: "startsOn", spalte: "starts_on" },
      { feld: "endsOn", spalte: "ends_on" },
      { feld: "habitIds", spalte: "habit_ids", art: "json" },
      { feld: "abandonedOn", spalte: "abandoned_on" },
      ...zeitstempel,
    ],
  },
  {
    schluessel: "freezes",
    tabelle: "freeze_ledger",
    primaer: ["id"],
    // Buchungen werden nicht gelöscht — deshalb auch kein `updatedAt` und
    // kein Last-Write-Wins: eine Zeile wird angelegt oder sie ist schon da.
    loeschbar: false,
    spalten: [
      { feld: "id", spalte: "id" },
      { feld: "userId", spalte: "user_id" },
      { feld: "amount", spalte: "amount" },
      { feld: "reason", spalte: "reason" },
      { feld: "habitId", spalte: "habit_id" },
      { feld: "date", spalte: "date" },
      { feld: "focusRunId", spalte: "focus_run_id" },
      { feld: "createdAt", spalte: "created_at" },
    ],
  },
];
