/// Eine Umgebungsvariable lesen, ohne zu wissen, wer sie hält.
///
/// Node legt sie in `process.env`, Deno hinter `Deno.env.get`. Der Server soll
/// beides nicht wissen müssen — er läuft unter Node zu Hause und unter Deno in
/// der Edge Function, und der Unterschied gehört in diese vier Zeilen und
/// nirgendwo sonst.
export function umgebung(name: string): string | undefined {
  const deno = (globalThis as {
    Deno?: { env: { get(schluessel: string): string | undefined } };
  }).Deno;
  if (deno) return deno.env.get(name);
  return (globalThis as {
    process?: { env: Record<string, string | undefined> };
  }).process?.env[name];
}
