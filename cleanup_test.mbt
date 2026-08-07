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
fn count_substring(text : String, needle : String) -> Int {
  let mut rest = text.view()
  let mut count = 0
  while rest.find(needle) is Some(index) {
    count += 1
    rest = rest.view(start_offset=index + needle.length())
  }
  count
}

///|
test "token cleanup highlights the natural repeated-token boundary" {
  let split = @ldiff.side_by_side_html(old=["x x"], new=["x"], context=0)
  inspect(
    split.contains(
      "<td class=\"del\">x <b class=\"wd\">x</b></td><td class=\"add\">x</td>",
    ),
    content="true",
  )
  let comment = @ldiff.unified_html(old=["// foo foo"], new=["// foo"])
  inspect(comment.contains("// foo <b class=\"wd\">foo</b>"), content="true")
  let unicode = @ldiff.side_by_side_html(old=["名 名"], new=["名"])
  inspect(unicode.contains("名 <b class=\"wd\">名</b>"), content="true")
}

///|
test "global traceback fixes left-leaning insertion in both renderers" {
  let old = ["    match candidate.normalized_expr_identifier_name() {"]
  let new = [
    "    if candidate.normalized_expr_identifier_name() is Some(candidate_name) {",
  ]
  let expected = "    <b class=\"wa\">if</b> candidate.normalized_expr_identifier_name() <b class=\"wa\">is Some(candidate_name)</b> {"
  let split = @ldiff.side_by_side_html(
    old~,
    new~,
    context=0,
    line_cleanup=false,
  )
  let unified = @ldiff.unified_html(old~, new~, context=0, line_cleanup=false)
  assert_true(split.contains(expected))
  assert_true(unified.contains(expected))
  assert_eq(
    split,
    @ldiff.side_by_side_html(old~, new~, context=0, line_cleanup=true),
  )
  assert_eq(
    unified,
    @ldiff.unified_html(old~, new~, context=0, line_cleanup=true),
  )
}

///|
test "line cleanup is opt-in and removes a misleading blank anchor" {
  let old = ["let a = old", "", "let b = old", "let c = old"]
  let new = ["let a = new", "let b = new", "let c = new", ""]
  let default_split = @ldiff.side_by_side_html(old~, new~, context=0)
  assert_eq(
    default_split,
    @ldiff.side_by_side_html(old~, new~, context=0, line_cleanup=false),
  )
  inspect(
    count_substring(default_split, "class=\"hunk-header\"") == 2,
    content="true",
  )
  let cleaned = @ldiff.side_by_side_html(
    old~,
    new~,
    context=0,
    line_cleanup=true,
  )
  inspect(
    cleaned.contains(
      "<td class=\"del\">let b = <b class=\"wd\">old</b></td><td class=\"add\">let b = <b class=\"wa\">new</b></td>",
    ),
    content="true",
  )
  inspect(
    count_substring(cleaned, "class=\"hunk-header\"") == 1,
    content="true",
  )
}

///|
test "re-aligned identical meaningful line is rendered as context" {
  let old = ["let a = old", "same line", "let b = old", "}", "let c = old", "}"]
  let new = ["let a = new", "}", "same line", "let b = new", "let c = new", "}"]
  let split = @ldiff.side_by_side_html(old~, new~, context=1, line_cleanup=true)
  inspect(
    split.contains(
      "<td class=\"ctx\">same line</td><td class=\"ctx\">same line</td>",
    ),
    content="true",
  )
  let unified = @ldiff.unified_html(old~, new~, context=1, line_cleanup=true)
  inspect(
    unified.contains("<span class=\"ctx\"> same line</span>"),
    content="true",
  )
}

