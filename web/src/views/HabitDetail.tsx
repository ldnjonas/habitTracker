/// Ein einzelner Habit: Jahresbild, Wochentage, Zahlen — und was man an einem
/// Tag noch ändern kann.
///
/// Die Farbe ist die des Habits, nicht die der Übersicht: hier geht es um
/// einen, dort um alle zusammen. Und die Stufe kommt nicht aus `intensityLevel`
/// — das ist die Regel für „wie viele von vielen", hier zählt der Status des
/// einen Tages.

import { useState } from "react";
import { api } from "../api/client.ts";
import type {
  CalendarDate, DayException, DayStatus, EntryEvent, Habit, HabitStats, PeriodTotal,
} from "../api/types.ts";
import { addDays, through } from "../../../server/src/domain/calendar.ts";
import { Heatmap, type Tag } from "../ui/Heatmap.tsx";
import { Blatt, Karte, Zeile } from "../ui/Blatt.tsx";
import { schreibe, useLaden } from "../ui/laden.ts";
import { langesDatum, langerWochentag, planText, zahl, STATUS_TEXT } from "../ui/text.ts";
import { zeichenFuer } from "../ui/symbole.ts";

/// Wie kräftig ein Tag leuchtet — dieselbe Abstufung wie `DayStatus.intensity`
/// in `HabitUI/Support.swift`. Ein Freeze bleibt sichtbar, aber blass: er hat
/// den Streak gehalten und den Tag nicht erledigt.
function deckkraft(status: DayStatus | undefined): number {
  if (!status) return 0;
  switch (status.code) {
    case "completed": return 1;
    case "partial": return Math.max(0.15, status.progress);
    case "frozen": return 0.3;
    default: return 0;
  }
}

const WOCHENTAGE = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"];

export function HabitDetail({
  habit, heute, schliessen, bearbeiten, abgemeldet,
}: {
  habit: Habit;
  heute: CalendarDate;
  schliessen: () => void;
  bearbeiten: () => void;
  abgemeldet: () => void;
}) {
  const [tagDetail, setzeTagDetail] = useState<CalendarDate | null>(null);

  // 53 volle Wochen, damit die sieben Zeilen aufgehen — derselbe Ausschnitt
  // wie im Jahr der Übersicht.
  const bis = heute;
  const von = addDays(bis, -370);

  const { daten, fehler, neuLaden } = useLaden(async () => {
    const [auswertung, summen, ausnahmen, events] = await Promise.all([
      api.hole<HabitStats>(`/habits/${habit.id}/stats?from=${von}&to=${bis}`),
      api.hole<PeriodTotal>(`/habits/${habit.id}/totals?from=${von}&to=${bis}`),
      api.hole<DayException[]>(`/exceptions?from=${von}&to=${bis}`),
      habit.tracksTime
        ? api.hole<EntryEvent[]>(`/habits/${habit.id}/events?from=${addDays(bis, -30)}&to=${bis}`)
        : Promise.resolve([] as EntryEvent[]),
    ]);
    return { auswertung, summen, ausnahmen, events };
  }, [habit.id, von, bis], abgemeldet);

  const regel = gueltigeRegel(habit, heute);

  return (
    <Blatt titel={habit.name} schliessen={schliessen}
           aktion={<button onClick={bearbeiten}>Bearbeiten</button>}>
      <div className="detail-kopf">
        <span className="marke gross"
              style={{ background: `${habit.colorHex}22`, color: habit.colorHex }}>
          {zeichenFuer(habit.symbol, habit.name)}
        </span>
        <div>
          <strong>{regel ? planText(regel.schedule) : "Ohne Zeitplan"}</strong>
          {habit.notes && <p className="hinweis klein">{habit.notes}</p>}
          {habit.archivedOn && <p className="hinweis klein">Archiviert am {langesDatum(habit.archivedOn)}</p>}
        </div>
      </div>

      {fehler && <div className="fehler">{fehler}</div>}
      {!daten ? <div className="laedt">Wird geladen …</div> : (
        <>
          <div className="kacheln">
            <Kachel titel="Aktuell" wert={String(daten.auswertung.currentStreak)}
                    unten={daten.auswertung.streakUnit === "weeks" ? "Wochen" : "Tage"} />
            <Kachel titel="Längste" wert={String(daten.auswertung.longestStreak)}
                    unten={daten.auswertung.streakUnit === "weeks" ? "Wochen" : "Tage"} />
            <Kachel titel="Quote"
                    wert={daten.auswertung.completionRate == null
                      ? "—"
                      : `${Math.round(daten.auswertung.completionRate * 100)} %`}
                    unten={`${daten.auswertung.completedCount} von ${daten.auswertung.evaluatedCount}`} />
          </div>

          <Karte titel="Letzte zwölf Monate">
            <Heatmap
              ausschnitt="year"
              farbe={habit.colorHex}
              ausgewaehlt={tagDetail}
              waehle={(t) => setzeTagDetail(t.date)}
              tage={through(von, bis).map((datum): Tag => ({
                date: datum,
                summary: null,
                level: 0,
                deckkraft: deckkraft(daten.auswertung.days[datum]),
              }))}
            />
          </Karte>

          <Karte titel="Nach Wochentag">
            <div className="wochenbalken">
              {WOCHENTAGE.map((name, i) => {
                const anteil = daten.auswertung.weekdayBreakdown[(i + 1) as 1];
                return (
                  <div className="wochenbalken-spalte" key={name}>
                    <div className="wochenbalken-schaft" title={anteil == null ? "keine Daten" : `${Math.round(anteil * 100)} %`}>
                      <span style={{
                        height: `${Math.round((anteil ?? 0) * 100)}%`,
                        background: habit.colorHex,
                      }} />
                    </div>
                    <span className="wochenbalken-name">{name}</span>
                    <span className="wochenbalken-wert">
                      {anteil == null ? "—" : `${Math.round(anteil * 100)}`}
                    </span>
                  </div>
                );
              })}
            </div>
            <p className="hinweis klein">
              Anteil erledigter an geplanten Tagen. Fehlt ein Wochentag, gab es dafür keine
              Datengrundlage.
            </p>
          </Karte>

          <Karte titel="Summe der letzten zwölf Monate">
            <Zeile label="Gesamt" wert={zahl(daten.summen.total)} />
            <Zeile label="Tage mit Aktivität" wert={daten.summen.activeDays} />
            <Zeile label="Schnitt je aktivem Tag"
                   wert={daten.summen.activeDays > 0
                     ? zahl(daten.summen.total / daten.summen.activeDays)
                     : "—"} />
          </Karte>

          {habit.tracksTime && (
            <Karte titel="Sitzungen der letzten 30 Tage">
              {daten.events.length === 0
                ? <p className="hinweis klein">Noch keine Sitzungen eingetragen.</p>
                : daten.events.slice().reverse().slice(0, 20).map((event) => (
                    <Zeile key={event.id}
                           label={`${langesDatum(event.date)} · ${uhrzeit(event.at)}${event.endsAt ? `–${uhrzeit(event.endsAt)}` : ""}`}
                           wert={`${zahl(event.value)} min`} />
                  ))}
            </Karte>
          )}
        </>
      )}

      {tagDetail && daten && (
        <TagAktionen
          habit={habit}
          datum={tagDetail}
          heute={heute}
          status={daten.auswertung.days[tagDetail]}
          ausnahme={daten.ausnahmen.find(
            (a) => a.date === tagDetail && (a.habitId === habit.id || a.habitId == null)) ?? null}
          schliessen={() => setzeTagDetail(null)}
          geaendert={neuLaden}
          abgemeldet={abgemeldet}
        />
      )}
    </Blatt>
  );
}

