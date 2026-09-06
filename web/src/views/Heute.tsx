/// Die Ansicht, die täglich benutzt wird — deshalb steht hier nur, was heute zählt.
///
/// Ein Aufruf für alles (`GET /stats/summary`), dann je Antippen ein
/// `PUT /habits/{id}/entries/{date}`. Auf dem Telefon ist jede Runde über das
/// Netz spürbar, deshalb wird die Zeile sofort umgestellt und erst danach
/// nachgeladen — und beim Fehlschlag wieder zurückgesetzt.

import { useCallback, useEffect, useState } from "react";
import { ApiFehler, api } from "../api/client.ts";
import type { CalendarDate, Habit, TagesUebersicht } from "../api/types.ts";
import { langerWochentag, langesDatum, planText, zahl } from "../ui/text.ts";
import { zeichenFuer } from "../ui/symbole.ts";

type Stand = {
  uebersicht: TagesUebersicht;
  habits: Map<string, Habit>;
};

/// Grober Tagesabschnitt — dieselbe Gruppierung wie in der Mac-App.
const ABSCHNITTE: { schluessel: string | null; titel: string }[] = [
  { schluessel: "morning", titel: "Morgens" },
  { schluessel: "afternoon", titel: "Mittags" },
  { schluessel: "evening", titel: "Abends" },
  { schluessel: "night", titel: "Nachts" },
  { schluessel: null, titel: "Ohne feste Zeit" },
];

export function Heute({ abgemeldet }: { abgemeldet: () => void }) {
  const [stand, setzeStand] = useState<Stand | null>(null);
  const [fehler, setzeFehler] = useState<string | null>(null);
  const [beschaeftigt, setzeBeschaeftigt] = useState<Set<string>>(new Set());

  const laden = useCallback(async () => {
    try {
      const [uebersicht, habits] = await Promise.all([
        api.hole<TagesUebersicht>("/stats/summary"),
        api.hole<Habit[]>("/habits"),
      ]);
      setzeStand({ uebersicht, habits: new Map(habits.map((h) => [h.id, h])) });
      setzeFehler(null);
    } catch (f) {
      if (f instanceof ApiFehler && f.status === 401) return abgemeldet();
      setzeFehler(f instanceof Error ? f.message : "Unbekannter Fehler");
    }
  }, [abgemeldet]);

  useEffect(() => { void laden(); }, [laden]);

  async function setzeWert(habitId: string, datum: CalendarDate, wert: number) {
    setzeBeschaeftigt((alt) => new Set(alt).add(habitId));
    try {
      await api.setze(`/habits/${habitId}/entries/${datum}`, { value: Math.max(0, wert) });
      await laden();
    } catch (f) {
      if (f instanceof ApiFehler && f.status === 401) return abgemeldet();
      setzeFehler(f instanceof Error ? f.message : "Unbekannter Fehler");
    } finally {
      setzeBeschaeftigt((alt) => {
        const neu = new Set(alt);
        neu.delete(habitId);
        return neu;
      });
    }
  }

  if (fehler && !stand) return <div className="fehler">{fehler}</div>;
  if (!stand) return <div className="laedt">Wird geladen …</div>;

  const { uebersicht, habits } = stand;
  const anteil = uebersicht.dueCount === 0
    ? 0
    : uebersicht.completedCount / uebersicht.dueCount;

  const gruppen = ABSCHNITTE
    .map(({ schluessel, titel }) => ({
      titel,
      eintraege: uebersicht.habits.filter(
        (h) => (habits.get(h.habitId)?.timeOfDay ?? null) === schluessel),
    }))
    .filter((g) => g.eintraege.length > 0);
  // Ohne Tageszeit ist die einzige Gruppe? Dann steht dort sinnlos „Ohne feste
  // Zeit" — dieselbe Regel wie auf dem Mac.
  const ohneUeberschrift = gruppen.length === 1;

  return (
    <>
      <header className="kopf">
        <h1>{langerWochentag(uebersicht.date)}</h1>
        <div className="zeile">
          <span className="zahl">{langesDatum(uebersicht.date)}</span>
          <span className="zahl">
            {uebersicht.completedCount} von {uebersicht.dueCount}
          </span>
        </div>
        <div className={anteil >= 1 ? "balken voll" : "balken"}>
          <span style={{ width: `${Math.round(anteil * 100)}%` }} />
        </div>
      </header>

      {fehler && <div className="fehler">{fehler}</div>}

      {uebersicht.habits.length === 0 && (
        <p className="hinweis">Für heute ist nichts geplant.</p>
      )}

      {gruppen.map((gruppe) => (
        <section className="gruppe" key={gruppe.titel}>
          {!ohneUeberschrift && <h2>{gruppe.titel}</h2>}
          <div className="liste">
            {gruppe.eintraege.map((eintrag) => {
              const habit = habits.get(eintrag.habitId);
              if (!habit) return null;
              return (
                <HabitZeile
                  key={eintrag.habitId}
                  habit={habit}
                  eintrag={eintrag}
                  datum={uebersicht.date}
                  laeuft={beschaeftigt.has(eintrag.habitId)}
                  aendern={setzeWert}
                />
              );
            })}
          </div>
        </section>
      ))}
    </>
  );
}

