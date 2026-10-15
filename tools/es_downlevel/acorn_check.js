// exit 0 when <file> parses at the given ECMAScript level, 1 otherwise.
//
//   node acorn_check.js <ecmaVersion> <file>
//
// ecmaVersion 2018 == what Chrome 66 (the Android 9 TV box WebView) understands.
// ecmaVersion 2022 == everything js_downlevel.dart is allowed to emit.
const acorn = require("acorn");
const fs = require("fs");

const ver = parseInt(process.argv[2], 10);
const file = process.argv[3];
const code = fs.readFileSync(file, "utf8");

let lastErr = null;
for (const sourceType of ["script", "module"]) {
  try {
    acorn.parse(code, {
      ecmaVersion: ver,
      sourceType,
      allowHashBang: true,
      allowReturnOutsideFunction: true,
      locations: true,
    });
    process.exit(0);
  } catch (e) {
    lastErr = e;
  }
}
const line = code.split("\n")[(lastErr.loc && lastErr.loc.line) - 1] || "";
console.error(`parse FAIL at ES${ver}: ${lastErr.message}`);
if (line) console.error(`  ${line.slice(0, 160)}`);
process.exit(1);
