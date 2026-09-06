/// Die Ressourcen-Endpunkte, über `app.request` — ohne Netz und ohne Datei.
///
/// Geprüft wird nicht nur, dass die Antworten stimmen, sondern auch, dass jede
/// Schreibung im Abgleich ankommt: eine Zeile, die im Browser entsteht und
/// keine Sequenznummer bekommt, steht in der Datenbank und taucht trotzdem in
/// keinem Delta auf. Der Mac sähe sie nie.

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { oeffneEingebettet } from "../src/pglite.ts";
import { baueApp } from "../src/app.ts";
import { addDays } from "../src/domain/calendar.ts";
import { heute } from "../src/store.ts";

const TOKEN = "t".repeat(32);
const KOPF = { authorization: `Bearer ${TOKEN}` };

const HEUTE = heute();
const GESTERN = addDays(HEUTE, -1);
const VORGESTERN = addDays(HEUTE, -2);

type Methode = "GET" | "POST" | "PUT" | "PATCH" | "DELETE";
type Antwort = { statusCode: number; json: <T = any>() => T; body: string };

/// Ein frischer Server je Test — die Datenbank liegt im Arbeitsspeicher.
async function neu() {
  const db = await oeffneEingebettet();
  const app = baueApp(db, TOKEN);

  async function ruf(
    method: Methode, url: string, payload?: unknown,
  ): Promise<Antwort> {
    const antwort = await app.request(url, {
      method,
      headers: payload === undefined ? KOPF : { ...KOPF, "content-type": "application/json" },
      body: payload === undefined ? undefined : JSON.stringify(payload),
    });
    const text = await antwort.text();
    return {
      statusCode: antwort.status,
      body: text,
      json: () => JSON.parse(text),
    } as Antwort;
  }

  /// Wie viele Zeilen der Abgleich seit `since` sieht.
  async function delta(since = 0) {
    const antwort = await app.request(`/sync?since=${since}`, { headers: KOPF });
    return await antwort.json() as any;
  }

  return { db, app, ruf, delta };
}

async function legeHabitAn(
  ruf: (m: Methode, u: string, p?: unknown) => Promise<Antwort>,
  werte: Record<string, unknown> = {},
) {
  const antwort = await ruf("POST", "/habits", {
    name: "Sport",
    rules: [{ effectiveFrom: "2026-01-01", schedule: { kind: "daily" } }],
    ...werte,
  });
  assert.equal(antwort.statusCode, 201, antwort.body);
  return antwort.json();
}

