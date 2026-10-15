// Negative test fixture: every receiver here is side-effecting, so the
// downleveler MUST refuse to duplicate it and leave the file byte-for-byte
// unchanged. Corrupting a working script is worse than leaving a broken one,
// so this is the guard against over-eager rewriting.
//
// run_checks.js asserts that the transformed output of this file is identical
// to the input and that the downleveler reported skipped constructs.

const obj = { get: () => ({ x: 1 }) };
const arr = [1, 2, 3];
let i = 0;

class Box {
  constructor() {
    this.x = 1;
  }
}

// `obj.get()?.x` - duplicating the receiver would call get() twice
void obj.get()?.x;

// `arr[i++]?.x` - duplicating the receiver would increment twice
void arr[i++]?.x;

// `new Box()?.x` - `new` as the chain head is not handled
void new Box()?.x;

console.log('unsafe-receivers still loads');
