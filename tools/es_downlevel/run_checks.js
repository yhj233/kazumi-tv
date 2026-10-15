#!/usr/bin/env node
// Verify the shipped implementation of the ES2020 downleveler.
//
//   node tools/es_downlevel/run_checks.js
//
// What it proves, using the real lib/webview/video/js_downlevel.dart (driven by
// dart_check.dart) plus the acorn parser and node itself:
//
//   1. every rewritten output still PARSES, both at ES2018 (the grammar the
//      Android 9 box's Chrome 66 actually implements) and at ES2022 (so we never
//      emit something invalid on modern engines either)
//   2. every rewritten output BEHAVES identically to the original under node
//   3. cases that contain no ES2020 construct are left byte-for-byte untouched
//   4. cases that do contain one are actually rewritten
//   5. nothing the downleveler is not confident about is rewritten - the
//      side-effecting fixtures must come out byte-for-byte identical, with the
//      impossible cases reported as skipped
//
// exit code 0 = all good, 1 = at least one check failed.
"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync, spawnSync } = require("child_process");

const HERE = __dirname;
const REPO = path.resolve(HERE, "..", "..");
const ACORN = path.join(HERE, "acorn_check.js");
const OUT = path.join(REPO, "es_downlevel_out");

const failures = [];
const rows = [];

function fail(msg) {
  failures.push(msg);
}

function acornOk(file, version) {
  const p = spawnSync(process.execPath, [ACORN, String(version), file], {
    encoding: "utf8",
  });
  return { ok: p.status === 0, out: (p.stderr || "").trim() };
}

function runNode(file) {
  const p = spawnSync(process.execPath, [file], { encoding: "utf8" });
  return { rc: p.status, out: p.stdout || "", err: (p.stderr || "").trim() };
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "esdl-"));

// --------------------------------------------------------------------------- //
// 1. run the real Dart implementation
// --------------------------------------------------------------------------- //
// ES_DOWNLEVEL_RUNNER is a JSON array overriding the command used to execute
// dart_check.dart. The default is the real SDK; the porting workspace points it
// at a Python stand-in to dry-run this whole pipeline on a machine that has no
// Dart SDK. CI never sets it.
const runner = process.env.ES_DOWNLEVEL_RUNNER
  ? JSON.parse(process.env.ES_DOWNLEVEL_RUNNER)
  : ["dart"];
if (!Array.isArray(runner) || !runner.length) {
  console.error("ES_DOWNLEVEL_RUNNER must be a non-empty JSON array");
  process.exit(1);
}
console.log(`running: ${runner.join(" ")} ${path.join(HERE, "dart_check.dart")}`);
try {
  const out = execFileSync(
    runner[0],
    [...runner.slice(1), path.join(HERE, "dart_check.dart"), OUT],
    {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  process.stdout.write(out);
} catch (e) {
  console.error("dart_check.dart failed:");
  console.error(e.stdout || "");
  console.error(e.stderr || "");
  console.error(e.message);
  process.exit(1);
}

const report = JSON.parse(fs.readFileSync(path.join(OUT, "report.json"), "utf8"));
const cases = JSON.parse(fs.readFileSync(path.join(HERE, "cases.json"), "utf8"));

function checkItem(item, originalSource, label) {
  if (item.error) {
    fail(`${label}: ${item.error}`);
    return null;
  }
  const outPath = item.outPath;
  const unsafe = String(item.name).startsWith("unsafe-");

  // (1) parse checks
  const p2018 = acornOk(outPath, 2018);
  const p2022 = acornOk(outPath, 2022);
  if (!p2022.ok) fail(`${label}: output is not valid ES2022 -> ${p2022.out}`);
  if (unsafe) {
    if (p2018.ok) {
      fail(`${label}: fixture is supposed to stay ES2020-only but parses as ES2018`);
    }
  } else if (!p2018.ok) {
    fail(`${label}: output still does not parse at ES2018 -> ${p2018.out}`);
  }

  // (2) behaviour comparison
  let same = null;
  if (originalSource !== null) {
    const origFile = path.join(tmp, `${label.replace(/[^\w.-]/g, "_")}.orig.js`);
    fs.writeFileSync(origFile, originalSource);
    const a = runNode(origFile);
    const b = runNode(outPath);
    same = a.rc === b.rc && a.out === b.out;
    if (!same) {
      fail(`${label}: behaviour differs\n      orig rc=${a.rc} out=${JSON.stringify(a.out)}\n      new  rc=${b.rc} out=${JSON.stringify(b.out)}\n      stderr=${b.err.slice(0, 300)}`);
    }
  }

  // (3)(4)(5) change / identity expectations
  const skipped = (item.skipped || []).length;
  if (item.kind === "case") {
    if (Boolean(item.expectChange) !== Boolean(item.changed)) {
      fail(`${label}: expectChange=${item.expectChange} but changed=${item.changed}`);
    }
    if (skipped !== 0) fail(`${label}: unexpected skipped constructs ${JSON.stringify(item.skipped)}`);
  } else {
    if (unsafe) {
      if (!item.identical) {
        fail(`${label}: side-effecting receiver was rewritten - output must be identical`);
      }
      if (skipped === 0) fail(`${label}: expected the impossible cases to be reported as skipped`);
    } else {
      if (skipped !== 0) fail(`${label}: unexpected skipped constructs ${JSON.stringify(item.skipped)}`);
      if (!item.changed) fail(`${label}: expected a rewrite, got none`);
    }
  }

  rows.push({
    label,
    changed: item.changed,
    skipped,
    es2018: p2018.ok ? "ok" : "-",
    es2022: p2022.ok ? "ok" : "FAIL",
    behaviour: same === null ? "-" : same ? "same" : "DIFF",
  });
  return item;
}

// --------------------------------------------------------------------------- //
// 2. corpus
// --------------------------------------------------------------------------- //
const caseByName = new Map(cases.cases.map((c) => [c.name, c]));
for (const item of report) {
  if (item.kind !== "case") continue;
  const src = caseByName.get(item.name);
  checkItem(item, src ? src.code : null, `case/${item.name}`);
}

// --------------------------------------------------------------------------- //
// 3. fixtures
// --------------------------------------------------------------------------- //
for (const item of report) {
  if (item.kind !== "sample") continue;
  // always compare against the pristine fixture on disk
  const src = fs.readFileSync(path.join(HERE, "samples", item.name), "utf8");
  checkItem(item, src, `sample/${item.name}`);
}

// --------------------------------------------------------------------------- //
// 4. report
// --------------------------------------------------------------------------- //
const w = Math.max(12, ...rows.map((r) => r.label.length));
console.log("");
console.log(
  "result".padEnd(w) +
    "changed  skipped  ES2018  ES2022  behaviour",
);
console.log("-".repeat(w + 43));
for (const r of rows) {
  console.log(
    r.label.padEnd(w) +
      String(r.changed).padEnd(9) +
      String(r.skipped).padEnd(9) +
      r.es2018.padEnd(8) +
      r.es2022.padEnd(8) +
      r.behaviour,
  );
}

console.log("");
if (failures.length) {
  console.log(`### ${failures.length} FAILURE(S)`);
  for (const f of failures) console.log("  - " + f);
  process.exit(1);
}
console.log(`### ALL ${rows.length} CHECKS PASSED`);
console.log("    (dart output + report kept in es_downlevel_out/)");
