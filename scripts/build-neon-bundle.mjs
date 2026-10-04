/**
 * Bundles the migration chain into a handful of files you can paste into
 * Neon's SQL Editor.
 *
 * WHY THIS EXISTS
 *
 * Setting up Neon means applying 50 migrations plus three Neon-specific
 * files. With psql that is a for-loop; in a browser SQL editor it is 53
 * copy-pastes, and the 30th one going in twice or out of order is a
 * genuinely hard problem to unpick. So this concatenates them into a few
 * parts, in the right order, with the substitutions already applied.
 *
 * TWO THINGS DECIDE WHERE THE SPLITS GO
 *
 * 1. A HARD boundary after migration 0045. It adds a value to the
 *    order_source enum, and Postgres refuses to let a later statement USE a
 *    new enum value in the same transaction — which is exactly what 0046
 *    does. A SQL editor runs a pasted script as one transaction, so these
 *    two cannot share a part. This is not a preference; combining them
 *    fails.
 *
 * 2. Size. Browser editors get unhappy past a few hundred KB, so the rest of
 *    the chain is split to keep each part under MAX_BYTES.
 *
 * The substitutions, which are the same ones the runbook describes:
 *   - 0041 is replaced by the pg_net-free variant (Neon has no pg_net)
 *   - 0044 is dropped (PostGIS region boundaries, from the cancelled Mapbox
 *     work; nothing references them)
 *
 * Regenerate after adding a migration:  node scripts/build-neon-bundle.mjs
 */

import { readFileSync, writeFileSync, mkdirSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const MAX_BYTES = 110 * 1024;
const OUT_DIR = "neon/bundled";

const num = (name) => Number(name.slice(0, 4));

const chain = readdirSync("supabase/migrations")
  .filter((f) => f.endsWith(".sql"))
  .sort()
  .flatMap((f) => {
    const n = num(f);
    if (n === 44) return []; // dropped: see the header
    if (n === 41) return ["neon/migrations/0041_push_dispatch_trigger.neon.sql"];
    return [join("supabase/migrations", f)];
  });

const PRELUDE = "neon/migrations/0000_prelude.sql";
const SHIM = "neon/migrations/0001_auth_shim.sql";
const LOCAL_AUTH = "neon/migrations/0002_local_auth.sql";

/** The enum boundary. Everything from 0046 on must be a later transaction. */
const beforeEnum = chain.filter((f) => num(f.split("/").pop()) <= 45);
const afterEnum = chain.filter((f) => num(f.split("/").pop()) >= 46);

/** Greedy split to keep each part paste-able. */
function chunk(files) {
  const parts = [];
  let current = [];
  let size = 0;
  for (const f of files) {
    const s = statSync(f).size;
    if (current.length && size + s > MAX_BYTES) {
      parts.push(current);
      current = [];
      size = 0;
    }
    current.push(f);
    size += s;
  }
  if (current.length) parts.push(current);
  return parts;
}

const groups = [
  ...chunk([PRELUDE, ...beforeEnum]).map((files) => ({ files, note: null })),
  {
    files: afterEnum,
    note:
      "Requires the previous part to have FINISHED. It uses the order_source\n-- enum value that part added, which Postgres will not allow in the same\n-- transaction.",
  },
  {
    files: [SHIM, LOCAL_AUTH],
    note:
      "The Neon-specific part: replaces auth.uid(), removes the PostgREST roles,\n-- and adds the password and login machinery that replaces GoTrue.",
  },
];

mkdirSync(OUT_DIR, { recursive: true });

const total = groups.length;
const written = [];

groups.forEach((group, i) => {
  const n = i + 1;
  const manifest = group.files.map((f, j) => `--   ${String(j + 1).padStart(2)}. ${f}`).join("\n");
  const note =
    group.note ??
    (n === 1
      ? "Start here. Creates the roles, schemas and tables the chain expects."
      : "Requires the previous part to have finished.");

  const header = `-- ============================================================================
-- NEON SETUP — PART ${n} OF ${total}
--
-- PASTE THIS WHOLE FILE INTO NEON'S SQL EDITOR AND RUN IT.
-- Run the parts in order. Wait for each to finish before starting the next.
-- Each part is safe to re-run: every statement is idempotent.
--
-- ${note}
--
-- GENERATED — do not edit. Edit the source files listed below and re-run
-- scripts/build-neon-bundle.mjs, so Supabase and Neon cannot drift apart.
--
-- Contains, in order:
${manifest}
-- ============================================================================

-- The chain installs pgcrypto/pg_trgm into the extensions schema (as Supabase
-- does) and several functions resolve against it. Declared per part rather
-- than relied on from the database default, so pasting a part into a fresh
-- editor session always works.
set search_path = public, extensions;

`;

  const bodies = group.files.map(
    (f) => `\n\n-- ========== ${f} ${"=".repeat(Math.max(0, 58 - f.length))}\n\n${readFileSync(f, "utf8")}`,
  );

  const name = `part${n}_of_${total}.sql`;
  const path = join(OUT_DIR, name);
  writeFileSync(path, header + bodies.join(""));
  written.push({ name, files: group.files.length, kb: Math.round(statSync(path).size / 1024) });
});

console.log(`\nwrote ${written.length} part(s) to ${OUT_DIR}/\n`);
for (const w of written) {
  console.log(`  ${w.name.padEnd(20)} ${String(w.files).padStart(2)} migrations  ${String(w.kb).padStart(4)} KB`);
}
console.log("");
