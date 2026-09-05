/// Portiert aus `apple/HabitKit/Sources/HabitCore/Models/Entry.swift`.

import type { CalendarDate } from "./calendar.ts";
import type { EntrySource } from "./habit.ts";
import { type Timestamp, epochMs, minutesBetween } from "./timestamp.ts";

/// Der autoritative Tagesdatensatz. **Nur diesen liest die Streak-Engine.**
///
/// Adressiert wird er über `(habitId, date)`, nicht über `id` — dadurch ist das
/// Schreiben idempotent und ein Sync-Konflikt („beide Geräte haben heute
/// abgehakt") löst sich von selbst auf.
export type Entry = {
  id: string;
  habitId: string;
  date: CalendarDate;
  /// `binary`: 0 oder 1 · `quantity`: die Menge · `avoid`: Anzahl Verstöße.
  value: number;
  note?: string | null;
  source: EntrySource;
  createdAt: Timestamp;
  updatedAt: Timestamp;
  deletedAt?: Timestamp | null;
};

/// Optionales Zeitstempel-Detail für Habits mit `tracksTime`.
///
/// Summiert sich zu `Entry.value` — die Invariante hält der Store, nicht der
/// Aufrufer. Die Domäne kennt diesen Typ absichtlich nur als Datenmodell und
/// wertet ihn nirgends aus.
export type EntryEvent = {
  id: string;
  habitId: string;
  /// Der lokale Tag, zu dem das Event zählt — denormalisiert, damit die
  /// Tageszuordnung nicht von der Zeitzone des Lesers abhängt.
  date: CalendarDate;
  /// Beginn der Sitzung.
  at: Timestamp;
  /// Ende, wenn es eine Sitzung mit Dauer ist.
  ///
  /// Ist es gesetzt, **leitet der Store `value` daraus ab** (Minuten), statt
  /// es vom Aufrufer zu übernehmen. Zwei Felder, die dasselbe sagen, driften
  /// sonst auseinander — dieselbe Begründung, aus der nicht der Aufrufer,
  /// sondern der Store die Tagessumme hält.
  endsAt?: Timestamp | null;
  value: number;
  note?: string | null;
  source: EntrySource;
  createdAt: Timestamp;
  updatedAt: Timestamp;
  deletedAt?: Timestamp | null;
};

/// Dauer in Minuten — `null`, solange kein Ende gesetzt ist.
export function durationMinutes(event: EntryEvent): number | null {
  return event.endsAt == null ? null : minutesBetween(event.at, event.endsAt);
}

/// Der Wert, der für diesen Eintrag zählt.
///
/// Bei einer Sitzung mit Ende die Dauer, sonst der gesetzte Wert. Der Store
/// schreibt genau das in die Spalte, damit die Tagessumme stimmt, ohne dass
/// jemand beide Felder von Hand im Einklang halten muss.
export function effectiveValue(event: EntryEvent): number {
  return durationMinutes(event) ?? event.value;
}

/// Ob Start und Ende zueinander passen. Ein Ende vor dem Start ist kein
/// Grenzfall, sondern ein Tippfehler.
export function hasValidInterval(event: EntryEvent): boolean {
  if (event.endsAt == null) return true;
  return epochMs(event.endsAt) > epochMs(event.at);
}

/// Warum ein geplanter Tag nicht als verpasst zählt.
///
/// Streak Freeze, Urlaub und bewusster Ruhetag sind für die Engine dasselbe
/// Konzept — sie unterscheiden sich nur darin, wie sie in die Statistik eingehen.
export type ExceptionKind =
  /// Eingelöster Token: schützt den Streak, zählt aber weiter als verpasst.
  | "frozen"
  /// Urlaub: der Tag war nie vorgesehen, fällt ganz aus der Statistik.
  | "paused"
  /// Bewusster Ruhetag: wie `paused`, nur manuell für einen einzelnen Tag.
  | "skipped";

export const AUSNAHMEARTEN: readonly ExceptionKind[] = ["frozen", "paused", "skipped"];

/// Ob der Tag so behandelt wird, als wäre er nie geplant gewesen.
export function removesDayFromSchedule(kind: ExceptionKind): boolean {
  return kind !== "frozen";
}

export type DayException = {
  id: string;
  /// `null` heißt: gilt für alle Habits (Urlaub).
  habitId?: string | null;
  date: CalendarDate;
  kind: ExceptionKind;
  reason?: string | null;
  createdAt: Timestamp;
  updatedAt: Timestamp;
  deletedAt?: Timestamp | null;
};

/// Tages-Journal, unabhängig von einzelnen Habits. Basis für die
/// Korrelations-Auswertung.
export type DayLog = {
  date: CalendarDate;
  userId: string;
  mood?: number | null;   // 1...5
  energy?: number | null; // 1...5
  sleepHours?: number | null;
  note?: string | null;
  createdAt: Timestamp;
  updatedAt: Timestamp;
  deletedAt?: Timestamp | null;
};
