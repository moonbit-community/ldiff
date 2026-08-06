# ldiff — lexer-based diff for MoonBit code

Line diffs whose changed regions are **aligned by weighted token similarity**
and highlighted **word-by-word**, rendered to HTML. Tokens come from the real
MoonBit lexer (`moonbitlang/lexer`), so strings, comments and identifiers are
classified the way the language sees them; line structure comes from
`moonbitlang/core/diff` (Myers / patience).

```moonbit
let html = @ldiff.html_page(
  title="my change",
  @ldiff.side_by_side_html(old=old_lines, new=new_lines),
)
```

`unified_html` renders the same alignment as a single-column view. See
`__snapshot__/demo.html` for rendered output (open it in a browser).

Pass `line_numbers=true` to render complete old/new line numbers. The split
view becomes old number / old code / new number / new code; the unified view
becomes old number / new number / code. The option is off by default, and the
legacy renderer output remains unchanged when it is omitted.

Notes:
- `html_page` inserts `body` verbatim (it is your rendered HTML); only pass
  it output from this library or HTML you trust.
- Lines are lexed independently. This is safe for MoonBit (a line-oriented
  language with no block comments); multiline raw strings (`#|`) lex as one
  `Str` token per line.

## How it works

1. **Line diff** (`@diff`, Myers/patience) gives structure and hunks.
2. Each `Delete`+`Insert` replacement block is **aligned**: lines pair by a
   weighted token edit distance (Wagner–Fischer), maximizing the total
   positive margin `sum(similarity − 0.4)` under a monotone alignment.
3. Each aligned pair's **highlights are the alignment's own traceback**
   (equal / substitution / delete / insert), so the script scored is exactly
   the script rendered; substitutions show as positionally paired runs.

Weight classes (integer, ×20): identifiers/keywords/literals 20, punctuation
6, comment content 2, whitespace 1, comment boilerplate (`//`, comment
spacing) 0. Comments therefore *help* pairing (identical comments win ties)
but can never veto it, and unrelated comment-only lines do not pair.
Same-kind substitution costs 1.5×weight — renames align cheaply, but two
lines with nothing in common stay under the pairing threshold.

All scoring is integer (permille similarities, stored backpointers): results
are bit-identical across wasm, wasm-gc, js and native.

Cost discipline: dimension guards, a per-line token cap, an early-exit DP
cell budget (2M) and a per-pair traceback guard; over budget a block renders
as plain unpaired rows (in the style of difflib's `_plain_replace`), never as
misleadingly highlighted pairs.

The design and implementation were hardened through several rounds of
adversarial review; the regression tests pin the semantics (comment
tie-breaking, zero-mass lines, margin-vs-raw-similarity objective, budget
fallbacks, delete-before-insert ordering, traceback reconstruction).

## Development

Until a toolchain release bundles `moonbitlang/core/diff`, build against a
core checkout that has it:

```sh
MOON_CORE_OVERRIDE=~/git/core moon test
```
