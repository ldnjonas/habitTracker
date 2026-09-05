/// Ein lokaler Kalendertag ohne Uhrzeit und ohne Zeitzone.
///
/// Portiert aus `apple/HabitKit/Sources/HabitCore/Models/CalendarDate.swift`.
/// Zwei Abweichungen von der Swift-Fassung, beide bewusst:
///
/// 1. **Ein Tag ist hier die ISO-Zeichenkette selbst**, kein Objekt mit drei
///    Feldern. In TypeScript ist das der passendere Träger: `YYYY-MM-DD`
///    sortiert sich lexikografisch wie chronologisch, taugt ohne Umweg als
///    Schlüssel eines `Map`/`Record`, und die JSON-Darstellung ist dieselbe.
///    Der Markierungstyp verhindert, dass eine beliebige Zeichenkette
///    hineinrutscht.
/// 2. **Jede Division ist `Math.trunc`.** Swift teilt ganzzahlig gegen null,
///    JavaScript rechnet mit Fließkomma. Bei Tagesnummern vor 1970 — die sind
///    negativ — liefe `Math.floor` um einen Tag daneben.

declare const kalenderMarke: unique symbol;
export type CalendarDate = string & { readonly [kalenderMarke]: true };

/// Ganzzahlige Division gegen null, wie Swifts `/` auf `Int`.
const div = (a: number, b: number): number => Math.trunc(a / b);

/// Modulo mit nicht-negativem Ergebnis. Der Rest in JavaScript wie in Swift
/// folgt dem Vorzeichen des Dividenden, und Tagesnummern vor 1970 sind negativ.
const mod = (a: number, b: number): number => ((a % b) + b) % b;

export function isLeapYear(year: number): boolean {
  return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
}

export function daysInMonth(year: number, month: number): number {
  switch (month) {
    case 1: case 3: case 5: case 7: case 8: case 10: case 12: return 31;
    case 4: case 6: case 9: case 11: return 30;
    case 2: return isLeapYear(year) ? 29 : 28;
    default: return 0;
  }
}

/// Baut einen Tag aus seinen Teilen. `null` bei einem Datum, das es nicht gibt.
export function makeDate(year: number, month: number, day: number): CalendarDate | null {
  if (month < 1 || month > 12) return null;
  if (day < 1 || day > daysInMonth(year, month)) return null;
  return unchecked(year, month, day);
}

/// Ohne Gültigkeitsprüfung — nur für Werte, die schon aus der Arithmetik stammen.
function unchecked(year: number, month: number, day: number): CalendarDate {
  const y = year < 0 ? `-${String(-year).padStart(4, "0")}` : String(year).padStart(4, "0");
  return `${y}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}` as CalendarDate;
}

/// Erwartet exakt `YYYY-MM-DD`. `null`, wenn es das nicht ist.
export function parseDate(iso: string): CalendarDate | null {
  const treffer = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  if (!treffer) return null;
  return makeDate(Number(treffer[1]), Number(treffer[2]), Number(treffer[3]));
}

/// Wie `parseDate`, wirft aber statt `null` zu liefern. Für Stellen, an denen
/// ein ungültiges Datum ein Fehler und kein Sonderfall ist.
export function requireDate(iso: string): CalendarDate {
  const datum = parseDate(iso);
  if (!datum) throw new Error(`Kein gültiges YYYY-MM-DD: ${iso}`);
  return datum;
}

export function year(date: CalendarDate): number {
  return Number(date.slice(0, date.length - 6));
}
export function month(date: CalendarDate): number {
  return Number(date.slice(-5, -3));
}
export function day(date: CalendarDate): number {
  return Number(date.slice(-2));
}

// MARK: - Zivilkalender-Arithmetik
//
// Howard Hinnant, „chrono-Compatible Low-Level Date Algorithms". Zeile für
// Zeile dieselbe Rechnung wie in Swift.

/// Tage seit 1970-01-01, auch negativ.
export function dayNumber(date: CalendarDate): number {
  return daysFromCivil(year(date), month(date), day(date));
}

export function fromDayNumber(z: number): CalendarDate {
  const { y, m, d } = civilFromDays(z);
  return unchecked(y, m, d);
}

