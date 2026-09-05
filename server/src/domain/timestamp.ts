/// Zeitpunkte — was in Swift `Foundation.Date` ist.
///
/// Ohne Entsprechung in `HabitCore`, weil Swift den Typ von Foundation bekommt
/// und die Kodierung in `Backup.swift` regelt. Hier braucht es beides an einer
/// Stelle, sonst formatiert jede Datei ein bisschen anders.
///
/// **Ein Zeitstempel ist die ISO-8601-Zeichenkette selbst**, in UTC und mit
/// exakt drei Nachkommastellen — also genau das, was `Date.toISOString()`
/// liefert und was `BackupCoding.string(from:)` in Swift von Hand nachbaut.
/// Die Millisekunden sind nicht Kosmetik: `updatedAt` entscheidet beim
/// Zusammenführen, welche Fassung gewinnt.

declare const zeitMarke: unique symbol;
export type Timestamp = string & { readonly [zeitMarke]: true };

export function now(): Timestamp {
  return new Date().toISOString() as Timestamp;
}

export function fromEpochMs(ms: number): Timestamp {
  return new Date(Math.round(ms)).toISOString() as Timestamp;
}

export function epochMs(zeit: Timestamp): number {
  return Date.parse(zeit);
}

/// Bringt einen beliebigen ISO-8601-Zeitstempel auf die kanonische Form.
///
/// Nötig, weil Sicherungsdateien aus anderen Werkzeugen ohne Bruchteile oder
/// mit einem Zonenversatz statt `Z` kommen dürfen — Swifts Decoder lässt beides
/// zu. `null`, wenn es kein Zeitstempel ist.
export function parseTimestamp(roh: string): Timestamp | null {
  const ms = Date.parse(roh);
  return Number.isNaN(ms) ? null : (new Date(ms).toISOString() as Timestamp);
}

export function requireTimestamp(roh: string): Timestamp {
  const zeit = parseTimestamp(roh);
  if (!zeit) throw new Error(`Kein ISO-8601-Zeitstempel: ${roh}`);
  return zeit;
}

/// Vergleich über den Zahlenwert, nicht über die Zeichenkette: nur die
/// kanonische Form sortiert lexikografisch richtig, und hereinkommende
/// Zeitstempel sind es nicht zwingend.
export function isAfter(a: Timestamp, b: Timestamp): boolean {
  return epochMs(a) > epochMs(b);
}

/// Minuten zwischen zwei Zeitpunkten — positiv, wenn `bis` später liegt.
export function minutesBetween(von: Timestamp, bis: Timestamp): number {
  return (epochMs(bis) - epochMs(von)) / 60_000;
}
