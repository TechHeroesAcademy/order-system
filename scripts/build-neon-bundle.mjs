import { readFileSync, writeFileSync, mkdirSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const MAX_BYTES = 110 * 1024;
const OUT_DIR = "db/bundled";

const num = (name) => Number(name.slice(0, 4));

const chain = readdirSync("db/migrations")
  .filter((f) => f.endsWith(".sql"))
  .sort()
  .flatMap((f) => {
    const n = num(f);
    if (n === 44) return [];
    if (n === 41) return ["db/neon/0041_push_dispatch_trigger.neon.sql"];
    return [join("db/migrations", f)];
  });

const PRELUDE = "db/neon/0000_prelude.sql";

const NEON_AFTER_PRELUDE = readdirSync("db/neon")
  .filter((f) => f.endsWith(".sql"))
  .filter((f) => f !== "0000_prelude.sql")
  .filter((f) => !f.includes(".neon."))
  .sort()
  .map((f) => join("db/neon", f));

const beforeEnum = chain.filter((f) => num(f.split("/").pop()) <= 45);
const afterEnum = chain.filter((f) => num(f.split("/").pop()) >= 46);

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
  ...chunk([PRELUDE, ...beforeEnum]).map((files) => ({ files })),
  { files: afterEnum },
  { files: NEON_AFTER_PRELUDE },
];

mkdirSync(OUT_DIR, { recursive: true });

const total = groups.length;
const written = [];

groups.forEach((group, i) => {
  const n = i + 1;

  const header = "set search_path = public, extensions;\n";

  const bodies = group.files.map((f) => `\n\n${readFileSync(f, "utf8")}`);

  const name = `part${n}_of_${total}.sql`;
  const path = join(OUT_DIR, name);
  writeFileSync(path, header + bodies.join(""));
  written.push({ name, files: group.files.length, kb: Math.round(statSync(path).size / 1024) });
});

const CHECK_FILE = "db/maintenance/check_schema_parts.sql";

const rows = [];
const seen = new Set();

groups.forEach((group, i) => {
  const part = i + 1;
  const body = group.files.map((f) => readFileSync(f, "utf8")).join("\n");

  const names = (re) =>
    [...new Set([...body.matchAll(re)].map((m) => m[1]))].filter((n) => {
      if (seen.has(n)) return false;
      seen.add(n);
      return true;
    });

  const tables = names(/create table if not exists public\.([a-z_]+)/g);
  const functions = names(/create or replace function public\.([a-z_]+)/g);

  for (const t of tables.slice(-2)) rows.push({ part, kind: "table", name: t });
  for (const f of functions.slice(-3)) rows.push({ part, kind: "function", name: f });
});

const values = rows
  .map((r) => `  (${r.part}, 'part ${r.part} of ${total}', '${r.kind}', '${r.name}')`)
  .join(",\n");

writeFileSync(
  CHECK_FILE,
  `with marker(part, label, kind, name) as (values\n${values}\n)
select m.part,
       m.label,
       m.kind || ' ' || m.name as object,
       case when m.kind = 'table'
                 then to_regclass('public.' || m.name) is not null
            else exists (select 1 from pg_proc p
                           join pg_namespace n on n.oid = p.pronamespace
                          where n.nspname = 'public' and p.proname = m.name)
       end as present
  from marker m
 order by m.part, m.name;
`,
);

console.log(`\nwrote ${written.length} part(s) to ${OUT_DIR}/\n`);
for (const w of written) {
  console.log(`  ${w.name.padEnd(20)} ${String(w.files).padStart(2)} migrations  ${String(w.kb).padStart(4)} KB`);
}
console.log("");