describe("Habits", () => {
  test("Anlegen, lesen, ändern, löschen", async () => {
    const { ruf } = await neu();

    const habit = await legeHabitAn(ruf, { name: "  Sport  ", colorHex: "#FF9500" });
    assert.equal(habit.name, "Sport", "Leerzeichen werden abgeschnitten");
    assert.equal(habit.rules.length, 1);
    assert.deepEqual(habit.tagIds, []);

    const liste = await ruf("GET", "/habits");
    assert.equal(liste.json().length, 1);

    const geaendert = await ruf("PATCH", `/habits/${habit.id}`, { name: "Laufen" });
    assert.equal(geaendert.json().name, "Laufen");

    // Zeitplan und Ziel lassen sich über PATCH **nicht** ändern — sie sind
    // versioniert und laufen über /rules.
    const versuch = await ruf("PATCH", `/habits/${habit.id}`, {
      rules: [{ effectiveFrom: "2026-05-01", schedule: { kind: "daily" } }],
    });
    assert.equal(versuch.json().rules.length, 1);
    assert.equal(versuch.json().rules[0].effectiveFrom, "2026-01-01");

    assert.equal((await ruf("DELETE", `/habits/${habit.id}`)).statusCode, 204);
    assert.equal((await ruf("GET", `/habits/${habit.id}`)).statusCode, 404);
    assert.equal((await ruf("GET", "/habits")).json().length, 0);
  });

  test("Ohne Namen oder ohne Zeitplan gibt es keinen Habit", async () => {
    const { ruf } = await neu();
    assert.equal((await ruf("POST", "/habits", { name: "", rules: [] })).statusCode, 422);
    assert.equal((await ruf("POST", "/habits", { name: "Sport", rules: [] })).statusCode, 422);
  });

  test("Archivierte erscheinen nur auf Nachfrage", async () => {
    const { ruf } = await neu();
    const habit = await legeHabitAn(ruf);
    await ruf("PATCH", `/habits/${habit.id}`, { archivedOn: "2026-02-01" });

    assert.equal((await ruf("GET", "/habits")).json().length, 0);
    assert.equal((await ruf("GET", "/habits?includeArchived=true")).json().length, 1);
  });

  test("Eine Regelversion wird gesetzt und entfernt — die letzte bleibt", async () => {
    const { ruf } = await neu();
    const habit = await legeHabitAn(ruf);

    const mitZweiter = await ruf("PUT", `/habits/${habit.id}/rules/2026-06-01`, {
      schedule: { kind: "timesPerWeek", n: 3 },
    });
    assert.equal(mitZweiter.json().rules.length, 2);

    // Derselbe Tag noch einmal: das überschreibt, statt eine dritte Version
    // anzulegen — „Tippfehler korrigieren" statt „ab heute ändern".
    const korrigiert = await ruf("PUT", `/habits/${habit.id}/rules/2026-06-01`, {
      schedule: { kind: "timesPerWeek", n: 4 },
    });
    assert.equal(korrigiert.json().rules.length, 2);
    assert.equal(korrigiert.json().rules[1].schedule.n, 4);

    const weniger = await ruf("DELETE", `/habits/${habit.id}/rules/2026-06-01`);
    assert.equal(weniger.json().rules.length, 1);

    // Ohne Regel wäre der Habit an keinem Tag mehr auswertbar.
    assert.equal((await ruf("DELETE", `/habits/${habit.id}/rules/2026-01-01`)).statusCode, 422);
  });

  test("Die Tag-Menge wird ersetzt, nicht addiert", async () => {
    const { ruf } = await neu();
    const habit = await legeHabitAn(ruf);
    const a = (await ruf("POST", "/tags", { name: "Gesundheit" })).json();
    const b = (await ruf("POST", "/tags", { name: "Morgens" })).json();

    let mit = await ruf("PUT", `/habits/${habit.id}/tags`, [a.id, b.id]);
    assert.deepEqual(mit.json().tagIds.sort(), [a.id, b.id].sort());

    mit = await ruf("PUT", `/habits/${habit.id}/tags`, [a.id]);
    assert.deepEqual(mit.json().tagIds, [a.id]);

    // Und derselbe Aufruf noch einmal ändert nichts.
    mit = await ruf("PUT", `/habits/${habit.id}/tags`, [a.id]);
    assert.deepEqual(mit.json().tagIds, [a.id]);

    assert.equal((await ruf("GET", `/habits?tag=${a.id}`)).json().length, 1);
    assert.equal((await ruf("GET", `/habits?tag=${b.id}`)).json().length, 0);
  });
});

describe("Einträge", () => {
  test("Der Tages-Upsert ist idempotent", async () => {
    const { ruf } = await neu();
    const habit = await legeHabitAn(ruf);

    const erst = await ruf("PUT", `/habits/${habit.id}/entries/${HEUTE}`, { value: 1 });
    assert.equal(erst.statusCode, 200);
    const nochmal = await ruf("PUT", `/habits/${habit.id}/entries/${HEUTE}`, { value: 1 });
    // Dieselbe Zeile, nicht eine zweite: adressiert über (habitId, date).
    assert.equal(nochmal.json().id, erst.json().id);

    const liste = await ruf("GET", `/entries?from=${VORGESTERN}&to=${HEUTE}`);
    assert.equal(liste.json().length, 1);

    assert.equal((await ruf("DELETE", `/habits/${habit.id}/entries/${HEUTE}`)).statusCode, 204);
    assert.equal((await ruf("GET", `/entries?from=${VORGESTERN}&to=${HEUTE}`)).json().length, 0);

    // Ein Wiedereintrag hebt den Grabstein auf.
    const wieder = await ruf("PUT", `/habits/${habit.id}/entries/${HEUTE}`, { value: 1 });
    assert.equal(wieder.json().id, erst.json().id);
  });

  test("Die Nachtrage-Grenze hält, in beide Richtungen", async () => {
    const { ruf } = await neu();
    const habit = await legeHabitAn(ruf);

    const zuAlt = await ruf("PUT", `/habits/${habit.id}/entries/2020-01-01`, { value: 1 });
    assert.equal(zuAlt.statusCode, 422, "rückwirkend einen perfekten Monat gibt es nicht");

    const morgen = addDays(HEUTE, 1);
    const zukunft = await ruf("PUT", `/habits/${habit.id}/entries/${morgen}`, { value: 1 });
    assert.equal(zukunft.statusCode, 422, "im Voraus abhaken auch nicht");
  });

  test("Ein Datum, das keines ist, ist eine 400 und keine 500", async () => {
    const { ruf } = await neu();
    const habit = await legeHabitAn(ruf);
    assert.equal((await ruf("PUT", `/habits/${habit.id}/entries/gestern`, { value: 1 })).statusCode, 400);
    assert.equal((await ruf("GET", "/entries?from=x&to=y")).statusCode, 400);
    assert.equal((await ruf("GET", `/entries?from=${HEUTE}&to=${VORGESTERN}`)).statusCode, 400);
  });
});

