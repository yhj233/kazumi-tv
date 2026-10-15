import 'dart:convert';
import 'dart:typed_data';

/// ES2020 -> ES5 downlevel transformer for old Android WebViews.
///
/// Why this exists
/// ---------------
/// The Android 9 TV box runs `com.android.webview 66.0.3359.158` (Chrome 66,
/// ES2018). Modern player bundles ship optional chaining (`?.`, Chrome 80+) and
/// nullish coalescing (`??`, Chrome 80+). Those are **syntax** errors on an old
/// V8, so the whole script is discarded before a single line runs - a single
/// `?.` inside a 165 KB minified bundle is enough to kill the player, which then
/// never creates a `<video>` element and the sniffing times out.
///
/// Measured on the failing AGE source (agedm.io -> jx.wuzhoupai.com player):
///   artplayer.min.js  parse at ES2018: FAIL  Unexpected token (7:147582)
///                     the offending code:  t.$parentItem?.selector||this.option
///   7 of the 8 scripts on that page were already Chrome-66 clean.
///
/// What this does
/// --------------
///     a?.b            ->  (a == null ? void 0 : a.b)
///     a?.b?.c         ->  (a == null ? void 0 : (a.b == null ? void 0 : a.b.c))
///     a??.[i]         ->  (a == null ? void 0 : a[i])
///     a?.()           ->  (a == null ? void 0 : a())
///     a ?? b          ->  ((a) !== null && (a) !== void 0 ? (a) : (b))
///     a ||= b         ->  ((a) || (a = b))
///     a &&= b         ->  ((a) && (a = b))
///     a ??= b         ->  ((a) !== null && (a) !== void 0 ? (a) : (a = b))
///
/// Safety rules (fail-safe: anything not understood is left untouched)
/// ------------------------------------------------------------------
/// * Only *pure* receivers are duplicated. A receiver containing a call
///   (`f()?.x`) or an in-place mutation (`a[i++]?.x`) is rejected, so a function
///   is never invoked twice. Property reads may invoke a getter twice - accepted,
///   because duplicating the text is what keeps `obj.method?.()`'s `this`
///   binding intact.
/// * Strings, regexes, comments and template chunks are tokenized opaquely; code
///   inside `${ ... }` substitutions IS scanned.
/// * A file that is not valid UTF-8 is skipped entirely (we never hand WebView
///   bytes we produced from a lossy decode).
///
/// The algorithm is validated against acorn at ecmaVersion 2018 plus runtime
/// equivalence checks under node - see verify_downlevel.py / js_downlevel_proto.py
/// in the porting workspace.
class JsDownlevelStats {
  int optionalChaining = 0;
  int nullish = 0;
  int logicalAssign = 0;
  final List<String> skipped = <String>[];

  bool get changed =>
      optionalChaining > 0 || nullish > 0 || logicalAssign > 0;

  String get summary =>
      '?.=$optionalChaining ??=$nullish logical-assign=$logicalAssign '
      'skipped=${skipped.length}';
}

class JsDownlevelResult {
  /// Transformed source, or null when nothing needed changing.
  final String? code;
  final JsDownlevelStats stats;

  const JsDownlevelResult(this.code, this.stats);
}

class JsDownlevel {
  JsDownlevel._();

  /// Skip anything absurd - player bundles are well under this.
  static const int maxBytes = 8 * 1024 * 1024;

  static const int _kMaxRewrites = 200000;

  /// `a ?? b ?? c ?? d` needs one pass per nesting level; a small cap is only
  /// here so a future change can never spin forever.
  static const int _kMaxPasses = 8;

  // token kinds
  static const int _ws = 0;
  static const int _comment = 1;
  static const int _str = 2;
  static const int _tmpl = 3;
  static const int _regex = 4;
  static const int _num = 5;
  static const int _id = 6;
  static const int _punc = 7;

  static const Set<String> _regexAfterId = <String>{
    'return', 'typeof', 'instanceof', 'in', 'of', 'new', 'delete', 'void',
    'throw', 'case', 'do', 'else', 'yield', 'await', 'default', 'extends',
  };

  static const Set<String> _regexAfterPunc = <String>{
    '(', ',', '=', ':', '[', '!', '&', '|', '?', '{', '}', ';', '+', '-', '*',
    '%', '~', '^', '<', '>',
  };

