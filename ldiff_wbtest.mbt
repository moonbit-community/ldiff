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
  inspect(lexer_complexity_within_limit(line), content="false")
  assert_eq(fallback_tokenize_line(line).map(t => t.text).join(""), line)
  assert_eq(tokenize_line(line).map(t => t.text).join(""), line)
}

///|
test "long-line fallback preserves marker comments Unicode and empty runs" {
  let line = "///| " + "说明/word  ".repeat(300) + "😀"
  inspect(lexer_complexity_within_limit(line), content="false")
  assert_eq(tokenize_line(line).map(t => t.text).join(""), line)
  inspect(tokenize_line(line)[0].kind is Marker, content="true")

  let punctuation = "(".repeat(2000) + "😀" + ")".repeat(2000)
  inspect(lexer_complexity_within_limit(punctuation), content="false")
  assert_eq(tokenize_line(punctuation).map(t => t.text).join(""), punctuation)

  let interpolation = "\\" + "{value} + "
  let slash_in_string = "let url = \"https://example.test/" +
    interpolation.repeat(300) +
    "\""
  inspect(lexer_complexity_within_limit(slash_in_string), content="false")
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
  inspect(old_tokens.length() > 1024, content="true")
  inspect(new_tokens.length() > 1024, content="true")
  inspect(alignment_tokens([old], [new], line => line) is None, content="true")
}
