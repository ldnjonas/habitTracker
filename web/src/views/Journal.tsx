/// Das Tages-Journal und was sich daraus über die Habits sagen lässt.
///
/// **Die Zurückhaltung ist der Punkt.** Bei wenigen Tagen findet man in
/// Zufallsrauschen immer irgendeinen Zusammenhang; wird er angezeigt, glaubt
/// man ihn. Der Server meldet deshalb nur, was über der Zufallsgrenze für
/// *diese* Datenmenge liegt — meistens also nichts. Diese Ansicht sagt das,
/// statt eine leere Fläche zu zeigen.

import { useState } from "react";
import { api } from "../api/client.ts";
import type { CalendarDate, Correlation, DayLog, Habit, JournalMetric } from "../api/types.ts";
import { addDays } from "../../../server/src/domain/calendar.ts";
import { Blatt, Feld, Karte, Zeile } from "../ui/Blatt.tsx";
import { schreibe, useLaden } from "../ui/laden.ts";
import { kurzesDatum, langesDatum, langerWochentag, zahl } from "../ui/text.ts";

const METRIK_TEXT: Record<JournalMetric, string> = {
  mood: "Stimmung",
  energy: "Energie",
  sleepHours: "Schlaf",
};

const STAERKE_TEXT: Record<string, string> = {
  weak: "schwach",
  moderate: "mäßig",
  strong: "deutlich",
};

export function Journal({
  heute, schliessen, abgemeldet,
}: {
  heute: CalendarDate;
  schliessen: () => void;
  abgemeldet: () => void;
}) {
  const [tag, setzeTag] = useState<CalendarDate>(heute);
  const von = addDays(heute, -90);

  const { daten, fehler, neuLaden } = useLaden(async () => {
    const [logs, befunde, habits] = await Promise.all([
      api.hole<DayLog[]>(`/days?from=${von}&to=${heute}`),
      api.hole<Correlation[]>(`/insights/correlations?from=${von}&to=${heute}`),
      api.hole<Habit[]>("/habits?includeArchived=true"),
    ]);
    return { logs, befunde, habits: new Map(habits.map((h) => [h.id, h])) };
  }, [von, heute], abgemeldet);

  return (
    <Blatt titel="Journal" schliessen={schliessen}>
      {fehler && <div className="fehler">{fehler}</div>}
      {!daten ? <div className="laedt">Wird geladen …</div> : (
        <>
          <div className="zeile">
            <strong>{langerWochentag(tag)}, {langesDatum(tag)}</strong>
            <span className="blaettern">
              <button onClick={() => setzeTag(addDays(tag, -1))} aria-label="Tag zurück">‹</button>
              <button onClick={() => setzeTag(heute)} disabled={tag === heute}>Heute</button>
              <button onClick={() => setzeTag(addDays(tag, 1))}
                      disabled={tag >= heute} aria-label="Tag vor">›</button>
            </span>
          </div>

          <TagesEintrag
            key={tag}
            datum={tag}
            vorhanden={daten.logs.find((l) => l.date === tag) ?? null}
            gespeichert={neuLaden}
            abgemeldet={abgemeldet}
          />

          <Karte titel="Zusammenhänge">
            {daten.befunde.length === 0 ? (
              <p className="hinweis klein">
                Nichts zu berichten. Das ist der Normalfall und kein Fehler: gemeldet wird nur,
                was über der Zufallsgrenze für diese Datenmenge liegt — mindestens 14
                gemeinsame Tage, je 5 in beiden Gruppen, und ein Zusammenhang, der bei so
                vielen Tagen nicht mehr als Zufall durchgeht.
              </p>
            ) : (
              <>
                {daten.befunde.map((befund) => (
                  <BefundZeile key={`${befund.habitId}-${befund.metric}`}
                               befund={befund}
                               name={daten.habits.get(befund.habitId)?.name ?? "Habit"} />
                ))}
                <p className="hinweis klein">
                  Es fällt zusammen — ob das eine das andere bewirkt, sagen diese Zahlen nicht.
                </p>
              </>
            )}
          </Karte>

          <Karte titel="Letzte Einträge">
            {daten.logs.length === 0
              ? <p className="hinweis klein">Noch nichts eingetragen.</p>
              : daten.logs.slice().reverse().slice(0, 14).map((log) => (
                  <Zeile key={log.date} label={kurzesDatum(log.date)}
                         wert={zusammenfassung(log)} />
                ))}
          </Karte>
        </>
      )}
    </Blatt>
  );
}