describe("Sitzungen", () => {
  test("Der Tageswert bleibt die Summe der Sitzungen", async () => {
    const { ruf } = await neu();
    const habit = await legeHabitAn(ruf, { tracksTime: true, kind: "quantity" });

    const beginn = `${HEUTE}T07:00:00.000Z`;
    const ende = `${HEUTE}T07:30:00.000Z`;
    const erste = await ruf("PUT", `/habits/${habit.id}/events/11111111-1111-1111-1111-111111111111`, {
      date: HEUTE, at: beginn, endsAt: ende, value: 999,
    });
    assert.equal(erste.statusCode, 200, erste.body);
    // Bei einer Sitzung mit Ende zählt die Dauer, nicht der mitgeschickte Wert.
    assert.equal(erste.json().value, 30);

    let eintraege = (await ruf("GET", `/entries?from=${VORGESTERN}&to=${HEUTE}`)).json();
    assert.equal(eintraege.length, 1);
    assert.equal(eintraege[0].value, 30, "entry.value == Σ events");

    await ruf("PUT", `/habits/${habit.id}/events/22222222-2222-2222-2222-222222222222`, {
      date: HEUTE, at: `${HEUTE}T18:00:00.000Z`, endsAt: `${HEUTE}T18:15:00.000Z`, value: 0,
    });
    eintraege = (await ruf("GET", `/entries?from=${VORGESTERN}&to=${HEUTE}`)).json();
    assert.equal(eintraege[0].value, 45);

    // Ohne Sitzungen gibt es auch keinen abgeleiteten Tageswert mehr.
    await ruf("DELETE", `/habits/${habit.id}/events/11111111-1111-1111-1111-111111111111`);
    await ruf("DELETE", `/habits/${habit.id}/events/22222222-2222-2222-2222-222222222222`);
    eintraege = (await ruf("GET", `/entries?from=${VORGESTERN}&to=${HEUTE}`)).json();
    assert.equal(eintraege.length, 0);
  });

  test("Ein Ende vor dem Beginn ist ein Tippfehler, kein Grenzfall", async () => {
    const { ruf } = await neu();
    const habit = await legeHabitAn(ruf, { tracksTime: true });
    const antwort = await ruf("PUT", `/habits/${habit.id}/events/33333333-3333-3333-3333-333333333333`, {
      date: HEUTE, at: `${HEUTE}T09:00:00.000Z`, endsAt: `${HEUTE}T08:00:00.000Z`, value: 1,
    });
    assert.equal(antwort.statusCode, 422);
  });
});

