import fs from "node:fs";
import path from "node:path";

const ROOT = process.cwd();
const WF_DIR = path.join(ROOT, "workflows");
const EXAMPLES_DIR = path.join(ROOT, "n8n examples");
const SCRIPTS_DIR = path.join(ROOT, "scripts");

const FORBIDDEN_SUBSTRINGS = ["$" + "env."];

function fail(msg) {
  console.error(msg);
  process.exitCode = 1;
}

function readJsonFiles(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .map((f) => path.join(dir, f));
}

function readFilesByExt(dir, ext) {
  if (!fs.existsSync(dir)) return [];
  return fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(ext))
    .map((f) => path.join(dir, f));
}

function checkForbiddenStrings(file, text) {
  for (const s of FORBIDDEN_SUBSTRINGS) {
    if (text.includes(s)) {
      fail(`[FAIL] ${file}: forbidden substring "${s}" found`);
    }
  }
}

function startsWithDbRoPrefix(name) {
  return /^DB RO\s*[—-]\s+/.test(String(name || ""));
}

function isReadOnlySql(sql) {
  if (!sql || typeof sql !== "string") return false;
  const s = sql.trim();

  if (!/^(select|with)\b/i.test(s)) return false;
  if (s.includes(";")) return false;

  if (/\b(insert|update|delete|merge|alter|drop|create|truncate|grant|revoke|vacuum|analyze)\b/i.test(s)) {
    return false;
  }

  return true;
}

function checkPostgresExecutePolicy(file, wf) {
  const nodes = wf?.nodes ?? [];
  for (const node of nodes) {
    const type = String(node?.type ?? "").toLowerCase();
    if (!type.includes("postgres")) continue;

    const name = String(node?.name ?? "");
    const params = node?.parameters ?? {};
    const operation = String(params?.operation ?? "").trim().toLowerCase();

    const isExecute = operation.includes("execute");
    if (!isExecute) continue;

    if (!startsWithDbRoPrefix(name)) {
      fail(
        `[FAIL] ${file}: postgres executeQuery node "${name}" must use prefix "DB RO - " or "DB RO — "`
      );
      continue;
    }

    const sqlCandidates = [
      params?.query,
      params?.options?.query,
      params?.executeQuery,
      params?.sql,
      params?.queryParameters,
    ].filter((v) => typeof v === "string");

    const sql = sqlCandidates.length > 0 ? sqlCandidates[0] : "";
    if (!isReadOnlySql(sql)) {
      fail(
        `[FAIL] ${file}: postgres node "${name}" executeQuery must be read-only SELECT/WITH without semicolons or DML/DDL keywords`
      );
    }
  }
}

function validateJsonWorkflows() {
  const files = readJsonFiles(WF_DIR);
  if (!files.length) {
    console.log("[OK] No workflows/*.json found (skipping)");
    return;
  }

  for (const file of files) {
    const text = fs.readFileSync(file, "utf8");
    checkForbiddenStrings(file, text);

    let wf;
    try {
      wf = JSON.parse(text);
    } catch (err) {
      fail(`[FAIL] ${file}: invalid JSON (${err.message})`);
      continue;
    }

    checkPostgresExecutePolicy(file, wf);
  }
}

function validateExamplesAndScripts() {
  const files = [
    ...readJsonFiles(EXAMPLES_DIR),
    ...readFilesByExt(SCRIPTS_DIR, ".mjs"),
    ...readFilesByExt(SCRIPTS_DIR, ".sh"),
  ];

  for (const file of files) {
    const text = fs.readFileSync(file, "utf8");
    checkForbiddenStrings(file, text);
  }
}

function main() {
  validateJsonWorkflows();
  validateExamplesAndScripts();

  if (process.exitCode) process.exit(1);
  console.log("[OK] workflows validation passed");
}

main();
