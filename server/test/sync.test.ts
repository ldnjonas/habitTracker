import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { Db } from "../src/db.ts";
import { leseDelta, schreibeDelta } from "../src/sync.ts";
import { baueServer } from "../src/index.ts";

const TOKEN = "t".repeat(32);

function habit(werte: Record<string, unknown> = {}) {
  return {
    id: "h1", userId: "local", name: "Sport", kind: "binary",
    colorHex: "#FF9500", symbol: "figure.run", sortOrder: 0, tracksTime: false,
    createdAt: "2026-09-01T08:00:00.000Z", updatedAt: "2026-09-01T08:00:00.000Z",
    rules: [{ effectiveFrom: "2026-09-01", schedule: { kind: "daily" } }],
    tagIds: [],
    ...werte,
  };
}

function eintrag(werte: Record<string, unknown> = {}) {
  return {
    id: "e1", userId: "local", habitId: "h1", date: "2026-09-03", value: 1,
    source: "manual",
    createdAt: "2026-09-03T08:00:00.000Z", updatedAt: "2026-09-03T08:00:00.000Z",
    ...werte,
  };
}

describe("Delta lesen und schreiben", () => {
  /// Der Fehler, den erst ein Lauf mit dem echten Client zeigte: `Entry` trägt
  /// in Swift gar kein `userId`, die Zuordnung steht nur in der Datenbankzeile.
  test("Der Server setzt die Zugehörigkeit selbst", () => {
    const db = new Db();
    schreibeDelta(db, { habits: [habit()] });
    // Ohne userId — so wie der Swift-Client es schickt.
    const ohne = { id: "e1", habitId: "h1", date: "2026-09-03", value: 1, source: "manual",
                   createdAt: "2026-09-03T08:00:00.000Z", updatedAt: "2026-09-03T08:00:00.000Z" };
    assert.equal(schreibeDelta(db, { entries: [ohne] }).angenommen, 1);
    assert.equal((leseDelta(db, 0).entries[0] as any).userId, "local");

    // Und eine fremde Angabe wird überschrieben, nicht übernommen.
    schreibeDelta(db, { entries: [{ ...ohne, userId: "jemand-anders",
                                    updatedAt: "2026-09-03T09:00:00.000Z" }] });
    assert.equal((leseDelta(db, 0).entries[0] as any).userId, "local");
    db.schliesse();
  });

  test("Ein Habit überlebt den Rundlauf samt Regeln und Tags", () => {
    const db = new Db();
    schreibeDelta(db, { tags: [{
      id: "t1", userId: "local", name: "Gesundheit", colorHex: "#34C759", sortOrder: 0,
      createdAt: "2026-09-01T08:00:00.000Z", updatedAt: "2026-09-01T08:00:00.000Z" }] });
    schreibeDelta(db, { habits: [habit({
      tagIds: ["t1"],
      rules: [{ effectiveFrom: "2026-09-01", schedule: { kind: "weekdays", days: [1, 3, 5] },
                target: { value: 30, unit: "min", comparison: "atLeast" } }],
    })] });

    const delta = leseDelta(db, 0);
    const gelesen = delta.habits[0] as Record<string, any>;
    assert.equal(gelesen.name, "Sport");
    assert.deepEqual(gelesen.tagIds, ["t1"]);
    assert.equal(gelesen.rules.length, 1);
    assert.deepEqual(gelesen.rules[0].schedule, { kind: "weekdays", days: [1, 3, 5] });
    assert.deepEqual(gelesen.rules[0].target, { value: 30, unit: "min", comparison: "atLeast" });
    db.schliesse();
  });

  test("Der Cursor liefert nur Neues", () => {
    const db = new Db();
    schreibeDelta(db, { habits: [habit()] });
    const erstes = leseDelta(db, 0);
    assert.equal(erstes.habits.length, 1);

    // Nichts Neues seit dem Cursor.
    assert.equal(leseDelta(db, erstes.nextSeq!).habits.length, 0);

    schreibeDelta(db, { entries: [eintrag()] });
    const zweites = leseDelta(db, erstes.nextSeq!);
    assert.equal(zweites.habits.length, 0, "der Habit ist schon bekannt");
    assert.equal(zweites.entries.length, 1);
    db.schliesse();
  });

  /// Ohne Grabsteine käme eine Löschung nie beim anderen Gerät an.
  test("Grabsteine werden mitgeliefert", () => {
    const db = new Db();
    schreibeDelta(db, { entries: [eintrag()] });
    const cursor = leseDelta(db, 0).nextSeq!;

    schreibeDelta(db, { entries: [eintrag({
      updatedAt: "2026-09-03T09:00:00.000Z", deletedAt: "2026-09-03T09:00:00.000Z" })] });

    const delta = leseDelta(db, cursor);
    assert.equal(delta.entries.length, 1);
    assert.equal((delta.entries[0] as any).deletedAt, "2026-09-03T09:00:00.000Z");
    db.schliesse();
  });

  test("Die neuere Fassung gewinnt, die ältere wird verworfen", () => {
    const db = new Db();
    schreibeDelta(db, { entries: [eintrag({ value: 1, updatedAt: "2026-09-03T10:00:00.000Z" })] });

    const alt = schreibeDelta(db, {
      entries: [eintrag({ value: 99, updatedAt: "2026-09-03T09:00:00.000Z" })] });
    assert.equal(alt.verworfen, 1);
    assert.equal((leseDelta(db, 0).entries[0] as any).value, 1);

    const neu = schreibeDelta(db, {
      entries: [eintrag({ value: 42, updatedAt: "2026-09-03T11:00:00.000Z" })] });
    assert.equal(neu.angenommen, 1);
    assert.equal((leseDelta(db, 0).entries[0] as any).value, 42);
    db.schliesse();
  });

  /// Ein Gerät mit falsch gestellter Uhr gewänne sonst dauerhaft jeden Konflikt.
  test("Eine Uhr aus der Zukunft wird gestutzt", () => {
    const db = new Db();
    const jetzt = new Date("2026-09-05T12:00:00.000Z");
    schreibeDelta(db, { entries: [eintrag({
      value: 7, updatedAt: "2027-01-01T00:00:00.000Z" })] }, jetzt);

    const gespeichert = (leseDelta(db, 0).entries[0] as any).updatedAt;
    assert.equal(gespeichert, jetzt.toISOString(), "auf die Serverzeit zurückgesetzt");

    // Und genau deshalb kann eine spätere, ehrliche Änderung noch gewinnen.
    const spaeter = schreibeDelta(db, { entries: [eintrag({
      value: 8, updatedAt: "2026-09-05T13:00:00.000Z" })] },
      new Date("2026-09-05T13:00:00.000Z"));
    assert.equal(spaeter.angenommen, 1);
    db.schliesse();
  });

  test("Eine Freeze-Buchung wird angelegt, aber nie geändert", () => {
    const db = new Db();
    const buchung = {
      id: "f1", userId: "local", amount: 1, reason: "focusCompleted",
      focusRunId: "r1", createdAt: "2026-09-01T08:00:00.000Z",
    };
    assert.equal(schreibeDelta(db, { freezes: [buchung] }).angenommen, 1);
    // Ein zweites Mal ändert nichts — eine Korrektur wäre eine Gegenbuchung.
    assert.equal(schreibeDelta(db, { freezes: [{ ...buchung, amount: 99 }] }).verworfen, 1);
    assert.equal((leseDelta(db, 0).freezes[0] as any).amount, 1);
    db.schliesse();
  });

  test("Ein Journaltag wird über (userId, date) erkannt", () => {
    const db = new Db();
    const log = { userId: "local", date: "2026-09-03", mood: 3,
                  createdAt: "2026-09-03T08:00:00.000Z", updatedAt: "2026-09-03T08:00:00.000Z" };
    schreibeDelta(db, { dayLogs: [log] });
    schreibeDelta(db, { dayLogs: [{ ...log, mood: 5, updatedAt: "2026-09-03T09:00:00.000Z" }] });

    const gelesen = leseDelta(db, 0).dayLogs;
    assert.equal(gelesen.length, 1, "kein zweiter Tag");
    assert.equal((gelesen[0] as any).mood, 5);
    db.schliesse();
  });

  test("Regeln werden mit dem Habit als Einheit ersetzt", () => {
    const db = new Db();
    schreibeDelta(db, { habits: [habit()] });
    schreibeDelta(db, { habits: [habit({
      updatedAt: "2026-09-02T08:00:00.000Z",
      rules: [{ effectiveFrom: "2026-09-01", schedule: { kind: "daily" } },
              { effectiveFrom: "2026-09-02", schedule: { kind: "timesPerWeek", n: 3 } }],
    })] });

    const regeln = (leseDelta(db, 0).habits[0] as any).rules;
    assert.equal(regeln.length, 2);
    assert.deepEqual(regeln[1].schedule, { kind: "timesPerWeek", n: 3 });
    db.schliesse();
  });

  test("Bei zu vielen Zeilen wird abgeschnitten und das gesagt", () => {
    const db = new Db();
    for (let i = 0; i < 10; i++) {
      schreibeDelta(db, { entries: [eintrag({ id: `e${i}`, date: `2026-09-${10 + i}` })] });
    }
    const delta = leseDelta(db, 0, 4);
    assert.equal(delta.hasMore, true);
    assert.equal(delta.nextSeq, 4);
    // Weiterlesen ab dem gemeldeten Cursor holt den Rest.
    const rest = leseDelta(db, delta.nextSeq!, 100);
    assert.equal(rest.hasMore, false);
    assert.equal(rest.entries.length, 6);
    db.schliesse();
  });

  test("Ein fehlgeschlagenes Delta hinterlässt nichts", () => {
    const db = new Db();
    schreibeDelta(db, { habits: [habit()] });
    const vorher = db.aktuelleSequenz();

    // Der zweite Eintrag verletzt die Eindeutigkeit von (habit_id, date).
    assert.throws(() => schreibeDelta(db, { entries: [
      eintrag({ id: "e1" }),
      eintrag({ id: "e2" }),
    ]}));

    assert.equal(db.aktuelleSequenz(), vorher, "die Folge ist nicht weitergelaufen");
    assert.equal(leseDelta(db, 0).entries.length, 0, "auch der erste ist zurückgerollt");
    db.schliesse();
  });
});