function HabitZeile({
  habit, eintrag, datum, laeuft, aendern,
}: {
  habit: Habit;
  eintrag: TagesUebersicht["habits"][number];
  datum: CalendarDate;
  laeuft: boolean;
  aendern: (habitId: string, datum: CalendarDate, wert: number) => void;
}) {
  const regel = gueltigeRegel(habit, datum);
  const ziel = regel?.target ?? null;
  const erfuellt = eintrag.status === "completed";

  return (
    <div className="zeile">
      <span
        className="marke"
        style={{ background: `${habit.colorHex}22`, color: habit.colorHex }}
        aria-hidden="true"
      >
        {zeichenFuer(habit.symbol, habit.name)}
      </span>

      <span className="mitte">
        <span className="name">{habit.name}</span>
        <span className="unter">
          <span>{regel ? planText(regel.schedule) : ""}</span>
          {eintrag.currentStreak > 0 && (
            <span className="flamme">🔥 {eintrag.currentStreak}</span>
          )}
          {eintrag.trend === "improving" && <span className="trend-improving">↑</span>}
          {eintrag.trend === "declining" && <span className="trend-declining">↓</span>}
        </span>
      </span>

      {habit.kind === "binary" && (
        <button
          className={erfuellt ? "haken erfuellt" : "haken"}
          disabled={laeuft}
          aria-pressed={erfuellt}
          aria-label={`${habit.name} ${erfuellt ? "nicht mehr erledigt" : "erledigt"}`}
          onClick={() => aendern(habit.id, datum, erfuellt ? 0 : 1)}
        >
          ✓
        </button>
      )}

      {habit.kind === "quantity" && ziel && (
        <span className="stufe">
          <button
            aria-label="weniger"
            disabled={laeuft}
            onClick={() => aendern(habit.id, datum, eintrag.value - schrittweite(ziel.value))}
          >
            −
          </button>
          <span className="wert">
            {zahl(eintrag.value)}
            {ziel.unit ? ` ${ziel.unit}` : ""}
          </span>
          <button
            aria-label="mehr"
            disabled={laeuft}
            onClick={() => aendern(habit.id, datum, eintrag.value + schrittweite(ziel.value))}
          >
            +
          </button>
        </span>
      )}

      {habit.kind === "avoid" && (
        // Kein Abhaken: bei Vermeidung ist Erfolg der Normalzustand, gemeldet
        // wird nur der Verstoß.
        <button
          className={eintrag.value > 0 ? "verstoss aktiv" : "verstoss"}
          disabled={laeuft}
          onClick={() => aendern(habit.id, datum, eintrag.value + 1)}
        >
          {eintrag.value > 0 ? `${zahl(eintrag.value)}×` : "Verstoß"}
        </button>
      )}
    </div>
  );
}

/// Die an diesem Tag gültige Regel — dieselbe Auswahl wie `ruleOn` im Server.
function gueltigeRegel(habit: Habit, datum: CalendarDate) {
  let ergebnis = null;
  for (const regel of habit.rules) {
    if (regel.effectiveFrom <= datum) ergebnis = regel;
  }
  return ergebnis;
}

/// Schrittweite passend zur Größenordnung: 0,5 bei Litern, 500 bei Schritten.
///
/// Wortgleich mit `stepSize(for:)` in `HabitUI/Components.swift`. Bislang die
/// einzige Regel, die in beiden Oberflächen doppelt steht — sie beeinflusst
/// keine Zahl, nur wie schnell man sie erreicht.
function schrittweite(ziel: number): number {
  if (ziel < 5) return 0.5;
  if (ziel < 100) return 5;
  if (ziel < 1000) return 50;
  return 500;
}