describe("Journal und Ausnahmen", () => {
  test("Der Journaleintrag ist ein Upsert über den Tag", async () => {
    const { ruf } = await neu();
    assert.equal((await ruf("GET", `/days/${HEUTE}`)).statusCode, 404);

    await ruf("PUT", `/days/${HEUTE}`, { mood: 4, energy: 3, sleepHours: 7.5 });
    const zweimal = await ruf("PUT", `/days/${HEUTE}`, { mood: 5 });
    assert.equal(zweimal.json().mood, 5);
    // Kein Teil-Patch: was im Rumpf fehlt, wird geleert. Und geleerte Felder
    // stehen gar nicht erst in der Antwort — dieselbe Regel wie in der
    // Sicherungsdatei, wo ein leeres Optional auch nicht geschrieben wird.
    assert.equal(zweimal.json().energy, undefined);

    assert.equal((await ruf("GET", `/days?from=${VORGESTERN}&to=${HEUTE}`)).json().length, 1);
  });

  test("Ausnahmen anlegen und zurücknehmen", async () => {
    const { ruf } = await neu();
    const angelegt = await ruf("POST", "/exceptions", { date: GESTERN, kind: "paused" });
    assert.equal(angelegt.statusCode, 201);

    assert.equal((await ruf("GET", `/exceptions?from=${VORGESTERN}&to=${HEUTE}`)).json().length, 1);
    await ruf("DELETE", `/exceptions/${angelegt.json().id}`);
    assert.equal((await ruf("GET", `/exceptions?from=${VORGESTERN}&to=${HEUTE}`)).json().length, 0);

    assert.equal((await ruf("POST", "/exceptions", { date: GESTERN, kind: "quatsch" })).statusCode, 422);
  });
});

describe("Papierkorb", () => {
  test("Ein gelöschter Habit nimmt seine Einträge mit — und bringt sie zurück", async () => {
    const { ruf } = await neu();
    const habit = await legeHabitAn(ruf);
    await ruf("PUT", `/habits/${habit.id}/entries/${HEUTE}`, { value: 1 });
    await ruf("PUT", `/habits/${habit.id}/entries/${GESTERN}`, { value: 1 });

    // Einer davon wird vorher einzeln gelöscht: er darf nicht mit
    // zurückkommen, er wurde ja bewusst weggeräumt.
    await ruf("DELETE", `/habits/${habit.id}/entries/${GESTERN}`);
    await ruf("DELETE", `/habits/${habit.id}`);

    const papierkorb = (await ruf("GET", "/trash")).json();
    const habits = papierkorb.filter((p: any) => p.table === "habit");
    const eintraege = papierkorb.filter((p: any) => p.table === "entry");
    assert.equal(habits.length, 1);
    assert.equal(eintraege.length, 1, "nur der einzeln gelöschte, nicht der ganze Verlauf");

    await ruf("POST", "/trash/restore", { table: "habit", rowId: habit.id });
    assert.equal((await ruf("GET", "/habits")).json().length, 1);
    const zurueck = (await ruf("GET", `/entries?from=${VORGESTERN}&to=${HEUTE}`)).json();
    assert.equal(zurueck.length, 1, "der einzeln gelöschte bleibt gelöscht");
    assert.equal(zurueck[0].date, HEUTE);
  });
});

describe("Fokus", () => {
  test("Nur ein offener Lauf gleichzeitig", async () => {
    const { ruf } = await neu();
    await legeHabitAn(ruf);

    const erster = await ruf("POST", "/focus", { days: 7 });
    assert.equal(erster.statusCode, 201);
    assert.equal(erster.json().startsOn, HEUTE, "ein Fokus beginnt immer heute");
    assert.equal(erster.json().endsOn, addDays(HEUTE, 6));

    const zweiter = await ruf("POST", "/focus", { days: 7 });
    assert.equal(zweiter.statusCode, 409, "ein noch heiler Lauf wird nicht still verdrängt");

    // Selbst beendet: danach darf sofort ein neuer beginnen.
    await ruf("POST", `/focus/${erster.json().id}/abandon`);
    assert.equal((await ruf("POST", "/focus", { days: 3 })).statusCode, 201);

    const laeufe = (await ruf("GET", "/focus")).json();
    assert.equal(laeufe.length, 2);
    assert.equal(laeufe.find((l: any) => l.run.id === erster.json().id).outcome.code, "abandoned");
  });

  test("Ein Lauf von null Tagen ist keiner", async () => {
    const { ruf } = await neu();
    assert.equal((await ruf("POST", "/focus", { days: 0 })).statusCode, 422);
  });
});