function Kachel({ titel, wert, unten }: { titel: string; wert: string; unten: string }) {
  return (
    <div className="kachel">
      <span className="kachel-titel">{titel}</span>
      <strong className="kachel-wert">{wert}</strong>
      <span className="kachel-unten">{unten}</span>
    </div>
  );
}

function uhrzeit(zeitpunkt: string): string {
  const d = new Date(zeitpunkt);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
}

export function gueltigeRegel(habit: Habit, datum: CalendarDate) {
  let ergebnis = null;
  for (const regel of habit.rules) if (regel.effectiveFrom <= datum) ergebnis = regel;
  return ergebnis;
}

// MARK: - Was an einem Tag noch geht

/// Ausnahmen setzen und aufheben, und einen verpassten Tag einfrieren.
///
/// Die Regeln stehen im Server und werden hier nicht wiederholt: er sagt mit
/// 409 „kein Guthaben" und mit 422 „dieser Tag lässt sich nicht einfrieren".
/// Diese Ansicht zeigt die Knöpfe und die Antwort.
function TagAktionen({
  habit, datum, heute, status, ausnahme, schliessen, geaendert, abgemeldet,
}: {
  habit: Habit;
  datum: CalendarDate;
  heute: CalendarDate;
  status: DayStatus | undefined;
  ausnahme: DayException | null;
  schliessen: () => void;
  geaendert: () => Promise<void>;
  abgemeldet: () => void;
}) {
  const [meldung, setzeMeldung] = useState<string | null>(null);
  const [laeuft, setzeLaeuft] = useState(false);

  async function tun(arbeit: () => Promise<unknown>) {
    setzeLaeuft(true);
    await schreibe(arbeit, geaendert, setzeMeldung, abgemeldet);
    setzeLaeuft(false);
  }

  return (
    <Blatt titel={langerWochentag(datum)} schliessen={schliessen}>
      <p className="hinweis klein">{langesDatum(datum)} · {habit.name}</p>

      <Karte>
        <Zeile label="Status" wert={status ? STATUS_TEXT[status.code] ?? status.code : "—"} />
        {ausnahme && (
          <Zeile label="Ausnahme"
                 wert={ausnahme.habitId ? "nur dieser Habit" : "alle Habits"} />
        )}
      </Karte>

      {meldung && <div className="fehler">{meldung}</div>}

      <Karte titel="Ändern">
        {ausnahme ? (
          <button className="breit" disabled={laeuft}
                  onClick={() => tun(() => api.loesche(`/exceptions/${ausnahme.id}`))}>
            Ausnahme aufheben
          </button>
        ) : (
          <>
            <button className="breit" disabled={laeuft}
                    onClick={() => tun(() => api.sende("/exceptions", {
                      habitId: habit.id, date: datum, kind: "paused", reason: "Urlaub",
                    }))}>
              Urlaub — der Tag fällt ganz aus der Statistik
            </button>
            <button className="breit" disabled={laeuft}
                    onClick={() => tun(() => api.sende("/exceptions", {
                      habitId: habit.id, date: datum, kind: "skipped", reason: "Ruhetag",
                    }))}>
              Ruhetag — bewusst ausgelassen
            </button>
            {status?.code === "missed" && datum < heute && (
              <button className="breit" disabled={laeuft}
                      onClick={() => tun(() => api.sende("/freezes/apply", {
                        habitId: habit.id, date: datum,
                      }))}>
                Freeze einlösen — rettet den Streak, nicht die Quote
              </button>
            )}
          </>
        )}
      </Karte>

      <p className="hinweis klein">
        Ein Freeze überbrückt einen verpassten Tag, verlängert den Streak aber nicht — sonst
        ließe sich Streak kaufen. Urlaub und Ruhetag nehmen den Tag ganz aus dem Nenner.
      </p>
    </Blatt>
  );
}
