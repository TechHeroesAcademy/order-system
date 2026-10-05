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

console.log(`\nwrote ${written.length} part(s) to ${OUT_DIR}/\n`);
for (const w of written) {
  console.log(`  ${w.name.padEnd(20)} ${String(w.files).padStart(2)} migrations  ${String(w.kb).padStart(4)} KB`);
}
console.log("");
