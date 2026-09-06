/// Die gesammelte Heatmap über alle Habits.
///
/// Der Ausschnitt und das Blättern kommen aus derselben Domäne wie auf dem Mac
/// (`spanRange`, `spanShift`) — Woche und Monat rasten am Kalender ein, das Jahr
/// sind 53 volle Wochen. Nachgebaut wäre das dieselbe Rechnung ein zweites Mal,
/// und die zweite wäre irgendwann die falsche.

import { useState } from "react";
import { api } from "../api/client.ts";
import type {
  CalendarDate, DayException, Habit, IntensityScale, UebersichtsAntwort,
} from "../api/types.ts";
import { intensityLevel, spanRange, spanShift } from "../../../server/src/domain/overview.ts";
import { AUSNAHME_TEXT, Heatmap, Legende, type Ausschnitt, type Tag } from "../ui/Heatmap.tsx";
import { Blatt, Karte, Zeile } from "../ui/Blatt.tsx";
import { useLaden } from "../ui/laden.ts";
import { kurzesDatum, langesDatum, langerWochentag, monatJahr, STATUS_TEXT } from "../ui/text.ts";
import { zeichenFuer } from "../ui/symbole.ts";

const AUSSCHNITTE: { wert: Ausschnitt; titel: string }[] = [
  { wert: "week", titel: "Woche" },
  { wert: "month", titel: "Monat" },
  { wert: "year", titel: "Jahr" },
];

/// Die beiden Maßstäbe beantworten verschiedene Fragen und sind beide sinnvoll:
/// **Anzahl** zeigt Betriebsamkeit (ein Sonntag mit einem Habit bleibt blass),
/// **Anteil** zeigt Verlässlichkeit (derselbe Sonntag leuchtet, wenn dieser eine
/// Habit erledigt wurde).
const MASSSTAEBE: { wert: IntensityScale; titel: string; erklaerung: string }[] = [
  { wert: "count", titel: "Anzahl",
    erklaerung: "Je mehr Habits an einem Tag erledigt wurden, desto kräftiger die Farbe." },
  { wert: "share", titel: "Anteil",
    erklaerung: "Je größer der erledigte Anteil des Tagespensums, desto kräftiger die Farbe." },
];

export function Uebersicht({
  heute, abgemeldet,
}: {
  heute: CalendarDate;
  abgemeldet: () => void;
}) {
  const [ausschnitt, setzeAusschnitt] = useState<Ausschnitt>("month");
  const [anker, setzeAnker] = useState<CalendarDate>(heute);
  const [massstab, setzeMassstab] = useState<IntensityScale>("count");
  const [tagDetail, setzeTagDetail] = useState<CalendarDate | null>(null);

  const bereich = spanRange(ausschnitt, anker);

  const { daten, fehler, laedt } = useLaden(async () => {
    const [uebersicht, ausnahmen, habits] = await Promise.all([
      api.hole<UebersichtsAntwort>(`/stats/overview?from=${bereich.from}&to=${bereich.to}`),
      api.hole<DayException[]>(`/exceptions?from=${bereich.from}&to=${bereich.to}`),
      api.hole<Habit[]>("/habits?includeArchived=true"),
    ]);
    return { uebersicht, ausnahmen, habits };
  }, [bereich.from, bereich.to], abgemeldet);

  if (fehler) return <div className="fehler">{fehler}</div>;
  if (!daten) return <div className="laedt">Wird geladen …</div>;

  const { uebersicht, ausnahmen } = daten;
  // Eine globale Ausnahme gilt für alle; eine für einen einzelnen Habit sagt
  // über den Tag als Ganzes wenig, deshalb färbt sie die Kachel nicht.
  const global = new Map(
    ausnahmen.filter((a) => a.habitId == null).map((a) => [a.date as string, a.kind]));

  const tage: Tag[] = uebersicht.days.map((summary) => ({
    date: summary.date,
    summary,
    level: intensityLevel(summary, massstab, uebersicht.busiestDay),
    ausnahme: global.get(summary.date) ?? null,
  }));

  return (
    <>
      <header className="kopf">
        <h1>Übersicht</h1>
        <div className="zeile">
          <span className="zahl">{titel(ausschnitt, bereich)}</span>
          <span className="blaettern">
            <button onClick={() => setzeAnker(spanShift(ausschnitt, anker, -1))}
                    aria-label="zurück">‹</button>
            <button onClick={() => setzeAnker(heute)} disabled={anker === heute}>Heute</button>
            <button onClick={() => setzeAnker(spanShift(ausschnitt, anker, 1))}
                    aria-label="vor">›</button>
          </span>
        </div>
      </header>

      <div className="segmente" role="tablist" aria-label="Ausschnitt">
        {AUSSCHNITTE.map((a) => (
          <button key={a.wert} role="tab" aria-selected={ausschnitt === a.wert}
                  onClick={() => setzeAusschnitt(a.wert)}>{a.titel}</button>
        ))}
      </div>

      <Karte>
        <Heatmap ausschnitt={ausschnitt} tage={tage}
                 ausgewaehlt={tagDetail} waehle={(t) => setzeTagDetail(t.date)} />
        <Legende />
        {laedt && <div className="laedt-leise">lädt …</div>}
      </Karte>

      <div className="segmente klein" role="tablist" aria-label="Maßstab">
        {MASSSTAEBE.map((m) => (
          <button key={m.wert} role="tab" aria-selected={massstab === m.wert}
                  onClick={() => setzeMassstab(m.wert)}>{m.titel}</button>
        ))}
      </div>
      <p className="hinweis klein">
        {MASSSTAEBE.find((m) => m.wert === massstab)!.erklaerung}
      </p>

      <Karte titel="Im Zeitraum">
        <Zeile label="Perfekte Tage" wert={uebersicht.perfectDays} />
        <Zeile label="Tage mit Plan" wert={uebersicht.daysWithPlan} />
        <Zeile label="Erledigungen" wert={uebersicht.totalCompletions} />
        <Zeile label="Serie perfekter Tage" wert={uebersicht.perfectStreak} />
      </Karte>

      {tagDetail && (
        <TagDetail datum={tagDetail} heute={heute}
                   schliessen={() => setzeTagDetail(null)} abgemeldet={abgemeldet} />
      )}
    </>
  );
}