describe("Freeze-Konto", () => {
  test("Ohne Guthaben lässt sich nichts einfrieren", async () => {
    const { ruf } = await neu();
    const habit = await legeHabitAn(ruf);

    const konto = (await ruf("GET", "/freezes")).json();
    assert.equal(konto.balance, 0);
    assert.equal(konto.maximum, 3);

    const versuch = await ruf("POST", "/freezes/apply", { habitId: habit.id, date: GESTERN });
    assert.equal(versuch.statusCode, 409);
  });

  test("Ein durchgezogener Lauf zahlt ein, und der Freeze rettet einen verpassten Tag", async () => {
    const { db, ruf } = await neu();
    const habit = await legeHabitAn(ruf);

    // Einen abgeschlossenen, durchgezogenen Lauf von Hand einsetzen: er liegt
    // in der Vergangenheit, und dorthin kommt man über die API nicht.
    const start = addDays(HEUTE, -3);
    await db.schreibe(
      `INSERT INTO focus_run (id, user_id, starts_on, ends_on, habit_ids,
                              created_at, updated_at, server_seq)
       VALUES ('f1', 'local', ?, ?, '[]', '2026-01-01T00:00:00.000Z',
               '2026-01-01T00:00:00.000Z', ?)`,
      start, addDays(HEUTE, -2), await db.naechsteSequenz());
    for (const tag of [start, addDays(HEUTE, -2)]) {
      await ruf("PUT", `/habits/${habit.id}/entries/${tag}`, { value: 1 });
    }

    const konto = (await ruf("GET", "/freezes")).json();
    assert.equal(konto.balance, 1, "ein durchgezogener Lauf bringt genau einen");

    // Noch einmal lesen bucht nicht erneut ein — idempotent über focusRunId.
    assert.equal((await ruf("GET", "/freezes")).json().balance, 1);

    // Gestern wurde nichts eingetragen: ein verpasster Tag.
    const eingelöst = await ruf("POST", "/freezes/apply", { habitId: habit.id, date: GESTERN });
    assert.equal(eingelöst.statusCode, 201, eingelöst.body);
    assert.equal(eingelöst.json().kind, "frozen");
    assert.equal((await ruf("GET", "/freezes")).json().balance, 0);

    // Ein erfüllter Tag braucht keine Rettung.
    const unnoetig = await ruf("POST", "/freezes/apply", { habitId: habit.id, date: start });
    assert.equal(unnoetig.statusCode, 409, "Guthaben ist alle — 409 vor 422");
  });
});

describe("Auswertungen", () => {
  test("Die Heute-Ansicht kommt in einem Aufruf", async () => {
    const { ruf } = await neu();
    const a = await legeHabitAn(ruf, { name: "Sport" });
    await legeHabitAn(ruf, { name: "Lesen" });
    await ruf("PUT", `/habits/${a.id}/entries/${HEUTE}`, { value: 1 });

    const summary = (await ruf("GET", `/stats/summary?date=${HEUTE}`)).json();
    assert.equal(summary.date, HEUTE);
    assert.equal(summary.dueCount, 2);
    assert.equal(summary.completedCount, 1);
    const sport = summary.habits.find((h: any) => h.habitId === a.id);
    assert.equal(sport.status, "completed");
    assert.equal(sport.value, 1);
    assert.equal(sport.currentStreak, 1);
    // „stable" und nicht „keine Aussage": die Regel gilt ab dem 1. Januar,
    // also war der Habit an jedem Tag seither fällig. Beide Vergleichszeiträume
    // stehen damit bei 0 %, und das ist kein Unterschied.
    assert.equal(sport.trend, "stable");
  });

  test("Die Übersicht zählt den Nenner nach derselben Regel wie die Mac-App", async () => {
    const { ruf } = await neu();
    const taeglich = await legeHabitAn(ruf, { name: "Sport" });
    await legeHabitAn(ruf, {
      name: "Laufen",
      rules: [{ effectiveFrom: "2026-01-01", schedule: { kind: "timesPerWeek", n: 3 } }],
    });
    await ruf("PUT", `/habits/${taeglich.id}/entries/${GESTERN}`, { value: 1 });

    const uebersicht = (await ruf("GET", `/stats/overview?from=${GESTERN}&to=${GESTERN}`)).json();
    assert.equal(uebersicht.days.length, 1);
    // Der nicht erledigte timesPerWeek-Habit bläht den Nenner nicht auf.
    assert.deepEqual(
      { completed: uebersicht.days[0].completed, scheduled: uebersicht.days[0].scheduled },
      { completed: 1, scheduled: 1 });
    assert.equal(uebersicht.perfectDays, 1);
    assert.equal(uebersicht.busiestDay, 1);
  });

  test("Summen und Streaks je Habit", async () => {
    const { ruf } = await neu();
    const habit = await legeHabitAn(ruf, {
      kind: "quantity",
      rules: [{
        effectiveFrom: "2026-01-01", schedule: { kind: "daily" },
        target: { value: 30, unit: "min", comparison: "atLeast" },
      }],
    });
    await ruf("PUT", `/habits/${habit.id}/entries/${GESTERN}`, { value: 45 });
    await ruf("PUT", `/habits/${habit.id}/entries/${HEUTE}`, { value: 20 });

    const summen = (await ruf("GET", `/habits/${habit.id}/totals?from=${GESTERN}&to=${HEUTE}`)).json();
    assert.equal(summen.total, 65);
    assert.equal(summen.activeDays, 2);

    const auswertung = (await ruf("GET", `/habits/${habit.id}/stats?from=${GESTERN}&to=${HEUTE}`)).json();
    assert.equal(auswertung.streakUnit, "days");
    assert.equal(auswertung.days[GESTERN].code, "completed");
    assert.equal(auswertung.days[HEUTE].code, "partial", "heute ist noch nicht verloren");
  });

  test("Korrelationen schweigen bei dünner Datenbasis", async () => {
    const { ruf } = await neu();
    await legeHabitAn(ruf);
    await ruf("PUT", `/days/${HEUTE}`, { mood: 5 });
    const befunde = (await ruf("GET", `/insights/correlations?from=${VORGESTERN}&to=${HEUTE}`)).json();
    assert.deepEqual(befunde, []);
  });
});

