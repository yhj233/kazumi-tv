// Kitchen-sink fixture: every ES2020 construct the downleveler is expected to
// rewrite, plus a lot of decoys that must NOT be touched.
//
// The `?.`/`??` inside strings, regexes and comments below are decoys: a naive
// string replace would corrupt them. `run_checks.js` proves the transformed
// output still behaves identically to this original.

// decoy: a?.b ?? c inside a line comment
/* decoy block comment: x?.y ?? z */
const DECOY_STR = "a?.b ?? c";
const DECOY_STR2 = 'q?.[0]';
const DECOY_RE = /a?\.b/;      // decoy regex
const DECOY_RE2 = /[?][.]/;    // decoy regex with class

console.log('decoy-str', DECOY_STR, DECOY_STR2);
console.log('decoy-re', DECOY_RE.test('aXb'), DECOY_RE2.test('?.'));

// --- optional chaining ------------------------------------------------------
const deep = { a: { b: { c: 42 } } };
console.log('chain', deep?.a?.b?.c, deep?.x?.y, deep.a?.b.c, deep?.a?.b?.z);

const arr = [{ k: 'K' }, null];
console.log('subscript', arr?.[0]?.k, arr?.[1]?.k, arr?.[9]?.k, arr?.['0']?.k);

let fn = (x) => 'fn:' + x;
console.log('opt-call', fn?.(1));
fn = null;
console.log('opt-call-null', fn?.(1));

const holder = { v: 7, m() { return this.v; } };
console.log('this-binding', holder.m?.());
const empty = { v: 8 };
console.log('this-binding-missing', empty.m?.());

// --- nullish coalescing -----------------------------------------------------
const a = null, b = 0, c = '', d = false;
console.log('nullish', a ?? 'A', b ?? 'B', c ?? 'C', d ?? 'D');
console.log('nullish-mixed', a ?? b + 1, b ?? 1 + 2);
console.log('nullish-ternary', (a ?? b) ? 'T' : 'F', a ?? b ? 'T' : 'F');
console.log('nullish-args', [a ?? 1, b ?? 2].join('|'));
console.log('nullish-nested', { v: a ?? (b ?? 'deep') }.v);

// --- logical assignment -----------------------------------------------------
let o1 = 0, o2 = 1, o3 = null, o4 = 'keep';
o1 ||= 'or'; o2 ||= 'or';
o1 &&= 'and'; o2 &&= 'and';
o3 ??= 'nul'; o4 ??= 'nul';
console.log('logical-assign', o1, o2, o3, o4);

const target = { x: null, y: 5 };
target.x ??= 'set';
target.y ??= 'not-set';
console.log('logical-assign-member', target.x, target.y);

// --- template substitution (code inside ${} must be rewritten) --------------
const tplNull = null;
console.log('template', `v=${tplNull?.y ?? 'd'}|${deep?.a?.b?.c}`);

// --- ternary + number must not be confused with `?.` ------------------------
const flag = 0;
console.log('ternary-dot', flag ? .5 : 1, deep ? 2.5 : 3);

// --- inside arrow / array / object literals ---------------------------------
const make = () => deep?.a?.b?.c ?? -1;
console.log('arrow', make(), [deep?.a?.b?.c].join(','), { k: deep?.x?.y ?? 'u' }.k);

// --- optional chaining used as a callee through a subscript -----------------
const mapObj = { f: (n) => n * 2 };
console.log('subscript-call', mapObj?.['f']?.(3));
