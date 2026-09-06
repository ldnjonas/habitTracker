/// Was jeder Endpunkt braucht: Parameter lesen und dabei prüfen.
///
/// Ein fehlendes `from` ist ein Fehler des Aufrufers und muss eine 400 werden,
/// keine 500 — sonst räumt der Server einen Fehler ein, den er nicht gemacht
/// hat, und in den Protokollen steht ein Stapelabzug statt einer Erklärung.

import type { Context } from "hono";
import { type CalendarDate, parseDate } from "../domain/calendar.ts";
import { Fehler } from "../store.ts";

export function datum(roh: unknown, name: string): CalendarDate {
  const wert = parseDate(String(roh ?? ""));
  if (!wert) throw new Fehler(400, `${name} muss ein Datum als YYYY-MM-DD sein`);
  return wert;
}

/// `from` und `to` aus der Abfrage — beide Pflicht, `from` nicht nach `to`.
export function zeitraum(c: Context): { from: CalendarDate; to: CalendarDate } {
  const from = datum(c.req.query("from"), "from");
  const to = datum(c.req.query("to"), "to");
  if (from > to) throw new Fehler(400, "from liegt nach to");
  return { from, to };
}

export function pfad<T extends Record<string, string>>(c: Context): T {
  return c.req.param() as T;
}

/// Der Rumpf als Objekt.
///
/// Asynchron, seit der Server auf Hono steht: dort wird der Rumpf erst gelesen,
/// wenn jemand danach fragt, und nicht vorab für jede Anfrage.
export async function rumpf<T>(c: Context): Promise<T> {
  let gelesen: unknown;
  try {
    gelesen = await c.req.json();
  } catch {
    throw new Fehler(400, "Der Rumpf muss ein JSON-Objekt sein");
  }
  if (gelesen === null || typeof gelesen !== "object") {
    throw new Fehler(400, "Der Rumpf muss ein JSON-Objekt sein");
  }
  return gelesen as T;
}
