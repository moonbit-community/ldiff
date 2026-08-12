// Copyright 2026 International Digital Economy Academy
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

///|
test "alignment objective is positive margin, not raw similarity" {
  // One strong pair (margin ~510) must beat two above-threshold moderate
  // diagonal pairs (raw-sim total ~1280, margins ~240 each).
  let a = "alpha beta gamma delta epsilon zeta eta theta"
  let y = "alpha beta gamma delta epsilon zeta eta CHANGED"
  let x = "alpha beta gamma delta ONE TWO THREE FOUR"
  let b = "FIVE SIX SEVEN EIGHT epsilon zeta eta CHANGED"
  let olds = [a, b].map(tokenize_line)
  let news = [x, y].map(tokenize_line)
  @debug.debug_inspect(
    align(olds, news),
    content="[(None, Some(0)), (Some(0), Some(1)), (Some(1), None)]",
  )
}

///|
test "unrelated block orders delete before insert" {
  let a = ["aaa bbb ccc"].map(tokenize_line)
  let b = ["xxx yyy zzz"].map(tokenize_line)
  @debug.debug_inspect(
    align(a, b),
    content="[(Some(0), None), (None, Some(0))]",
  )
}

///|
test "comma carries less alignment evidence than structural punctuation" {
  let comma = Tok::{ kind: Punct, text: "," }
  let close = Tok::{ kind: Punct, text: ")" }
  assert_eq(weight(Punct), 6)
  assert_eq(alignment_weight(comma), 1)
  assert_eq(alignment_weight(close), 6)
  assert_true(similarity("old,", "new,") < THETA)
  assert_true(similarity("old)", "new)") > THETA)
}

///|
test "pair_ops reconstruction property" {
  for
    pair in [
      ("let total = a", "let sum = a"),
      ("f(x, 1) // old note", "g(x, 2) // new note"),
      ("let 名 = \"é😀\"", "let 名 = \"z\""),
      ("", "only new"),
    ] {
    let (oa, ob) = pair
    let left = StringBuilder::new()
    let right = StringBuilder::new()
    for op in pair_ops(tokenize_line(oa), tokenize_line(ob)) {
      match op {
        OEq(t) => {
          left <+ "\{t.text}"
          right <+ "\{t.text}"
        }
        OSub(a, b) => {
          left <+ "\{a.text}"
          right <+ "\{b.text}"
        }
        ODel(a) => left <+ "\{a.text}"
        OIns(b) => right <+ "\{b.text}"
      }
    }
    assert_eq(left.to_string(), oa)
    assert_eq(right.to_string(), ob)
  }
}

///|
test "strong crossing pair beats weak monotone pairs" {
  // The strong pair sits on the anti-diagonal; taking it forbids the weak
  // diagonal pairs. Margin scoring must still prefer it.
  let olds = ["unrelated_one thing here", "let total = price * count"].map(
    tokenize_line,
  )
  let news = ["let total = price * count + tax", "other_stuff entirely now"].map(
    tokenize_line,
  )
  @debug.debug_inspect(
    align(olds, news),
    content="[(Some(0), None), (Some(1), Some(0)), (None, Some(1))]",
  )
}

///|
test "long-line fallback is selected before the recursive lexer and is lossless" {
  let line = "let 名 = " + "value + ".repeat(300) + "😀 < end"
  assert_false(lexer_complexity_within_limit(line))
  assert_eq(fallback_tokenize_line(line).map(t => t.text).join(""), line)
  assert_eq(tokenize_line(line).map(t => t.text).join(""), line)
}

///|
test "long-line fallback preserves marker comments Unicode and empty runs" {
  let line = "///| " + "说明/word  ".repeat(300) + "😀"
  assert_false(lexer_complexity_within_limit(line))
  assert_eq(tokenize_line(line).map(t => t.text).join(""), line)
  assert_true(tokenize_line(line)[0].kind is Marker)

  let punctuation = "(".repeat(2000) + "😀" + ")".repeat(2000)
  assert_false(lexer_complexity_within_limit(punctuation))
  assert_eq(tokenize_line(punctuation).map(t => t.text).join(""), punctuation)

  let interpolation = "\\" + "{value} + "
  let slash_in_string = "let url = \"https://example.test/" +
    interpolation.repeat(300) +
    "\""
  assert_false(lexer_complexity_within_limit(slash_in_string))
  assert_eq(
    tokenize_line(slash_in_string).map(t => t.text).join(""),
    slash_in_string,
  )
}

///|
test "fallback tokens still feed the existing alignment budgets" {
  let old = "word + ".repeat(600) + "old"
  let new = "word + ".repeat(600) + "new"
  let old_tokens = tokenize_line(old)
  let new_tokens = tokenize_line(new)
  assert_true(old_tokens.length() > 1024)
  assert_true(new_tokens.length() > 1024)
  assert_true(alignment_tokens([old], [new], line => line) is None)
}

///|
test "pair renderer trims whitespace tokens at every changed-run boundary" {
  let space = Tok::{ kind: Space, text: " " }
  let old = Tok::{ kind: Word, text: "old" }
  let new = Tok::{ kind: Word, text: "new" }
  let (both_left, both_right) = pair_row_html([
    OSub(space, space),
    OSub(old, new),
    OSub(space, space),
  ])
  assert_eq(both_left, " <b class=\"wd\">old</b> ")
  assert_eq(both_right, " <b class=\"wa\">new</b> ")

  let (before, _) = pair_row_html([ODel(space), ODel(old)])
  assert_eq(before, " <b class=\"wd\">old</b>")
  let (after, _) = pair_row_html([ODel(old), ODel(space)])
  assert_eq(after, "<b class=\"wd\">old</b> ")
}

///|
test "pair renderer uses token text and trims each side independently" {
  let (left, right) = pair_row_html([
    OSub({ kind: Filler, text: "\t" }, { kind: Word, text: "new" }),
    OSub({ kind: Word, text: "old" }, { kind: Filler, text: " " }),
  ])
  assert_eq(left, "\t<b class=\"wd\">old</b>")
  assert_eq(right, "<b class=\"wa\">new</b> ")

  let (_, internal) = pair_row_html([
    OIns({ kind: Word, text: "a" }),
    OIns({ kind: Space, text: " " }),
    OIns({ kind: Punct, text: ":" }),
    OIns({ kind: Filler, text: " " }),
    OIns({ kind: Word, text: "Int" }),
  ])
  assert_eq(internal, "<b class=\"wa\">a : Int</b>")

  let (plain, _) = pair_row_html([
    ODel({ kind: Space, text: " " }),
    ODel({ kind: Filler, text: "\t" }),
  ])
  assert_eq(plain, " \t")

  let (_, comment) = pair_row_html([
    OIns({ kind: Filler, text: "//" }),
    OIns({ kind: Filler, text: " " }),
    OIns({ kind: Comment, text: "word" }),
    OIns({ kind: Filler, text: " " }),
  ])
  assert_eq(comment, "<b class=\"wa\">// word</b> ")
}

///|
test "full-line renderer trims whitespace escapes content and skips empty emphasis" {
  assert_eq(
    full_line_html(tokenize_line(" \t<old & gone>  "), "wd"),
    " \t<b class=\"wd\">&lt;old &amp; gone&gt;</b>  ",
  )
  assert_eq(
    full_line_html(tokenize_line("\tnew & <value> "), "wa"),
    "\t<b class=\"wa\">new &amp; &lt;value&gt;</b> ",
  )
  assert_eq(full_line_html(tokenize_line(" \t  "), "wd"), " \t  ")
  assert_eq(full_line_html(tokenize_line(""), "wa"), "")
}
