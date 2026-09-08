/// Was in einer entfernten Datenbank steht — ohne Server, ohne Client.
///
/// Für den Umzug und danach: hat `db push` das Schema angelegt, wie weit ist
/// die Folge, und welche Kennung trägt diese Datenbank? Die Kennung ist die
/// Frage, an der ein Umzug gelingt oder scheitert.
///
/// Aufruf:
///     node --disable-warning=ExperimentalWarning tools/fern-stand.ts .env.local

import { readFileSync } from "node:fs";
import postgres from "postgres";

const url = readFileSync(process.argv[2] ?? ".env.local", "utf8").trim();
const sql = postgres(url, { max: 1, prepare: false });

const tabellen = (await sql`
  SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename
`).map((z) => String(z.tablename));

console.log(`Tabellen (${tabellen.length}): ${tabellen.join(", ") || "keine"}`);

if (tabellen.includes("sync_sequence")) {
  const [folge] = await sql`SELECT value FROM sync_sequence WHERE id = 1`;
  const [kennung] = await sql`SELECT instance FROM server_info WHERE id = 1`;
  console.log(`Folge:   ${folge?.value ?? "—"}`);
  console.log(`Kennung: ${kennung?.instance ?? "noch keine"}`);
  for (const t of ["habit", "tag", "entry", "entry_event", "day_log",
                   "day_exception", "focus_run", "freeze_ledger"]) {
    const [n] = await sql.unsafe(`SELECT count(*)::int AS n FROM "${t}"`);
    console.log(`  ${t.padEnd(14)} ${n?.n}`);
  }
}

await sql.end();