function daysFromCivil(jahr: number, m: number, d: number): number {
  const y = jahr - (m <= 2 ? 1 : 0);
  const era = div(y >= 0 ? y : y - 399, 400);
  const yoe = y - era * 400;                                        // [0, 399]
  const doy = div(153 * (m + (m > 2 ? -3 : 9)) + 2, 5) + d - 1;     // [0, 365]
  const doe = yoe * 365 + div(yoe, 4) - div(yoe, 100) + doy;        // [0, 146096]
  return era * 146097 + doe - 719468;
}

function civilFromDays(tage: number): { y: number; m: number; d: number } {
  const z = tage + 719468;
  const era = div(z >= 0 ? z : z - 146096, 146097);
  const doe = z - era * 146097;                                     // [0, 146096]
  const yoe = div(doe - div(doe, 1460) + div(doe, 36524) - div(doe, 146096), 365);
  const y = yoe + era * 400;
  const doy = doe - (365 * yoe + div(yoe, 4) - div(yoe, 100));      // [0, 365]
  const mp = div(5 * doy + 2, 153);                                 // [0, 11]
  const d = doy - div(153 * mp + 2, 5) + 1;                         // [1, 31]
  const m = mp + (mp < 10 ? 3 : -9);                                // [1, 12]
  return { y: y + (m <= 2 ? 1 : 0), m, d };
}

// MARK: - Rechnen mit Tagen

export function addDays(date: CalendarDate, count: number): CalendarDate {
  return fromDayNumber(dayNumber(date) + count);
}

/// Tage von `from` bis `to` — positiv, wenn `to` später liegt.
export function daysUntil(from: CalendarDate, to: CalendarDate): number {
  return dayNumber(to) - dayNumber(from);
}

/// Alle Tage von `from` bis **einschließlich** `to`. Leer, wenn `to` davor liegt.
///
/// Ein Vergleich mit `<` genügt hier: `YYYY-MM-DD` ordnet lexikografisch wie
/// chronologisch. Genau dafür ist die Zeichenkette der richtige Träger.
export function through(from: CalendarDate, to: CalendarDate): CalendarDate[] {
  if (from > to) return [];
  const ergebnis: CalendarDate[] = [];
  for (let n = dayNumber(from); n <= dayNumber(to); n++) ergebnis.push(fromDayNumber(n));
  return ergebnis;
}

// MARK: - Wochentage

/// ISO: Montag ist 1, Sonntag ist 7.
export type Weekday = 1 | 2 | 3 | 4 | 5 | 6 | 7;

export function weekday(date: CalendarDate): Weekday {
  // Tagesnummer 0 ist der 1970-01-01, ein Donnerstag (ISO 4).
  return (mod(dayNumber(date) + 3, 7) + 1) as Weekday;
}

/// Montag der Woche, in der dieser Tag liegt.
export function weekStart(date: CalendarDate): CalendarDate {
  return addDays(date, -(weekday(date) - 1));
}

export function weekEnd(date: CalendarDate): CalendarDate {
  return addDays(weekStart(date), 6);
}

// MARK: - Monate

export function monthStart(date: CalendarDate): CalendarDate {
  return unchecked(year(date), month(date), 1);
}

export function monthEnd(date: CalendarDate): CalendarDate {
  const j = year(date), m = month(date);
  return unchecked(j, m, daysInMonth(j, m));
}

/// Denselben Tag `count` Monate später oder früher.
///
/// Fällt der Tag im Zielmonat aus, wird auf dessen letzten gekürzt: vom
/// 31. Januar einen Monat weiter ist der 28. Februar, nicht der 3. März.
export function addMonths(date: CalendarDate, count: number): CalendarDate {
  const total = year(date) * 12 + (month(date) - 1) + count;
  // Hier abrunden statt abschneiden — wie die Swift-Fassung, die dafür
  // ausdrücklich `.rounded(.down)` benutzt.
  const zielJahr = Math.floor(total / 12);
  const zielMonat = total - zielJahr * 12 + 1;
  return unchecked(zielJahr, zielMonat, Math.min(day(date), daysInMonth(zielJahr, zielMonat)));
}
