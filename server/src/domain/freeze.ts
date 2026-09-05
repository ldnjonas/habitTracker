/// Portiert aus `apple/HabitKit/Sources/HabitCore/Freeze.swift`.

import type { CalendarDate } from "./calendar.ts";
import type { DayStatus } from "./dayStatus.ts";
import type { Timestamp } from "./timestamp.ts";
import { type FocusOutcome, type FocusRun, isSuccess } from "./focus.ts";

/// Wofür eine Buchung im Freeze-Konto steht.
export type FreezeReason =
  /// Ein Fokus-Lauf wurde durchgezogen.
  | "focusCompleted"
  /// Ein Freeze wurde für einen Tag eingelöst.
  | "applied"
  /// Startguthaben oder von Hand vergeben.
  | "granted";

/// Eine einzelne Buchung.
///
/// Bewusst ein Ledger und kein Zähler: der Kontostand ist die Summe, nie ein
/// gespeicherter Wert. Ein Zähler kann falsch werden, ohne dass man sieht wie —
/// eine Buchungsreihe nicht, und beim Sync bleibt sie konfliktfrei, weil nur
/// angehängt wird. Deshalb hat die Tabelle auch kein `updated_at` und keinen
/// Grabstein: Buchungen werden nicht geändert und nicht gelöscht.
export type FreezeEntry = {
  id: string;
  userId: string;
  /// Positiv verdient, negativ eingelöst.
  amount: number;
  reason: FreezeReason;
  /// Bei einer Einlösung: der gerettete Habit.
  habitId?: string | null;
  /// Bei einer Einlösung: der gerettete Tag.
  date?: CalendarDate | null;
  /// Bei `focusCompleted`: der Lauf, der eingezahlt hat.
  ///
  /// Ohne diesen Bezug ließe sich nicht sagen, ob ein Lauf schon eingezahlt
  /// hat — und da `evaluate` sein Ergebnis bei jedem Aufruf neu ausrechnet,
  /// zahlte derselbe Lauf sonst bei jedem Nachladen erneut ein.
  focusRunId?: string | null;
  createdAt: Timestamp;
};

/// Was ein durchgezogener Fokus einbringt.
export const FREEZE_PER_COMPLETED_FOCUS = 1;

/// Obergrenze des Guthabens.
///
/// Ohne sie sammelt man über Monate ein Polster an, das jeden Streak beliebig
/// lange am Leben hält — dann sagt er nichts mehr aus. Drei reichen für eine
/// Krankheitswoche und nicht für ein halbes Jahr Nachlässigkeit.
export const FREEZE_MAXIMUM = 3;

/// Der Kontostand: die Summe aller Buchungen.
export function freezeBalance(ledger: FreezeEntry[]): number {
  return ledger.reduce((summe, e) => summe + e.amount, 0);
}

/// Welche durchgezogenen Läufe noch nicht eingezahlt haben.
///
/// Rein und ohne Datenbank, damit die Regel testbar ist und beide Fassungen
/// dieselbe treffen. Die Obergrenze wird dabei laufend mitgeführt: steht das
/// Konto voll, verfällt der Anspruch — er wird nicht aufgespart und später
/// nachgezahlt, sonst wäre die Grenze wirkungslos.
export function pendingFreezeAwards(
  outcomes: { run: FocusRun; outcome: FocusOutcome }[],
  ledger: FreezeEntry[],
): FocusRun[] {
  const schonGebucht = new Set(
    ledger.map((e) => e.focusRunId).filter((id): id is string => id != null));
  let stand = freezeBalance(ledger);
  const faellig: FocusRun[] = [];

  // Älteste zuerst: wer früher durchgezogen hat, bekommt bei knapper
  // Obergrenze auch zuerst.
  const kandidaten = outcomes
    .filter((k) => isSuccess(k.outcome) && !schonGebucht.has(k.run.id))
    .sort((a, b) => (a.run.endsOn < b.run.endsOn ? -1 : a.run.endsOn > b.run.endsOn ? 1 : 0));

  for (const kandidat of kandidaten) {
    if (stand >= FREEZE_MAXIMUM) break;
    faellig.push(kandidat.run);
    stand += FREEZE_PER_COMPLETED_FOCUS;
  }
  return faellig;
}

/// Ob ein Tag sich überhaupt einfrieren lässt.
///
/// Nur ein bereits verpasster Tag: einen erfüllten braucht man nicht zu retten,
/// und der laufende ist noch nicht verloren. Ein Freeze auf die Zukunft wäre
/// eine Vorabentschuldigung — genau das, was der Streak nicht aussagen soll.
export function canFreeze(
  status: DayStatus, date: CalendarDate, today: CalendarDate,
): boolean {
  if (!(date < today)) return false;
  return status.code === "missed";
}