describe("Sicherung", () => {
  test("Ausgeben und wieder einspielen stellt denselben Bestand her", async () => {
    const { ruf } = await neu();
    const habit = await legeHabitAn(ruf, { name: "Sport" });
    const tag = (await ruf("POST", "/tags", { name: "Gesundheit" })).json();
    await ruf("PUT", `/habits/${habit.id}/tags`, [tag.id]);
    await ruf("PUT", `/habits/${habit.id}/entries/${HEUTE}`, { value: 1 });
    await ruf("PUT", `/days/${HEUTE}`, { mood: 4 });

    const datei = JSON.parse((await ruf("GET", "/backup")).body);
    assert.equal(datei.scope, "full");
    assert.equal(datei.habits.length, 1);
    assert.equal(datei.entries.length, 1);
    assert.equal(datei.dayLogs.length, 1);
    assert.deepEqual(datei.habits[0].tagIds, [tag.id]);

    // In eine leere Datenbank einspielen.
    const zweiter = await neu();
    const bericht = await zweiter.ruf("POST", "/backup/import", { mode: "replace", file: datei });
    assert.equal(bericht.statusCode, 200, bericht.body);
    assert.equal(bericht.json().counts.habits.inserted, 1);
    assert.equal(bericht.json().counts.entries.inserted, 1);

    const wieder = JSON.parse((await zweiter.ruf("GET", "/backup")).body);
    assert.deepEqual(wieder.habits[0].rules, datei.habits[0].rules);
    assert.equal(wieder.entries.length, 1);
    assert.equal(wieder.dayLogs[0].mood, 4);
  });

  test("Zweimal dasselbe einspielen ändert beim zweiten Mal nichts", async () => {
    const { ruf } = await neu();
    const habit = await legeHabitAn(ruf);
    await ruf("PUT", `/habits/${habit.id}/entries/${HEUTE}`, { value: 1 });
    const datei = JSON.parse((await ruf("GET", "/backup")).body);

    const zweiter = await neu();
    await zweiter.ruf("POST", "/backup/import", { mode: "merge", file: datei });
    const zweitesMal = await zweiter.ruf("POST", "/backup/import", { mode: "merge", file: datei });
    const counts = zweitesMal.json().counts;
    assert.equal(counts.habits.skipped, 1);
    assert.equal(counts.entries.skipped, 1);
    assert.equal(counts.habits.inserted, 0);
  });

  test("Eine unbrauchbare Datei wird abgewiesen und sagt warum", async () => {
    const { ruf } = await neu();
    const antwort = await ruf("POST", "/backup/import", {
      mode: "merge",
      file: { formatVersion: 99, exportedAt: "2026-01-01T00:00:00.000Z" },
    });
    assert.equal(antwort.statusCode, 422);
    assert.equal(antwort.json().problems[0].code, "unsupportedVersion");
  });

  test("Ersetzen setzt Grabsteine, statt hart zu löschen", async () => {
    const { ruf, delta } = await neu();
    const alt = await legeHabitAn(ruf, { name: "Alt" });
    const datei = JSON.parse((await ruf("GET", "/backup")).body);
    datei.habits = [];
    datei.entries = [];

    await ruf("POST", "/backup/import", { mode: "replace", file: datei });
    assert.equal((await ruf("GET", "/habits")).json().length, 0);

    // Der entscheidende Unterschied zum Client: ein Gerät mit altem Cursor
    // muss von der Löschung erfahren, sonst schiebt es die Zeile zurück.
    const stand = await delta(0);
    const grabstein = stand.habits.find((h: any) => h.id === alt.id);
    assert.ok(grabstein?.deletedAt, "der Habit steht als Grabstein im Delta");
  });
});