describe("Über HTTP", () => {
  test("Ohne Token kommt man nicht durch, mit schon", async () => {
    const db = new Db();
    const app = baueServer(db, TOKEN);
    const kopf = { authorization: `Bearer ${TOKEN}` };

    assert.equal((await app.inject({ method: "GET", url: "/sync" })).statusCode, 401);
    assert.equal((await app.inject({
      method: "GET", url: "/sync", headers: { authorization: "Bearer falsch" },
    })).statusCode, 401);

    const hoch = await app.inject({
      method: "POST", url: "/sync", headers: kopf, payload: { habits: [habit()] } });
    assert.equal(hoch.statusCode, 200);
    assert.equal(hoch.json().angenommen, 1);
    assert.equal(hoch.json().habits, undefined, "nur der Bericht, kein Delta");

    // Die autoritative Fassung kommt beim nächsten Abholen — die Zeile liegt
    // jetzt über dem Cursor des Clients.
    const runter = await app.inject({ method: "GET", url: "/sync?since=0", headers: kopf });
    assert.equal(runter.json().habits.length, 1);
    await app.close();
    db.schliesse();
  });

  test("Die Gesundheitsprüfung braucht kein Token", async () => {
    const db = new Db();
    const app = baueServer(db, TOKEN);
    const antwort = await app.inject({ method: "GET", url: "/health" });
    assert.equal(antwort.statusCode, 200);
    assert.equal(antwort.json().ok, true);
    await app.close();
    db.schliesse();
  });
});
