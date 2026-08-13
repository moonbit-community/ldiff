# ldiff — lexer-based diff for MoonBit code

playground: https://moonbit-community.github.io/ldiff/

`ldiff` separates diff calculation from presentation. The root package
tokenizes MoonBit, aligns lines and tokens, groups hunks, and returns a public
renderer-neutral `DiffDocument`. HTML and unified patch text live in dedicated
packages that consume the same calculated document.

```text
moonbit-community/ldiff       calculation and public diff IR
moonbit-community/ldiff/html  split and unified HTML rendering
moonbit-community/ldiff/text  unified patch text rendering
```

## Usage

Add the packages needed by the caller. An explicit alias keeps the ldiff HTML
renderer distinct from other packages commonly named `html`:

```moon.pkg
import {
  "moonbit-community/ldiff",
  "moonbit-community/ldiff/html" @ldiff_html,
  "moonbit-community/ldiff/text" @ldiff_text,
}
```

Calculate once and select any renderer:

```mbt
let document = @ldiff.diff(
  old=["let total = price"],
  new=["let total = price + tax"],
  context=3,
)
let split = @ldiff_html.render_side_by_side(document, line_numbers=true)
let unified = @ldiff_html.render_unified(document)
let patches = @ldiff_text.render_unified_hunks(document)
```

Use `@ldiff.line_diff` for plain text. It performs a Patience line diff without
MoonBit tokenization, semantic cleanup, or intraline highlights. The existing
convenience signatures remain available in their renderer packages, for
example `@ldiff_html.side_by_side_html(old~, new~)` and
`@ldiff_text.unified_hunks(old~, new~)`.

## Migration from the single root package

The calculation and rendered bytes are unchanged, but rendering names moved:

| Previous name | New name |
| --- | --- |
| `@ldiff.side_by_side_html` and other `*_html` functions | `@ldiff_html.side_by_side_html` and the corresponding HTML function |
| `@ldiff.html_page` | `@ldiff_html.html_page` |
| `@ldiff.HunkNote` | `@ldiff_html.HunkNote` |
| `@ldiff.unified_hunks` | `@ldiff_text.unified_hunks` |
| `@ldiff.unified_line_hunks` | `@ldiff_text.unified_line_hunks` |

The root package continues to expose `TokKind`, `Tok`, `weight`,
`tokenize_line`, and `similarity`, and now also exposes `diff`, `line_diff`,
and the `DiffDocument` IR types.