function zusammenfassung(log: DayLog): string {
  const teile: string[] = [];
  if (log.mood != null) teile.push(`Stimmung ${log.mood}`);
  if (log.energy != null) teile.push(`Energie ${log.energy}`);
  if (log.sleepHours != null) teile.push(`${zahl(log.sleepHours)} h Schlaf`);
  return teile.length === 0 ? (log.note ? "Notiz" : "—") : teile.join(" · ");
}

function BefundZeile({ befund, name }: { befund: Correlation; name: string }) {
  const richtung = befund.completedAverage > befund.missedAverage ? "höher" : "niedriger";
  const unterschied = Math.abs(befund.completedAverage - befund.missedAverage);
  return (
    <div className="befund">
      <strong>
        An Tagen mit „{name}" liegt {METRIK_TEXT[befund.metric]} um {zahl(unterschied)} {richtung}.
      </strong>
      <span className="unter">
        {STAERKE_TEXT[befund.strength]} · {befund.dayCount} gemeinsame Tage
        {" "}({befund.completedDays} mit, {befund.dayCount - befund.completedDays} ohne)
      </span>
    </div>
  );
}

// MARK: - Ein Tag

function TagesEintrag({
  datum, vorhanden, gespeichert, abgemeldet,
}: {
  datum: CalendarDate;
  vorhanden: DayLog | null;
  gespeichert: () => Promise<void>;
  abgemeldet: () => void;
}) {
  const [stimmung, setzeStimmung] = useState<number | null>(vorhanden?.mood ?? null);
  const [energie, setzeEnergie] = useState<number | null>(vorhanden?.energy ?? null);
  const [schlaf, setzeSchlaf] = useState(
    vorhanden?.sleepHours == null ? "" : String(vorhanden.sleepHours));
  const [notiz, setzeNotiz] = useState(vorhanden?.note ?? "");
  const [meldung, setzeMeldung] = useState<string | null>(null);
  const [laeuft, setzeLaeuft] = useState(false);

  async function speichern() {
    setzeLaeuft(true);
    const stunden = schlaf.trim().replace(",", ".");
    await schreibe(() => api.setze(`/days/${datum}`, {
      mood: stimmung,
      energy: energie,
      sleepHours: stunden === "" ? null : Number(stunden),
      note: notiz.trim() || null,
    }), gespeichert, setzeMeldung, abgemeldet);
    setzeLaeuft(false);
  }

  return (
    <Karte>
      {meldung && <div className="fehler">{meldung}</div>}

      <Feld titel="Stimmung">
        <Skala wert={stimmung} setze={setzeStimmung} />
      </Feld>
      <Feld titel="Energie">
        <Skala wert={energie} setze={setzeEnergie} />
      </Feld>
      <Feld titel="Schlaf" hinweis="Stunden, etwa 7,5">
        <input inputMode="decimal" value={schlaf}
               onChange={(e) => setzeSchlaf(e.target.value)} placeholder="—" />
      </Feld>
      <Feld titel="Notiz">
        <textarea rows={3} value={notiz} onChange={(e) => setzeNotiz(e.target.value)} />
      </Feld>

      <button className="breit haupt" onClick={speichern} disabled={laeuft}>
        {laeuft ? "Wird gespeichert …" : "Speichern"}
      </button>
      <p className="hinweis klein">
        Was leer bleibt, wird geleert — der Eintrag eines Tages wird als Ganzes gesetzt.
      </p>
    </Karte>
  );
}

function Skala({ wert, setze }: { wert: number | null; setze: (w: number | null) => void }) {
  return (
    <div className="skala">
      {[1, 2, 3, 4, 5].map((n) => (
        <button key={n} aria-pressed={wert === n}
                onClick={() => setze(wert === n ? null : n)}>{n}</button>
      ))}
    </div>
  );
}