  static const List<String> _punct3 = <String>[
    '??=', '...', '===', '!==', '**=', '<<=', '>>=', '||=', '&&=', '>>>',
  ];
  static const List<String> _punct2 = <String>[
    '?.', '??', '=>', '==', '!=', '<=', '>=', '+=', '-=', '*=', '/=', '%=',
    '&=', '|=', '^=', '++', '--', '&&', '||', '**', '<<', '>>',
  ];

  static const Set<String> _boundaryLeft = <String>{
    ',', ';', '(', '[', '{', ':', '?', '=', '=>', '??=', '||=', '&&=', '+=',
    '-=', '*=', '/=', '%=', '&=', '|=', '^=', '**=',
  };
  static const Set<String> _boundaryLeftId = <String>{
    'return', 'yield', 'case', 'throw', 'typeof', 'void', 'delete', 'in', 'of',
    'new',
  };
  static const Set<String> _boundaryRightOp = <String>{
    ',', ';', ')', ']', '}', ':', '?',
  };
  static const Set<String> _boundaryRightAssign = <String>{
    ',', ';', ')', ']', '}',
  };

  // ---------------------------------------------------------------------------
  // public entry points
  // ---------------------------------------------------------------------------

  /// Does this URL look like a JavaScript resource?
  static bool urlLooksLikeScript(String url) {
    final String path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    return path.endsWith('.js') ||
        path.endsWith('.mjs') ||
        path.endsWith('.cjs');
  }

