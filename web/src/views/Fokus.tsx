/// Fokus-Läufe und das Freeze-Konto.
///
/// **Das Ergebnis wird berechnet, nie gespeichert.** Was hier steht, rechnet der
/// Server bei jedem Aufruf aus den Einträgen aus; ein gespeichertes „geschafft"
/// würde von ihnen abdriften, sobald ein Tag nachträglich korrigiert wird.

import { useState } from "react";
import { api } from "../api/client.ts";
import type { FocusProgress, FreezeKonto, Habit } from "../api/types.ts";
import { Blatt, Feld, Karte, Zeile } from "../ui/Blatt.tsx";
import { schreibe, useLaden } from "../ui/laden.ts";
import { daysUntil } from "../../../server/src/domain/calendar.ts";
import { kurzesDatum } from "../ui/text.ts";

const ERGEBNIS_TEXT: Record<string, string> = {
  upcoming: "Beginnt noch",
  running: "Läuft",
  completed: "Durchgezogen",
  failed: "Gerissen",
  abandoned: "Selbst beendet",
};

export function Fokus({ abgemeldet }: { abgemeldet: () => void }) {
  const [neuOffen, setzeNeuOffen] = useState(false);
  const [meldung, setzeMeldung] = useState<string | null>(null);

  const { daten, fehler, neuLaden } = useLaden(async () => {
    const [laeufe, konto, habits] = await Promise.all([
      api.hole<FocusProgress[]>("/focus"),
      api.hole<FreezeKonto>("/freezes"),
      api.hole<Habit[]>("/habits"),
    ]);
    return { laeufe, konto, habits };
  }, [], abgemeldet);

  if (fehler) return <div className="fehler">{fehler}</div>;
  if (!daten) return <div className="laedt">Wird geladen …</div>;

  const { laeufe, konto, habits } = daten;
  const offen = laeufe.find((l) => l.outcome.code === "upcoming" || l.outcome.code === "running");
  const abgeschlossen = laeufe.filter(
    (l) => l.outcome.code !== "upcoming" && l.outcome.code !== "running");
  const geschafft = abgeschlossen.filter((l) => l.outcome.code === "completed").length;

  return (
    <>
      <header className="kopf">
        <h1>Fokus</h1>
        <div className="zeile">
          <span className="zahl">
            {abgeschlossen.length === 0
              ? "noch kein abgeschlossener Lauf"
              : `${geschafft} von ${abgeschlossen.length} durchgezogen`}
          </span>
          {!offen && <button className="klein-knopf" onClick={() => setzeNeuOffen(true)}>Starten</button>}
        </div>
      </header>

      {meldung && <div className="fehler">{meldung}</div>}

      <Karte titel="Freeze-Konto">
        <Zeile label="Guthaben" wert={`${konto.balance} von ${konto.maximum}`} />
        <p className="hinweis klein">
          Ein durchgezogener Lauf bringt einen Freeze. Steht das Konto voll, verfällt der
          Anspruch — ohne Obergrenze hielte ein Polster jeden Streak beliebig lange am Leben,
          und dann sagt er nichts mehr aus.
        </p>
      </Karte>

      {offen ? (
        <Karte titel="Läuft gerade">
          <LaufZeile lauf={offen} />
          <div className="knopfreihe">
            <button onClick={() => void schreibe(
              () => api.sende(`/focus/${offen.run.id}/abandon`, {}),
              neuLaden, setzeMeldung, abgemeldet)}>
              Beenden
            </button>
          </div>
          <p className="hinweis klein">
            Selbst beendet schlägt beim Auswerten jedes andere Ergebnis — auch einen Lauf, der
            rechnerisch noch heil wäre. Das ist ehrlicher, als ihn still verrotten zu lassen.
          </p>
        </Karte>
      ) : (
        <p className="hinweis">
          Kein Lauf offen. Ein Fokus ist ein Versprechen mit Anfang, Ende und Ergebnis —
          und er beginnt immer heute.
        </p>
      )}

      {abgeschlossen.length > 0 && (
        <Karte titel="Verlauf">
          {abgeschlossen.map((lauf) => (
            <div className="laufzeile" key={lauf.run.id}>
              <LaufZeile lauf={lauf} />
              <button className="leise" aria-label="Aus dem Verlauf entfernen"
                      onClick={() => void schreibe(
                        () => api.loesche(`/focus/${lauf.run.id}`),
                        neuLaden, setzeMeldung, abgemeldet)}>×</button>
            </div>
          ))}
        </Karte>
      )}

      {neuOffen && (
        <NeuerLauf habits={habits} schliessen={() => setzeNeuOffen(false)}
                   fertig={neuLaden} abgemeldet={abgemeldet} />
      )}
    </>
  );
}

