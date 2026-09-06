import { useCallback, useEffect, useState } from "react";
import { api, istAbgemeldet, token, vergissToken } from "./api/client.ts";
import type { CalendarDate, Habit, Tag } from "./api/types.ts";
import { Schale, type Register } from "./ui/Schale.tsx";
import { TokenTor } from "./ui/TokenTor.tsx";
import { Heute } from "./views/Heute.tsx";
import { Uebersicht } from "./views/Uebersicht.tsx";
import { Fokus } from "./views/Fokus.tsx";
import { Mehr } from "./views/Mehr.tsx";
import { Journal } from "./views/Journal.tsx";
import { HabitDetail } from "./views/HabitDetail.tsx";
import { HabitEditor } from "./views/HabitEditor.tsx";

/// Was gerade über allem liegt. Höchstens eines — auf einem Telefon ist ein
/// Stapel aus vier Ebenen ein Labyrinth.
type Ueberlagerung =
  | { art: "detail"; habit: Habit }
  | { art: "editor"; habit: Habit | null }
  | { art: "journal" }
  | null;

export function App() {
  const [angemeldet, setzeAngemeldet] = useState(() => token() !== null);
  const [register, setzeRegister] = useState<Register>("heute");
  const [ueberlagerung, setzeUeberlagerung] = useState<Ueberlagerung>(null);
  const [tags, setzeTags] = useState<Tag[]>([]);
  /// Welcher Tag „heute" ist, entscheidet der **Server**. Der Browser könnte in
  /// einer anderen Zeitzone stehen — dann zeigte er die Liste von gestern und
  /// bekäme beim Abhaken eine 422.
  const [heute, setzeHeute] = useState<CalendarDate | null>(null);
  /// Zwingt Ansichten zum Neuladen, wenn anderswo etwas geändert wurde.
  const [runde, setzeRunde] = useState(0);

  const abmelden = useCallback(() => {
    vergissToken();
    setzeAngemeldet(false);
    setzeUeberlagerung(null);
  }, []);

  useEffect(() => {
    if (!angemeldet) return;
    void (async () => {
      try {
        const [uebersicht, tagListe] = await Promise.all([
          api.hole<{ date: CalendarDate }>("/stats/summary"),
          api.hole<Tag[]>("/tags"),
        ]);
        setzeHeute(uebersicht.date);
        setzeTags(tagListe);
      } catch (f) {
        if (istAbgemeldet(f)) abmelden();
      }
    })();
  }, [angemeldet, abmelden, runde]);

  const geaendert = useCallback(async () => { setzeRunde((n) => n + 1); }, []);

  if (!angemeldet) return <TokenTor fertig={() => setzeAngemeldet(true)} />;
  if (!heute) return <div className="laedt">Wird geladen …</div>;

  return (
    <Schale aktiv={register} waehle={setzeRegister}>
      {register === "heute" && <Heute key={runde} abgemeldet={abmelden} />}
      {register === "uebersicht" && (
        <Uebersicht key={runde} heute={heute} abgemeldet={abmelden} />
      )}
      {register === "fokus" && <Fokus key={runde} abgemeldet={abmelden} />}
      {register === "mehr" && (
        <Mehr
          key={runde}
          heute={heute}
          abgemeldet={abmelden}
          oeffneHabit={(habit) => setzeUeberlagerung({ art: "detail", habit })}
          oeffneJournal={() => setzeUeberlagerung({ art: "journal" })}
          neuerHabit={() => setzeUeberlagerung({ art: "editor", habit: null })}
          bearbeiteHabit={(habit) => setzeUeberlagerung({ art: "editor", habit })}
        />
      )}

      {ueberlagerung?.art === "detail" && (
        <HabitDetail
          habit={ueberlagerung.habit}
          heute={heute}
          schliessen={() => setzeUeberlagerung(null)}
          bearbeiten={() => setzeUeberlagerung({ art: "editor", habit: ueberlagerung.habit })}
          abgemeldet={abmelden}
        />
      )}

      {ueberlagerung?.art === "editor" && (
        <HabitEditor
          habit={ueberlagerung.habit}
          tags={tags}
          heute={heute}
          schliessen={() => setzeUeberlagerung(null)}
          fertig={geaendert}
          abgemeldet={abmelden}
        />
      )}

      {ueberlagerung?.art === "journal" && (
        <Journal heute={heute} schliessen={() => setzeUeberlagerung(null)}
                 abgemeldet={abmelden} />
      )}
    </Schale>
  );
}
