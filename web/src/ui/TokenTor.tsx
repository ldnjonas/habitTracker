/// Einmal das Token eintragen, dann nie wieder.
///
/// Es liegt danach im `localStorage`: wer den Browser hat, hat den Zugang. Auf
/// einem privaten Telefon ist das vertretbar, aber es ist eine Entscheidung —
/// deshalb steht sie auch auf dieser Seite und nicht nur im Quelltext.

import { useState } from "react";
import { setzeToken, tokenPasst } from "../api/client.ts";

export function TokenTor({ fertig }: { fertig: () => void }) {
  const [wert, setzeWert] = useState("");
  const [laeuft, setzeLaeuft] = useState(false);
  const [fehler, setzeFehler] = useState<string | null>(null);

  async function absenden(ereignis: React.FormEvent) {
    ereignis.preventDefault();
    if (!wert.trim() || laeuft) return;
    setzeLaeuft(true);
    setzeFehler(null);
    try {
      if (await tokenPasst(wert)) {
        setzeToken(wert);
        fertig();
      } else {
        setzeFehler("Der Server kennt dieses Token nicht.");
      }
    } catch {
      setzeFehler("Der Server ist nicht erreichbar.");
    } finally {
      setzeLaeuft(false);
    }
  }

  return (
    <form className="tor" onSubmit={absenden}>
      <h1>Habit Tracker</h1>
      <p>
        Einmal das Zugangstoken des Servers eintragen. Es bleibt in diesem
        Browser gespeichert — wer ihn öffnen kann, kommt damit an die Daten.
      </p>
      <input
        type="password"
        value={wert}
        onChange={(e) => setzeWert(e.target.value)}
        placeholder="Token"
        autoComplete="off"
        autoCapitalize="off"
        autoCorrect="off"
        spellCheck={false}
        aria-label="Zugangstoken"
      />
      {fehler && <div className="fehler">{fehler}</div>}
      <button type="submit" disabled={!wert.trim() || laeuft}>
        {laeuft ? "Wird geprüft …" : "Verbinden"}
      </button>
    </form>
  );
}