///|
test "both renderers preserve exact core hunk headers for all contexts" {
  let old = ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]
  let new = ["a", "B", "c", "d", "e", "f", "g", "H", "i", "j"]
  for
    case in [
      (0, ["@@ -2 +2 @@", "@@ -8 +8 @@"]),
      (1, ["@@ -1,3 +1,3 @@", "@@ -7,3 +7,3 @@"]),
      (3, ["@@ -1,10 +1,10 @@"]),
      (99, ["@@ -1,10 +1,10 @@"]),
    ] {
    let (context, headers) = case
    let split = @ldiff.side_by_side_html(
      old~,
      new~,
      context~,
      line_cleanup=true,
    )
    let unified = @ldiff.unified_html(old~, new~, context~, line_cleanup=true)
    assert_eq(count_substring(split, "class=\"hunk-header\""), headers.length())
    assert_eq(
      count_substring(unified, "class=\"hunk-header\""),
      headers.length(),
    )
    for header in headers {
      assert_true(
        split.contains("<td class=\"hunk-header\" colspan=\"2\">\{header}</td>"),
      )
      assert_true(
        unified.contains("<span class=\"hunk-header\">\{header}</span>"),
      )
    }
  }
}

///|
test "pure insertion and deletion retain file-edge hunk ranges" {
  inspect(
    @ldiff.side_by_side_html(
      old=[],
      new=["x", "y"],
      context=0,
      line_cleanup=true,
    ),
    content=(
      #|<table class="split">
      #|<tr><td class="hunk-header" colspan="2">@@ -0,0 +1,2 @@</td></tr>
      #|<tr><td class="empty"></td><td class="add">x</td></tr>
      #|<tr><td class="empty"></td><td class="add">y</td></tr>
      #|</table>
      #|
    ),
  )
  inspect(
    @ldiff.unified_html(old=["x", "y"], new=[], context=0, line_cleanup=true),
    content=(
      #|<pre class="unified">
      #|<span class="hunk-header">@@ -1,2 +0,0 @@</span>
      #|<span class="del">-x</span>
      #|<span class="del">-y</span>
      #|</pre>
      #|
    ),
  )
}

///|
fn assert_line_cleanup_budget_fallback(
  old : Array[String],
  new : Array[String],
) -> Unit raise {
  assert_eq(
    @ldiff.side_by_side_html(old~, new~, context=0, line_cleanup=true),
    @ldiff.side_by_side_html(old~, new~, context=0, line_cleanup=false),
  )
  assert_eq(
    @ldiff.unified_html(old~, new~, context=0, line_cleanup=true),
    @ldiff.unified_html(old~, new~, context=0, line_cleanup=false),
  )
}

///|
test "line cleanup restores original grouping at all window budgets" {
  let many_old : Array[String] = []
  let many_new : Array[String] = []
  for i in 0..<65 {
    many_old.push("old declaration \{i}")
    many_new.push("new expression \{i}")
  }
  many_old.push("")
  many_new.push("")
  many_old.push("old tail")
  many_new.push("new tail")
  assert_line_cleanup_budget_fallback(many_old, many_new)

  let huge_old = "word ".repeat(600) + "old"
  let huge_new = "word ".repeat(600) + "new"
  assert_line_cleanup_budget_fallback([huge_old, "", "old tail"], [
    huge_new, "", "new tail",
  ])

  let cells_old : Array[String] = []
  let cells_new : Array[String] = []
  for i in 0..<50 {
    cells_old.push(
      "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi OLD\{i}",
    )
    cells_new.push(
      "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi NEW\{i}",
    )
  }
  cells_old.push("")
  cells_new.push("")
  cells_old.push("old tail")
  cells_new.push("new tail")
  assert_line_cleanup_budget_fallback(cells_old, cells_new)
}

///|
test "per-pair traceback budget keeps pairing but omits highlights" {
  let old_line = "x ".repeat(256) + "old"
  let new_line = "x ".repeat(256) + "new"
  let split = @ldiff.side_by_side_html(
    old=[old_line],
    new=[new_line],
    context=0,
  )
  inspect(split.contains("<b class="), content="false")
  inspect(
    split.contains(
      "<td class=\"del\">\{old_line}</td><td class=\"add\">\{new_line}</td>",
    ),
    content="true",
  )
  let unified = @ldiff.unified_html(old=[old_line], new=[new_line], context=0)
  inspect(unified.contains("<b class="), content="false")
  inspect(
    unified.find("class=\"del\"").unwrap() <
    unified.find("class=\"add\"").unwrap(),
    content="true",
  )
}