function LaufZeile({ lauf }: { lauf: FocusProgress }) {
  const ergebnis = lauf.outcome;
  const titel = lauf.run.title && lauf.run.title.length > 0
    ? lauf.run.title
    : `${lauf.run.habitIds.length === 0 ? "" : ""}${tage(lauf)}-Tage-Fokus`;

  return (
    <div className="lauf">
      <div className="lauf-kopf">
        <strong>{titel}</strong>
        <span className={`marker ${ergebnis.code}`}>{ERGEBNIS_TEXT[ergebnis.code]}</span>
      </div>
      <div className="unter">
        {kurzesDatum(lauf.run.startsOn)} – {kurzesDatum(lauf.run.endsOn)}
        {ergebnis.code === "running" && ` · Tag ${ergebnis.dayNumber} von ${ergebnis.totalDays}`}
        {ergebnis.code === "failed" && ` · gerissen am ${kurzesDatum(ergebnis.on)}`}
        {ergebnis.code === "abandoned" && ` · beendet am ${kurzesDatum(ergebnis.on)}`}
      </div>
      <div className="balken">
        <span style={{
          width: `${Math.round((lauf.plannedDays > 0
            ? lauf.perfectDays / lauf.plannedDays : 1) * 100)}%`,
        }} />
      </div>
      <div className="unter">
        {lauf.perfectDays} von {lauf.plannedDays} geplanten Tagen geschafft
        {lauf.run.habitIds.length > 0 && ` · ${lauf.run.habitIds.length} Habits`}
      </div>
    </div>
  );
}

function tage(lauf: FocusProgress): number {
  return daysUntil(lauf.run.startsOn, lauf.run.endsOn) + 1;
}

// MARK: - Starten

function NeuerLauf({
  habits, schliessen, fertig, abgemeldet,
}: {
  habits: Habit[];
  schliessen: () => void;
  fertig: () => Promise<void>;
  abgemeldet: () => void;
}) {
  const [dauer, setzeDauer] = useState(7);
  const [titel, setzeTitel] = useState("");
  const [auswahl, setzeAuswahl] = useState<Set<string>>(new Set());
  const [meldung, setzeMeldung] = useState<string | null>(null);
  const [laeuft, setzeLaeuft] = useState(false);

  async function starten() {
    setzeLaeuft(true);
    const gut = await schreibe(() => api.sende("/focus", {
      days: dauer,
      title: titel.trim() || undefined,
      habitIds: [...auswahl],
    }), fertig, setzeMeldung, abgemeldet);
    setzeLaeuft(false);
    if (gut) schliessen();
  }

  return (
    <Blatt titel="Fokus starten" schliessen={schliessen}
           aktion={<button onClick={starten} disabled={laeuft}>Starten</button>}>
      <p className="hinweis klein">
        Beginnt heute. Bewusst nicht rückwirkend — sonst trüge man sich nachträglich eine
        geschaffte Woche ein, und die Bilanz wäre nichts wert.
      </p>

      {meldung && <div className="fehler">{meldung}</div>}

      <Feld titel="Dauer">
        <div className="segmente">
          {[3, 7, 14, 30].map((n) => (
            <button key={n} aria-selected={dauer === n} role="tab"
                    onClick={() => setzeDauer(n)}>{n} Tage</button>
          ))}
        </div>
      </Feld>

      <Feld titel="Name" hinweis="Ohne Angabe heißt er nach seiner Länge.">
        <input value={titel} onChange={(e) => setzeTitel(e.target.value)}
               placeholder={`${dauer}-Tage-Fokus`} />
      </Feld>

      <Feld titel="Welche Habits"
            hinweis="Nichts ausgewählt heißt alle — auch später angelegte.">
        <div className="auswahl">
          {habits.map((h) => (
            <button key={h.id} aria-pressed={auswahl.has(h.id)}
                    onClick={() => setzeAuswahl((alt) => {
                      const neu = new Set(alt);
                      if (neu.has(h.id)) neu.delete(h.id); else neu.add(h.id);
                      return neu;
                    })}>
              {h.name}
            </button>
          ))}
        </div>
      </Feld>

      <p className="hinweis klein">
        Ein Tag ist geschafft, wenn alles erledigt ist, was an ihm verpflichtend war. Ein
        Streak Freeze rettet einen Fokus nicht — er ist das strengere Versprechen. Der
        laufende Tag lässt ihn nie scheitern, solange er offen ist.
      </p>
    </Blatt>
  );
}
