/// Laden, Fehler, Nachladen — an einer Stelle.
///
/// Jede Ansicht holt sich, was sie braucht, und lädt nach einer Änderung neu.
/// Bei einem Aufruf je Ansicht ist ein Zwischenspeicher mehr Verwaltung als
/// Nutzen; was er sparen würde, ist eine Anfrage über ein Netz, das im selben
/// Haus steht.

import { useCallback, useEffect, useState } from "react";
import { ApiFehler } from "../api/client.ts";

export type Zustand<T> = {
  daten: T | null;
  fehler: string | null;
  laedt: boolean;
  neuLaden: () => Promise<void>;
};

/// Führt `hole` aus, sobald sich `abhaengig` ändert.
///
/// Ein 401 bedeutet, dass das Token nicht mehr gilt; das ist kein Fehler dieser
/// Ansicht, sondern einer der Anmeldung — deshalb geht er nach oben, statt hier
/// als roter Kasten zu enden.
export function useLaden<T>(
  hole: () => Promise<T>,
  abhaengig: unknown[],
  abgemeldet: () => void,
): Zustand<T> {
  const [daten, setzeDaten] = useState<T | null>(null);
  const [fehler, setzeFehler] = useState<string | null>(null);
  const [laedt, setzeLaedt] = useState(true);

  // eslint-disable-next-line react-hooks/exhaustive-deps
  const laufen = useCallback(hole, abhaengig);

  const neuLaden = useCallback(async () => {
    setzeLaedt(true);
    try {
      setzeDaten(await laufen());
      setzeFehler(null);
    } catch (f) {
      if (f instanceof ApiFehler && f.status === 401) return abgemeldet();
      setzeFehler(f instanceof Error ? f.message : "Unbekannter Fehler");
    } finally {
      setzeLaedt(false);
    }
  }, [laufen, abgemeldet]);

  useEffect(() => { void neuLaden(); }, [neuLaden]);

  return { daten, fehler, laedt, neuLaden };
}

/// Für schreibende Aufrufe: führt aus, meldet Fehler, lädt neu.
export async function schreibe(
  tun: () => Promise<unknown>,
  danach: () => Promise<void>,
  melde: (fehler: string | null) => void,
  abgemeldet: () => void,
): Promise<boolean> {
  try {
    await tun();
    melde(null);
    await danach();
    return true;
  } catch (f) {
    if (f instanceof ApiFehler && f.status === 401) { abgemeldet(); return false; }
    melde(f instanceof Error ? f.message : "Unbekannter Fehler");
    return false;
  }
}