describe("Jede Schreibung kommt im Abgleich an", () => {
  /// Der eigentliche Zweck dieser Datei. Ein Endpunkt, der `server_seq` nicht
  /// vergibt, schreibt eine Zeile, die kein Client je zu sehen bekommt — und
  /// das fällt erst auf, wenn jemand die Mac-App abgleichen lässt.
  test("Sequenznummern steigen bei jeder Schreibung", async () => {
    const { ruf, delta } = await neu();
    const stand = async () => (await delta(0)).nextSeq as number;

    let vorher = await stand();
    const schritte: [string, () => Promise<unknown>][] = [];
    const habit = await legeHabitAn(ruf);
    assert.ok(await stand() > vorher, "POST /habits");

    const tag = (await ruf("POST", "/tags", { name: "Gesundheit" })).json();

    schritte.push(
      ["PATCH /habits", () => ruf("PATCH", `/habits/${habit.id}`, { name: "Neu" })],
      ["PUT rules", () => ruf("PUT", `/habits/${habit.id}/rules/2026-07-01`,
                              { schedule: { kind: "daily" } })],
      ["DELETE rules", () => ruf("DELETE", `/habits/${habit.id}/rules/2026-07-01`)],
      ["PUT tags", () => ruf("PUT", `/habits/${habit.id}/tags`, [tag.id])],
      ["PATCH /tags", () => ruf("PATCH", `/tags/${tag.id}`, { name: "Sport" })],
      ["PUT entries", () => ruf("PUT", `/habits/${habit.id}/entries/${HEUTE}`, { value: 1 })],
      ["DELETE entries", () => ruf("DELETE", `/habits/${habit.id}/entries/${HEUTE}`)],
      ["PUT days", () => ruf("PUT", `/days/${HEUTE}`, { mood: 3 })],
      ["POST exceptions", () => ruf("POST", "/exceptions", { date: GESTERN, kind: "skipped" })],
      ["POST focus", () => ruf("POST", "/focus", { days: 5 })],
      ["DELETE tags", () => ruf("DELETE", `/tags/${tag.id}`)],
      ["DELETE habits", () => ruf("DELETE", `/habits/${habit.id}`)],
    );

    for (const [name, schritt] of schritte) {
      vorher = await stand();
      await schritt();
      assert.ok(await stand() > vorher, `${name} hat keine Sequenznummer vergeben`);
    }
  });

  test("Eine kaskadierte Löschung ist ein Vorgang, kein Rieseln", async () => {
    const { ruf, delta } = await neu();
    const habit = await legeHabitAn(ruf);
    await ruf("PUT", `/habits/${habit.id}/entries/${HEUTE}`, { value: 1 });
    await ruf("PUT", `/habits/${habit.id}/entries/${GESTERN}`, { value: 1 });

    const vorher = (await delta(0)).nextSeq as number;
    await ruf("DELETE", `/habits/${habit.id}`);
    const nachher = (await delta(0)).nextSeq as number;
    assert.equal(nachher, vorher + 1, "Habit und Einträge teilen sich eine Nummer");

    // Und alles davon kommt im selben Delta an.
    const stand = await delta(vorher);
    assert.equal(stand.habits.length, 1);
    assert.equal(stand.entries.length, 2);
    assert.ok(stand.entries.every((e: any) => e.deletedAt));
  });
});