function titel(ausschnitt: Ausschnitt, bereich: { from: CalendarDate; to: CalendarDate }): string {
  if (ausschnitt === "week") return `${kurzesDatum(bereich.from)} – ${kurzesDatum(bereich.to)}`;
  if (ausschnitt === "month") return langesDatum(bereich.from).replace(/^\d+\. /, "");
  return `${monatJahr(bereich.from)} – ${monatJahr(bereich.to)}`;
}

// MARK: - Ein einzelner Tag

function TagDetail({
  datum, heute, schliessen, abgemeldet,
}: {
  datum: CalendarDate;
  heute: CalendarDate;
  schliessen: () => void;
  abgemeldet: () => void;
}) {
  const { daten, fehler } = useLaden(async () => {
    const [summary, habits, ausnahmen] = await Promise.all([
      api.hole<{ habits: { habitId: string; status: string; value: number }[] }>(
        `/stats/summary?date=${datum}`),
      api.hole<Habit[]>("/habits?includeArchived=true"),
      api.hole<DayException[]>(`/exceptions?from=${datum}&to=${datum}`),
    ]);
    return { summary, habits: new Map(habits.map((h) => [h.id, h])), ausnahmen };
  }, [datum], abgemeldet);

  return (
    <Blatt titel={langerWochentag(datum)} schliessen={schliessen}>
      <p className="hinweis klein">{langesDatum(datum)}</p>
      {fehler && <div className="fehler">{fehler}</div>}
      {!daten ? <div className="laedt">Wird geladen …</div> : (
        <>
          {daten.ausnahmen.length > 0 && (
            <Karte titel="Ausnahmen">
              {daten.ausnahmen.map((a) => (
                <Zeile key={a.id}
                       label={a.habitId ? daten.habits.get(a.habitId)?.name ?? "Habit" : "Alle Habits"}
                       wert={AUSNAHME_TEXT[a.kind] ?? a.kind} />
              ))}
            </Karte>
          )}

          {datum > heute ? (
            <p className="hinweis">Dieser Tag liegt noch vor uns.</p>
          ) : daten.summary.habits.length === 0 ? (
            <p className="hinweis">An diesem Tag war nichts geplant.</p>
          ) : (
            <div className="liste">
              {daten.summary.habits.map((eintrag) => {
                const habit = daten.habits.get(eintrag.habitId);
                if (!habit) return null;
                return (
                  <div className="zeile" key={eintrag.habitId}>
                    <span className="marke"
                          style={{ background: `${habit.colorHex}22`, color: habit.colorHex }}>
                      {zeichenFuer(habit.symbol, habit.name)}
                    </span>
                    <span className="mitte">
                      <span className="name">{habit.name}</span>
                      <span className="unter">{STATUS_TEXT[eintrag.status] ?? eintrag.status}</span>
                    </span>
                    {eintrag.value > 0 && <span className="zahl">{eintrag.value}</span>}
                  </div>
                );
              })}
            </div>
          )}
        </>
      )}
    </Blatt>
  );
}
