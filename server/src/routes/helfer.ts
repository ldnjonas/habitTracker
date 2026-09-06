/// Was jeder Endpunkt braucht: Parameter lesen und dabei prüfen.
///
/// Ein fehlendes `from` ist ein Fehler des Aufrufers und muss eine 400 werden,
/// keine 500 — sonst räumt der Server einen Fehler ein, den er nicht gemacht
/// hat, und in den Protokollen steht ein Stapelabzug statt einer Erklärung.

import type { FastifyRequest } from "fastify";
import { type CalendarDate, parseDate } from "../domain/calendar.ts";
import { Fehler } from "../store.ts";

export function datum(roh: unknown, name: string): CalendarDate {
  const wert = parseDate(String(roh ?? ""));
  if (!wert) throw new Fehler(400, `${name} muss ein Datum als YYYY-MM-DD sein`);
  return wert;
}

/// `from` und `to` aus der Abfrage — beide Pflicht, `from` nicht nach `to`.
export function zeitraum(anfrage: FastifyRequest): { from: CalendarDate; to: CalendarDate } {
  const abfrage = anfrage.query as { from?: string; to?: string };
  const from = datum(abfrage.from, "from");
  const to = datum(abfrage.to, "to");
  if (from > to) throw new Fehler(400, "from liegt nach to");
  return { from, to };
}

export function pfad<T extends Record<string, string>>(anfrage: FastifyRequest): T {
  return anfrage.params as T;
}

export function rumpf<T>(anfrage: FastifyRequest): T {
  if (anfrage.body === null || typeof anfrage.body !== "object") {
    throw new Fehler(400, "Der Rumpf muss ein JSON-Objekt sein");
  }
  return anfrage.body as T;
}
