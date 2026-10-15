// Faithful reproduction of the exact statement that broke the player on the
// Android 9 box.
//
// Real source: https://xcdn.khfed.com:8443/jx/20230723ver/Play/artplayer.min.js
// (line 7, a 165 KB single-line minified bundle):
//
//   ...(0,h.errorHandle)(t,`Can't find [${e}] from the [setting]`);
//   const r=t.$parentItem?.selector||this.option;
//   return r.splice(r.indexOf(t),1),this.option
//
// Chrome 66 (com.android.webview 66.0.3359.158) does not support optional
// chaining, so V8 threw "Uncaught SyntaxError: Unexpected token ." AT PARSE TIME
// and discarded the whole 165 KB file. ArtPlayer was therefore never defined,
// the page never created a <video> element, and m3u8 sniffing timed out at 13 s.
// acorn confirms it: parsing this file at ecmaVersion 2018 fails with
// "Unexpected token (7:147582)" - the same offset Chromium reported.
//
// This fixture is runnable so the transformed output can be compared with the
// original behaviourally.
function pickOption(parentItem, option) {
  const r = parentItem?.selector || option;
  return r;
}

function show(label, parentItem, option) {
  let out;
  try {
    out = JSON.stringify(pickOption(parentItem, option));
  } catch (e) {
    out = 'threw:' + e.name;
  }
  console.log(label, out);
}

show('normal', { selector: ['a', 'b'] }, ['fallback']);
show('nullish-parent', null, ['fallback']);
show('undefined-parent', undefined, ['fallback']);
show('nullish-selector', { selector: null }, ['fallback']);
show('nested-parent', { $parentItem: { selector: ['x'] }, option: ['o'] }
  .$parentItem, ['fallback']);

// the original line, in the original shape
const t = { $parentItem: { selector: ['first', 'second'] }, option: ['opt'] };
const r = t.$parentItem?.selector || t.option;
console.log('selector-chain', JSON.stringify(r));
