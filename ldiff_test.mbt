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
test "tokenizer is faithful and language-aware" {
  for
    line in [
      "let x = 1 // trailing", "/// doc comment", "///| x", "let s = \"a//b\" // real",
      "let 名 = \"é😀\"", "fn f(a : Int) -> Int { a + 1 }",
    ] {
    assert_eq(@ldiff.tokenize_line(line).map(t => t.text()).join(""), line)
  }
  // a string literal is one Str token even when it contains `//`
  let toks = @ldiff.tokenize_line("let s = \"a//b\" // real")
  @debug.debug_inspect(
    toks.filter(t => t.kind() is Str).map(t => t.text()),
    content=(
      #|["\"a//b\""]
    ),
  )
}

///|
test "similarity: comments help but cannot veto" {
  // similar comments pair; unrelated comments do not
  inspect(
    @ldiff.similarity("// add tax", "// add the tax") > 400,
    content="true",
  )
  inspect(
    @ldiff.similarity("// promoted; output is not", "// another topic entirely") <
    400,
    content="true",
  )
  // code identical, comment rewritten: still a strong pair
  inspect(
    @ldiff.similarity("let x = 1 // sum", "let x = 1 // total") > 900,
    content="true",
  )
  // identical comment beats a rewritten one (tie-breaker)
  inspect(
    @ldiff.similarity("let x = 1 // a", "let x = 1 // a") >
    @ldiff.similarity("let x = 1 // a", "let x = 1 // b"),
    content="true",
  )
  // lines with nothing in common stay under the threshold
  inspect(
    @ldiff.similarity("alpha beta gamma delta eps", "one two three four five") <
    400,
    content="true",
  )
  // respacing barely matters
  inspect(@ldiff.similarity("f(a,b)", "f( a , b )") > 800, content="true")
  // zero-mass lines pair only when identical
  inspect(@ldiff.similarity("//", "") == 0, content="true")
  inspect(@ldiff.similarity("//", "//") == 1000, content="true")
}

///|
test "split view: alignment, highlights, escaping" {
  let old = [
      "fn total(items : Array[Item]) -> Int {", "  let mut sum = 0 // running total",
      "  // helper detail", "  sum", "}",
    ][:]
  let new = [
      "fn total(items : Array[Item], tax~ : Int) -> Int {", "  let mut sum = 0 // running total",
      "  sum + tax", "}",
    ][:]
  let html = @ldiff.side_by_side_html(old~, new~, context=1)
  // paired rows carry word-level highlights
  inspect(html.contains("<b class=\"wa\">"), content="true")
  // the unrelated comment line is an unpaired deletion (no pairing garbage)
  inspect(
    html.contains(
      "<td class=\"del\">  // helper detail</td><td class=\"empty\">",
    ),
    content="true",
  )
  // escaping
  let esc_html = @ldiff.side_by_side_html(old=["if a < b && c > d {"], new=[
    "if a <= b && c > d {",
  ])
  inspect(esc_html.contains("&lt;"), content="true")
  inspect(esc_html.contains("<b class=\"wa\">"), content="true")
}

///|
test "budget fallbacks render plain rows" {
  // per-line token cap
  let big_old = "word ".repeat(600) + "same tail here"
  let big_new = "word ".repeat(600) + "same tail CHANGED"
  let html = @ldiff.side_by_side_html(old=[big_old], new=[big_new])
  inspect(html.contains("<b class="), content="false")
  // total cell budget
  let old_lines : Array[String] = []
  let new_lines : Array[String] = []
  for i in 0..<50 {
    let base = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi line\{i}"
    old_lines.push(base)
    new_lines.push(base + " tail")
  }
  let html2 = @ldiff.side_by_side_html(old=old_lines, new=new_lines)
  inspect(html2.contains("<b class="), content="false")
}

///|
test "complete page demo" (t : @test.Test) {
  let old = [
      "///| sum with default", "pub fn total(items : Array[Item]) -> Int {", "  let mut sum = 0",
      "  for item in items {", "    sum += item.price * item.count", "  }", "  sum // final",
      "}",
    ][:]
  let new = [
      "///| sum with tax", "pub fn total(items : Array[Item], tax~ : Int) -> Int {",
      "  let mut sum = 0", "  for item in items {", "    sum += item.price * item.count + tax",
      "  }", "  sum // final", "}",
    ][:]
  t.write(
    @ldiff.html_page(title="ldiff demo", @ldiff.side_by_side_html(old~, new~)),
  )
  t.snapshot(filename="demo.html")
}
