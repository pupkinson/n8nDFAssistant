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

function checkPostgresNoExecuteQuery(file, wf) {
  const nodes = wf?.nodes ?? [];
  for (const n of nodes) {
    const type = n?.type ?? "";
    // эвристика: Postgres node
    if (type.includes("postgres")) {
      const params = n?.parameters ?? {};
      const op = params?.operation ?? "";
      const query = params?.query ?? params?.options?.query ?? "";
      if (String(op).toLowerCase().includes("execute")) {
        fail(`[FAIL] ${file}: postgres node "${n.name}" uses operation "${op}" (executeQuery forbidden)`);
      }
      if (typeof query === "string" && query.trim().length > 0) {
        // если вы вообще запрещаете произвольный SQL — включите это правило
        // fail(`[FAIL] ${file}: postgres node "${n.name}" contains raw SQL in parameters (forbidden)`);
      }
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

    checkPostgresNoExecuteQuery(file, wf);
  }

  if (process.exitCode) process.exit(1);
  console.log("[OK] workflows validation passed");
}

main();
