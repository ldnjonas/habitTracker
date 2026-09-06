import { useState } from "react";
import { token, vergissToken } from "./api/client.ts";
import { Schale, type Register } from "./ui/Schale.tsx";
import { TokenTor } from "./ui/TokenTor.tsx";
import { Heute } from "./views/Heute.tsx";
import { Platzhalter } from "./views/Platzhalter.tsx";

export function App() {
  const [angemeldet, setzeAngemeldet] = useState(() => token() !== null);
  const [register, setzeRegister] = useState<Register>("heute");

  function abmelden() {
    vergissToken();
    setzeAngemeldet(false);
  }

  if (!angemeldet) return <TokenTor fertig={() => setzeAngemeldet(true)} />;

  return (
    <Schale aktiv={register} waehle={setzeRegister}>
      {register === "heute" && <Heute abgemeldet={abmelden} />}
      {register === "uebersicht" && (
        <Platzhalter
          titel="Übersicht"
          text="Die gesammelte Heatmap über alle Habits kommt als Nächstes."
        />
      )}
      {register === "fokus" && (
        <Platzhalter
          titel="Fokus"
          text="Läufe starten und den Verlauf sehen — noch nicht gebaut."
        />
      )}
      {register === "mehr" && (
        <Platzhalter
          titel="Mehr"
          text="Journal, Sicherung, Papierkorb und Tags — noch nicht gebaut."
        />
      )}
    </Schale>
  );
}