  /// Downlevel `bytes` if it is valid UTF-8 and actually needs it.
  /// Returns null when the caller should just serve the original bytes.
  static Uint8List? downlevelBytes(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) return null;
    final String source;
    try {
      source = utf8.decode(bytes);
    } catch (_) {
      return null; // not valid UTF-8 -> never touch it
    }
    final String? out = transform(source).code;
    if (out == null) return null;
    try {
      return Uint8List.fromList(utf8.encode(out));
    } catch (_) {
      return null;
    }
  }

  /// Rewrite one script source. `code` is null when nothing was rewritten.
  ///
  /// A single left-to-right pass finishes every independent construct, but
  /// `a ?? b ?? c` nests one inside another: the first `??` claims `b ?? c` as
  /// its right operand, so the inner one survives the pass and `_singlePass`
  /// reports that by setting `innerSkipped`. Repeat until it stops happening,
  /// which for a real bundle is essentially always one pass.
  static JsDownlevelResult transform(String source) {
    final JsDownlevelStats stats = JsDownlevelStats();
    String src = source;
    for (int pass = 0; pass < _kMaxPasses; pass++) {
      final _PassResult r = _singlePass(src, stats);
      src = r.source;
      if (!r.changed || !r.innerSkipped) break;
    }
    return JsDownlevelResult(stats.changed ? src : null, stats);
  }

  /// One left-to-right pass over [source], accumulating into [stats].
  ///
  /// A construct this pass cannot reach - because it sits inside a range a
  /// sibling rewrite already claimed - is never guessed at; it is simply left
  /// alone and reported through `innerSkipped` so [transform] can retry.
  static _PassResult _singlePass(String source, JsDownlevelStats stats) {
    final List<_Tok> toks = _tokenize(source);
    final List<_Tok> sig = _significant(toks);

    final List<_Splice> splices = <_Splice>[];
    int consumedEnd = -1;
    bool innerSkipped = false;
    int rewrites = 0;

    for (int k = 0; k < sig.length; k++) {
      final _Tok t = sig[k];
      if (t.kind != _punc) continue;

      final String txt = source.substring(t.start, t.end);
      if (txt != '?.' &&
          txt != '??' &&
          txt != '??=' &&
          txt != '||=' &&
          txt != '&&=') {
        continue;
      }

      // Inside a range this same pass already rewrote: the construct is real,
      // we simply cannot reach it yet, so ask for another pass.
      if (t.start < consumedEnd) {
        innerSkipped = true;
        continue;
      }

      String? repl;
      int start = 0;
      int end = 0;

      try {
        if (txt == '?.') {
          if (k + 1 >= sig.length) continue;
          final _Tok nxt = sig[k + 1];
          if (nxt.kind == _num && _isDigit(source.codeUnitAt(nxt.start))) {
            continue; // `a ? .5 : b` - a ternary, not optional chaining
          }
          final _ChainRewrite r = _rewriteOptionalChain(source, sig, k);
          repl = r.text;
          start = r.start;
          end = r.end;
        } else if (txt == '??') {
          final _OpRewrite r = _rewriteNullish(source, sig, k);
          repl = r.text;
          start = r.start;
          end = r.end;
        } else {
          final _OpRewrite r = _rewriteLogicalAssign(source, sig, k);
          repl = r.text;
          start = r.start;
          end = r.end;
        }
      } on _Unsupported catch (e) {
        final String entry = '$txt: ${e.reason}';
        if (!stats.skipped.contains(entry)) stats.skipped.add(entry);
        continue;
      }

      // A rewrite's own span can reach back into a range this pass has already
      // emitted: in `o?.a ?? b` the `?.` chain is rewritten first and the `??`
      // then wants its left operand to begin inside that replacement. Emitting
      // both would make the splices overlap and one would be silently dropped,
      // so hold this construct for the next pass instead.
      if (start < consumedEnd) {
        innerSkipped = true;
        continue;
      }

      if (txt == '?.') {
        stats.optionalChaining++;
      } else if (txt == '??') {
        stats.nullish++;
      } else {
        stats.logicalAssign++;
      }

      splices.add(_Splice(start, end, repl));
      consumedEnd = end;
      rewrites++;
      if (rewrites > _kMaxRewrites) break;
    }

    if (splices.isEmpty) return _PassResult(source, false, innerSkipped);

    final StringBuffer out = StringBuffer();
    int cursor = 0;
    for (final _Splice s in splices) {
      if (s.start < cursor) continue;
      out.write(source.substring(cursor, s.start));
      out.write(s.replacement);
      cursor = s.end;
    }
    out.write(source.substring(cursor));
    return _PassResult(out.toString(), true, innerSkipped);
  }

  // ---------------------------------------------------------------------------
  // tokenizer
  // ---------------------------------------------------------------------------

  static bool _isWs(int c) =>
      c == 0x20 ||
      c == 0x09 ||
      c == 0x0a ||
      c == 0x0d ||
      c == 0x0c ||
      c == 0x0b ||
      c == 0xa0;

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  static bool _isIdStart(int c) =>
      (c >= 0x41 && c <= 0x5a) ||
      (c >= 0x61 && c <= 0x7a) ||
      c == 0x5f ||
      c == 0x24 ||
      c >= 0x80;

  static bool _isIdPart(int c) =>
      _isIdStart(c) || _isDigit(c);

  static List<_Tok> _tokenize(String src) {
    final List<_Tok> toks = <_Tok>[];
    final int n = src.length;
    int i = 0;
    _Tok? prev;
    int braceDepth = 0;
    final List<int> substStack = <int>[];

    void push(int kind, int start, int end) {
      final _Tok t = _Tok(kind, start, end);
      toks.add(t);
      if (kind != _ws && kind != _comment) prev = t;
    }

    while (i < n) {
      final int c = src.codeUnitAt(i);

      if (_isWs(c)) {
        int j = i;
        while (j < n && _isWs(src.codeUnitAt(j))) {
          j++;
        }
        push(_ws, i, j);
        i = j;
        continue;
      }

      // comments
      if (c == 0x2f && i + 1 < n && src.codeUnitAt(i + 1) == 0x2f) {
        int j = src.indexOf('\n', i);
        if (j < 0) j = n;
        push(_comment, i, j);
        i = j;
        continue;
      }
      if (c == 0x2f && i + 1 < n && src.codeUnitAt(i + 1) == 0x2a) {
        int j = src.indexOf('*/', i + 2);
        j = j < 0 ? n : j + 2;
        push(_comment, i, j);
        i = j;
        continue;
      }

      // strings
      if (c == 0x27 || c == 0x22) {
        int j = i + 1;
        while (j < n) {
          final int ch = src.codeUnitAt(j);
          if (ch == 0x5c) {
            j += 2;
            continue;
          }
          if (ch == c) {
            j++;
            break;
          }
          if (ch == 0x0a) break;
          j++;
        }
        push(_str, i, j);
        i = j;
        continue;
      }

      // template chunk: starts at '`' or at the '}' closing a `${ ... }`
      if (c == 0x60 ||
          (c == 0x7d &&
              substStack.isNotEmpty &&
              braceDepth == substStack.last)) {
        int j = i + 1;
        bool closed = false;
        while (j < n) {
          final int ch = src.codeUnitAt(j);
          if (ch == 0x5c) {
            j += 2;
            continue;
          }
          if (ch == 0x60) {
            j++;
            closed = true;
            break;
          }
          if (ch == 0x24 && j + 1 < n && src.codeUnitAt(j + 1) == 0x7b) break;
          j++;
        }
        final bool endsOnSubst = !closed &&
            j + 1 < n &&
            src.codeUnitAt(j) == 0x24 &&
            src.codeUnitAt(j + 1) == 0x7b;
        if (!closed && !endsOnSubst) {
          push(_tmpl, i, n);
          i = n;
          continue;
        }
        if (closed) {
          push(_tmpl, i, j);
          if (c == 0x7d) substStack.removeLast();
          i = j;
          continue;
        }
        push(_tmpl, i, j + 2);
        if (c == 0x7d) substStack.removeLast();
        substStack.add(braceDepth);
        prev = null; // a '/' right after `${` starts a regex
        i = j + 2;
        continue;
      }

      // regex literal or division
      if (c == 0x2f) {
        // `prev` is written from inside the local `push` helper below, and a
        // variable assigned in a closure is never type-promoted; take a final
        // alias so the null check below actually narrows the type.
        final _Tok? previous = prev;
        bool allowRegex = true;
        if (previous != null) {
          if (previous.kind == _punc) {
            allowRegex = _regexAfterPunc
                .contains(src.substring(previous.start, previous.end));
          } else if (previous.kind == _id) {
            allowRegex = _regexAfterId
                .contains(src.substring(previous.start, previous.end));
          } else {
            allowRegex = false;
          }
        }
        if (allowRegex) {
          int j = i + 1;
          bool inClass = false;
          bool ok = false;
          while (j < n) {
            final int ch = src.codeUnitAt(j);
            if (ch == 0x5c) {
              j += 2;
              continue;
            }
            if (ch == 0x0a) break;
            if (inClass) {
              if (ch == 0x5d) inClass = false;
            } else if (ch == 0x5b) {
              inClass = true;
            } else if (ch == 0x2f) {
              j++;
              ok = true;
              break;
            }
            j++;
          }
          if (ok && (j - i) < 1000) {
            push(_regex, i, j);
            i = j;
            continue;
          }
        }
        push(_punc, i, i + 1);
        i++;
        continue;
      }

      // numbers
      if (_isDigit(c) ||
          (c == 0x2e && i + 1 < n && _isDigit(src.codeUnitAt(i + 1)))) {
        int j = i;
        bool radix = false;
        if (i + 1 < n && src.codeUnitAt(i) == 0x30) {
          final int second = src.codeUnitAt(i + 1) | 0x20;
          radix = second == 0x78 || second == 0x62 || second == 0x6f;
        }
        if (radix) {
          j = i + 2;
          while (j < n &&
              (_isIdPart(src.codeUnitAt(j)) || src.codeUnitAt(j) == 0x5f)) {
            j++;
          }
        } else {
          while (j < n &&
              (_isDigit(src.codeUnitAt(j)) || src.codeUnitAt(j) == 0x5f)) {
            j++;
          }
          if (j < n && src.codeUnitAt(j) == 0x2e) {
            j++;
            while (j < n &&
                (_isDigit(src.codeUnitAt(j)) || src.codeUnitAt(j) == 0x5f)) {
              j++;
            }
          }
          if (j < n &&
              (src.codeUnitAt(j) == 0x65 || src.codeUnitAt(j) == 0x45)) {
            int m = j + 1;
            if (m < n &&
                (src.codeUnitAt(m) == 0x2b || src.codeUnitAt(m) == 0x2d)) {
              m++;
            }
            if (m < n && _isDigit(src.codeUnitAt(m))) {
              j = m;
              while (j < n &&
                  (_isDigit(src.codeUnitAt(j)) || src.codeUnitAt(j) == 0x5f)) {
                j++;
              }
            }
          }
        }
        if (j < n && src.codeUnitAt(j) == 0x6e) j++; // BigInt suffix
        push(_num, i, j);
        i = j;
        continue;
      }

      // identifiers / keywords
      if (_isIdStart(c)) {
        int j = i + 1;
        while (j < n && _isIdPart(src.codeUnitAt(j))) {
          j++;
        }
        push(_id, i, j);
        i = j;
        continue;
      }

      // punctuators / braces
      if (c == 0x7b) {
        braceDepth++;
        push(_punc, i, i + 1);
        i++;
        continue;
      }
      if (c == 0x7d) {
        braceDepth--;
        push(_punc, i, i + 1);
        i++;
        continue;
      }
      final String three = i + 3 <= n ? src.substring(i, i + 3) : '';
      if (_punct3.contains(three)) {
        push(_punc, i, i + 3);
        i += 3;
        continue;
      }
      final String two = i + 2 <= n ? src.substring(i, i + 2) : '';
      if (_punct2.contains(two)) {
        push(_punc, i, i + 2);
        i += 2;
        continue;
      }
      push(_punc, i, i + 1);
      i++;
    }

    return toks;
  }

  static List<_Tok> _significant(List<_Tok> toks) {
    final List<_Tok> out = <_Tok>[];
    for (final _Tok t in toks) {
      if (t.kind != _ws && t.kind != _comment) out.add(t);
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // optional chaining
  // ---------------------------------------------------------------------------

  /// Walk backwards from the `?.` at `pos` to find the receiver start offset.
  static int _findHead(String src, List<_Tok> sig, int pos) {
    int k = pos - 1;
    while (k >= 0) {
      final _Tok t = sig[k];
      final String txt = src.substring(t.start, t.end);
      if (t.kind == _punc && (txt == ')' || txt == ']')) {
        final int? open = _matchingOpen(src, sig, k, txt == ')' ? '(' : '[', txt);
        if (open == null) {
          throw const _Unsupported('unbalanced bracket before ?.');
        }
        k = open - 1;
        continue;
      }
      if (t.kind == _id || t.kind == _num || t.kind == _str) {
        final int j = k - 1;
        if (j >= 0) {
          final _Tok p = sig[j];
          final String ptxt = src.substring(p.start, p.end);
          if (p.kind == _punc && ptxt == '.') {
            k = j - 1;
            continue;
          }
          if (p.kind == _punc && ptxt == '?.') {
            throw const _Unsupported('chain head hides a previous ?.');
          }
          if (p.kind == _id && ptxt == 'new') {
            throw const _Unsupported('new expression as chain head');
          }
        }
        return t.start;
      }
      throw _Unsupported('unsupported chain head token $txt');
    }
    throw const _Unsupported('no chain head');
  }

  static int? _matchingOpen(
      String src, List<_Tok> sig, int pos, String openCh, String closeCh) {
    int depth = 0;
    for (int k = pos; k >= 0; k--) {
      final String txt = src.substring(sig[k].start, sig[k].end);
      if (txt == closeCh) {
        depth++;
      } else if (txt == openCh) {
        depth--;
        if (depth == 0) return k;
      }
    }
    return null;
  }

  static int? _matchingClose(
      String src, List<_Tok> sig, int pos, String openCh, String closeCh) {
    int depth = 0;
    for (int k = pos; k < sig.length; k++) {
      final String txt = src.substring(sig[k].start, sig[k].end);
      if (txt == openCh) {
        depth++;
      } else if (txt == closeCh) {
        depth--;
        if (depth == 0) return k;
      }
    }
    return null;
  }

  /// Collect the member/call/subscript segments of the chain that starts at the
  /// `?.` in `sig[pos]`.
  static List<_Seg> _scanChain(String src, List<_Tok> sig, int pos) {
    final List<_Seg> segs = <_Seg>[];
    int k = pos;
    while (k < sig.length) {
      final _Tok t = sig[k];
      final String txt = src.substring(t.start, t.end);

      if (txt == '?.') {
        if (k + 1 >= sig.length) break;
        final _Tok nxt = sig[k + 1];
        final String ntxt = src.substring(nxt.start, nxt.end);
        if (nxt.kind == _num && _isDigit(src.codeUnitAt(nxt.start))) break;
        if (ntxt == '(') {
          final int? close = _matchingClose(src, sig, k + 1, '(', ')');
          if (close == null) throw const _Unsupported('unbalanced ( after ?.');
          segs.add(_Seg(true, t.start, sig[close].end,
              src.substring(nxt.start, sig[close].end)));
          k = close + 1;
          continue;
        }
        if (ntxt == '[') {
          final int? close = _matchingClose(src, sig, k + 1, '[', ']');
          if (close == null) throw const _Unsupported('unbalanced [ after ?.');
          segs.add(_Seg(true, t.start, sig[close].end,
              src.substring(nxt.start, sig[close].end)));
          k = close + 1;
          continue;
        }
        if (nxt.kind == _id || nxt.kind == _num || nxt.kind == _str) {
          segs.add(_Seg(true, t.start, nxt.end, '.$ntxt'));
          k += 2;
          continue;
        }
        throw _Unsupported('unexpected token after ?.: $ntxt');
      }

      if (txt == '.') {
        if (k + 1 >= sig.length) break;
        final _Tok nxt = sig[k + 1];
        if (nxt.kind != _id) break;
        segs.add(_Seg(
            false, t.start, nxt.end, src.substring(t.start, nxt.end)));
        k += 2;
        continue;
      }

      if (txt == '(' || txt == '[') {
        final String closeCh = txt == '(' ? ')' : ']';
        final int? close = _matchingClose(src, sig, k, txt, closeCh);
        if (close == null) break;
        segs.add(
            _Seg(false, t.start, sig[close].end, src.substring(t.start, sig[close].end)));
        k = close + 1;
        continue;
      }

      break;
    }
    return segs;
  }

  static _ChainRewrite _rewriteOptionalChain(
      String src, List<_Tok> sig, int pos) {
    final int headStart = _findHead(src, sig, pos);
    final List<_Seg> segs = _scanChain(src, sig, pos);
    if (segs.isEmpty) throw const _Unsupported('no chain segments');
    final bool anyOptional = segs.any((_Seg s) => s.optional);
    if (!anyOptional) throw const _Unsupported('no optional segment');

    final String head = src.substring(headStart, segs.first.start);

    String fullText(int upto) {
      final StringBuffer sb = StringBuffer(head);
      for (int i = 0; i <= upto && i < segs.length; i++) {
        sb.write(segs[i].neutral);
      }
      return sb.toString();
    }

    final List<int> optIdx = <int>[];
    for (int i = 0; i < segs.length; i++) {
      if (segs[i].optional) optIdx.add(i);
    }

    for (final int i in optIdx) {
      final String recv = fullText(i - 1);
      if (!_isPureReceiver(recv)) {
        throw _Unsupported(
            'receiver is not side-effect free: ${recv.trim()}');
      }
    }

    String result(int i) {
      if (i == optIdx.length) return fullText(segs.length - 1);
      final String recv = fullText(optIdx[i] - 1);
      return '($recv == null ? void 0 : ${result(i + 1)})';
    }

    return _ChainRewrite(result(0), headStart, segs.last.end);
  }

  /// True when duplicating this expression text is side-effect free.
  static bool _isPureReceiver(String text) {
    if (text.trim().isEmpty) return false;
    final List<_Tok> sig;
    try {
      sig = _significant(_tokenize(text));
    } catch (_) {
      return false;
    }
    for (int k = 0; k < sig.length; k++) {
      final _Tok t = sig[k];
      if (t.kind != _punc) continue;
      final String txt = text.substring(t.start, t.end);
      if (txt == '++' || txt == '--') return false;
      if (txt.endsWith('=') &&
          txt != '==' &&
          txt != '===' &&
          txt != '!=' &&
          txt != '!==' &&
          txt != '<=' &&
          txt != '>=') {
        return false;
      }
      if (txt == '(' && k > 0) {
        final _Tok p = sig[k - 1];
        final String ptxt = text.substring(p.start, p.end);
        if (p.kind == _id ||
            p.kind == _num ||
            p.kind == _str ||
            p.kind == _tmpl ||
            ptxt == ')' ||
            ptxt == ']') {
          return false; // that '(' is a call, not a grouping
        }
      }
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // nullish coalescing / logical assignment
  // ---------------------------------------------------------------------------

  static int _leftOperand(String src, List<_Tok> sig, int pos) {
    int depth = 0;
    int? start;
    for (int k = pos - 1; k >= 0; k--) {
      final _Tok t = sig[k];
      // A template chunk must never be crossed: in `` `x=${a ?? b}` `` the left
      // operand lives inside the substitution and the opening chunk is the
      // boundary. Without this the operand would swallow the whole template.
      if (t.kind == _tmpl) break;
      final String txt = src.substring(t.start, t.end);
      if (t.kind == _punc) {
        if (txt == ')' || txt == ']' || txt == '}') {
          depth++;
        } else if (txt == '(' || txt == '[' || txt == '{') {
          if (depth == 0) break;
          depth--;
        } else if (depth == 0 && _boundaryLeft.contains(txt)) {
          break;
        }
      } else if (t.kind == _id && depth == 0 && _boundaryLeftId.contains(txt)) {
        break;
      }
      start = t.start;
    }
    if (start == null) throw const _Unsupported('no left operand');
    return start;
  }

  static int _rightOperand(
      String src, List<_Tok> sig, int pos, Set<String> boundaries) {
    int depth = 0;
    int? end;
    for (int k = pos + 1; k < sig.length; k++) {
      final _Tok t = sig[k];
      // A template chunk that starts with `}` is the boundary that closes a
      // substitution: in `` `a=${x ?? y}` `` the right operand lives inside the
      // substitution and must not run past it.
      if (t.kind == _tmpl && _tokText(src, t).startsWith('}')) break;
      final String txt = _tokText(src, t);
      if (t.kind == _punc) {
        if (txt == '(' || txt == '[' || txt == '{') {
          depth++;
        } else if (txt == ')' || txt == ']' || txt == '}') {
          if (depth == 0) break;
          depth--;
        } else if (depth == 0 && boundaries.contains(txt)) {
          break;
        }
      }
      end = t.end;
    }
    if (end == null) throw const _Unsupported('no right operand');
    return end;
  }

  /// The literal source text a significant token covers.
  static String _tokText(String src, _Tok t) => src.substring(t.start, t.end);

  static _OpRewrite _rewriteNullish(String src, List<_Tok> sig, int pos) {
    final _Tok t = sig[pos];
    final int aStart = _leftOperand(src, sig, pos);
    final int aEnd = t.start;
    final int bEnd = _rightOperand(src, sig, pos, _boundaryRightOp);
    final String a = src.substring(aStart, aEnd);
    final String b = src.substring(t.end, bEnd);
    if (a.trim().isEmpty || b.trim().isEmpty) {
      throw const _Unsupported('empty operand');
    }
    final String out =
        '(($a) !== null && ($a) !== void 0 ? ($a) : ($b))';
    return _OpRewrite(out, aStart, bEnd);
  }

  static _OpRewrite _rewriteLogicalAssign(String src, List<_Tok> sig, int pos) {
    final _Tok t = sig[pos];
    final String op = src.substring(t.start, t.end);
    final int aStart = _leftOperand(src, sig, pos);
    final int aEnd = t.start;
    final int bEnd = _rightOperand(src, sig, pos, _boundaryRightAssign);
    final String a = src.substring(aStart, aEnd);
    final String b = src.substring(t.end, bEnd);
    if (a.trim().isEmpty || b.trim().isEmpty) {
      throw const _Unsupported('empty operand');
    }
    String out;
    if (op == '||=') {
      out = '(($a) || ($a = $b))';
    } else if (op == '&&=') {
      out = '(($a) && ($a = $b))';
    } else {
      out = '(($a) !== null && ($a) !== void 0 ? ($a) : ($a = $b))';
    }
    return _OpRewrite(out, aStart, bEnd);
  }
}

class _Tok {
  final int kind;
  final int start;
  final int end;
  const _Tok(this.kind, this.start, this.end);
}

class _Seg {
  final bool optional;
  final int start;
  final int end;
  final String neutral;
  const _Seg(this.optional, this.start, this.end, this.neutral);
}

class _Splice {
  final int start;
  final int end;
  final String replacement;
  const _Splice(this.start, this.end, this.replacement);
}

/// Outcome of one left-to-right pass: the new text, whether anything was
/// rewritten at all, and whether a real construct had to be skipped because it
/// was nested inside a range this pass already rewrote (which requires another
/// pass to reach it).
class _PassResult {
  final String source;
  final bool changed;
  final bool innerSkipped;
  const _PassResult(this.source, this.changed, this.innerSkipped);
}

class _ChainRewrite {
  final String text;
  final int start;
  final int end;
  const _ChainRewrite(this.text, this.start, this.end);
}

class _OpRewrite {
  final String text;
  final int start;
  final int end;
  const _OpRewrite(this.text, this.start, this.end);
}

class _Unsupported implements Exception {
  final String reason;
  const _Unsupported(this.reason);

  @override
  String toString() => 'Unsupported: $reason';
}
