import fs from "node:fs";
import path from "node:path";

const ROOT = process.cwd();
const WF_DIR = path.join(ROOT, "workflows");

const FORBIDDEN_SUBSTRINGS = [
  "$env.", // ваше правило
];

function walkJson(obj, fn, p = "") {
  if (Array.isArray(obj)) {
    obj.forEach((v, i) => walkJson(v, fn, `${p}[${i}]`));
  } else if (obj && typeof obj === "object") {
    for (const [k, v] of Object.entries(obj)) {
      walkJson(v, fn, p ? `${p}.${k}` : k);
    }
  } else {
    fn(obj, p);
  }
}

function fail(msg) {
  console.error(msg);
  process.exitCode = 1;
}

function readWorkflows() {
  if (!fs.existsSync(WF_DIR)) return [];
  return fs.readdirSync(WF_DIR)
    .filter(f => f.endsWith(".json"))
    .map(f => path.join(WF_DIR, f));
}

function checkForbiddenStrings(file, text) {
  for (const s of FORBIDDEN_SUBSTRINGS) {
    if (text.includes(s)) fail(`[FAIL] ${file}: forbidden substring "${s}" found`);
  }
}

function isReadOnlySql(sql) {
  if (!sql || typeof sql !== "string") return false;
  const s = sql.trim();

  // Must start with SELECT or WITH
  if (!/^(select|with)\b/i.test(s)) return false;

  // No statement chaining
  if (s.includes(";")) return false;

  // No write / ddl keywords
  if (/\b(insert|update|delete|merge|alter|drop|create|truncate|grant|revoke|vacuum|analyze)\b/i.test(s)) {
    return false;
  }

  return true;
}

function checkPostgresExecutePolicy(file, wf) {
  const nodes = wf?.nodes ?? [];
  for (const n of nodes) {
    const type = n?.type ?? "";
    if (!type.includes("postgres")) continue;

    const name = n?.name ?? "";
    const params = n?.parameters ?? {};
    const op = String(params?.operation ?? "").trim();
    const query =
      params?.query ??
      params?.options?.query ??
      params?.executeQuery ??
      params?.sql ??
      "";

    const isExecute = op.toLowerCase().includes("execute");

    if (!isExecute) continue;

    // Allow only DB RO — nodes with read-only SQL
    const allowedByName = name.startsWith("DB RO —");
    if (!allowedByName) {
      fail(`[FAIL] ${file}: postgres node "${name}" uses operation "${op}" but node name is not prefixed with "DB RO —"`);
      continue;
    }

    if (!isReadOnlySql(String(query))) {
      fail(`[FAIL] ${file}: postgres node "${name}" uses executeQuery but SQL is not read-only SELECT/WITH (or contains forbidden patterns)`);
      continue;
    }
  }
}

function main() {
  const files = readWorkflows();
  if (files.length === 0) {
    console.log("[OK] No workflows/*.json found (skipping)");
    return;
  }

  for (const file of files) {
    const text = fs.readFileSync(file, "utf8");
    checkForbiddenStrings(file, text);

    let wf;
    try {
      wf = JSON.parse(text);
    } catch (e) {
      fail(`[FAIL] ${file}: invalid JSON (${e.message})`);
      continue;
    }

    checkPostgresExecutePolicy(file, wf);
  }

  if (process.exitCode) process.exit(1);
  console.log("[OK] workflows validation passed");
}

main();
