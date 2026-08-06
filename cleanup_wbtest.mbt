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
fn cleanup_op_signature(ops : ArrayView[Op]) -> String {
  ops
  .map(op => {
    match op {
      OEq(t) => "=\{t.text}"
      OSub(a, b) => "~\{a.text}>\{b.text}"
      ODel(t) => "-\{t.text}"
      OIns(t) => "+\{t.text}"
    }
  })
  .join("|")
}

///|
fn reconstruct_ops(ops : ArrayView[Op]) -> (String, String) {
  let old = StringBuilder::new()
  let new = StringBuilder::new()
  for op in ops {
    match op {
      OEq(t) => {
        old <+ "\{t.text}"
        new <+ "\{t.text}"
      }
      OSub(a, b) => {
        old <+ "\{a.text}"
        new <+ "\{b.text}"
      }
      ODel(t) => old <+ "\{t.text}"
      OIns(t) => new <+ "\{t.text}"
    }
  }
  (old.to_string(), new.to_string())
}

///|
fn ops_cost(ops : ArrayView[Op]) -> Int {
  let mut cost = 0
  for op in ops {
    cost += match op {
      OEq(_) => 0
      OSub(a, b) => subst_cost(a, b).unwrap()
      ODel(t) | OIns(t) => weight(t.kind)
    }
  }
  cost
}

///|
test "lossless cleanup places repeated edits at natural right boundary" {
  let repeated_old = tokenize_line("x x")
  let repeated_new = tokenize_line("x")
  inspect(
    cleanup_op_signature(pair_ops_min(repeated_old, repeated_new)),
    content="-x|- |=x",
  )
  inspect(
    cleanup_op_signature(pair_ops(repeated_old, repeated_new)),
    content="=x|- |-x",
  )
  inspect(
    cleanup_op_signature(
      pair_ops(tokenize_line("// foo foo"), tokenize_line("// foo")),
    ),
    content="=//|= |-foo|- |=foo",
  )
  inspect(
    cleanup_op_signature(
      pair_ops(tokenize_line("f((x))"), tokenize_line("f(x)")),
    ),
    content="=f|=(|-(|=x|=)|-)",
  )
}

///|
test "token boundary score follows the language-aware priority table" {
  let word = Tok::{ kind: Word, text: "word" }
  let string = Tok::{ kind: Str, text: "\"s\"" }
  let punct = Tok::{ kind: Punct, text: ")" }
  let space = Tok::{ kind: Space, text: " " }
  let filler = Tok::{ kind: Filler, text: "//" }
  assert_eq(token_boundary_score(None, Some(word)), 4)
  assert_eq(token_boundary_score(Some(word), Some(space)), 3)
  assert_eq(token_boundary_score(Some(filler), Some(word)), 3)
  assert_eq(token_boundary_score(Some(word), Some(punct)), 2)
  assert_eq(token_boundary_score(Some(word), Some(string)), 1)
  assert_eq(token_boundary_score(Some(word), Some(word)), 0)
}

///|
test "lossless cleanup preserves both texts and weighted minimum cost" {
  for
    pair in [
      ("x x", "x"),
      ("x  x", "x"),
      ("a a a", "a a"),
      ("// foo foo", "// foo"),
      ("f((x))", "f(x)"),
      ("let 名 = \"é😀\" // 注释 注释", "let 名 = \"z\" // 注释"),
      ("", "only new"),
    ] {
    let (old, new) = pair
    let old_toks = tokenize_line(old)
    let new_toks = tokenize_line(new)
    let minimum = pair_ops_min(old_toks, new_toks)
    let cleaned = pair_ops(old_toks, new_toks)
    assert_eq(reconstruct_ops(minimum), (old, new))
    assert_eq(reconstruct_ops(cleaned), (old, new))
    assert_eq(ops_cost(minimum), wdist(old_toks, new_toks))
    assert_eq(ops_cost(cleaned), wdist(old_toks, new_toks))
  }
}

///|
test "blank soft anchor is removed when coherent line pairs are stronger" {
  let old = ["let a = old", "", "let b = old", "let c = old"]
  let new = ["let a = new", "let b = new", "let c = new", ""]
  @debug.debug_inspect(
    rendering_diff(old, new, false).edits(),
    content=(
      #|<ArrayView:
      #|  [
      #|    Delete(old_index=0, old_len=1, new_index=0),
      #|    Insert(old_index=1, new_index=0, new_len=3),
      #|    Equal(old_index=1, new_index=3, len=1),
      #|    Delete(old_index=2, old_len=2, new_index=4),
      #|  ]>
    ),
  )
  @debug.debug_inspect(
    rendering_diff(old, new, true).edits(),
    content=(
      #|<ArrayView:
      #|  [
      #|    Delete(old_index=0, old_len=4, new_index=0),
      #|    Insert(old_index=4, new_index=0, new_len=4),
      #|  ]>
    ),
  )
}

///|
test "repeated bracket soft anchor yields to meaningful exact context" {
  let old = ["let a = old", "same line", "let b = old", "}", "let c = old", "}"]
  let new = ["let a = new", "}", "same line", "let b = new", "let c = new", "}"]
  @debug.debug_inspect(
    rendering_diff(old, new, true).edits(),
    content=(
      #|<ArrayView:
      #|  [
      #|    Delete(old_index=0, old_len=1, new_index=0),
      #|    Insert(old_index=1, new_index=0, new_len=2),
      #|    Equal(old_index=1, new_index=2, len=1),
      #|    Delete(old_index=2, old_len=3, new_index=3),
      #|    Insert(old_index=5, new_index=3, new_len=2),
      #|    Equal(old_index=5, new_index=5, len=1),
      #|  ]>
    ),
  )
}

///|
test "meaningful equal middle line remains a hard anchor" {
  let old = ["let a = old", "same semantic anchor", "let b = old"]
  let new = ["let a = new", "same semantic anchor", "let b = new"]
  assert_eq(
    rendering_diff(old, new, true).edits(),
    rendering_diff(old, new, false).edits(),
  )
}

///|
test "soft equal spans are bounded and significant lines never soften" {
  let eight = Array::make(8, "")
  let old_eight = ["old head"] + eight + ["old tail"]
  let new_eight = ["new head"] + eight + ["new tail"]
  let diff_eight = @diff.Diff(old=old_eight, new=new_eight)
  assert_true(
    soft_equal_edits(diff_eight.edits(), old_eight, new_eight).contains(true),
  )

  let nine = Array::make(9, "")
  let old_nine = ["old head"] + nine + ["old tail"]
  let new_nine = ["new head"] + nine + ["new tail"]
  let diff_nine = @diff.Diff(old=old_nine, new=new_nine)
  assert_false(
    soft_equal_edits(diff_nine.edits(), old_nine, new_nine).contains(true),
  )

  let old_word = ["old head", "semantic anchor", "old tail"]
  let new_word = ["new head", "semantic anchor", "new tail"]
  let diff_word = @diff.Diff(old=old_word, new=new_word)
  assert_false(
    soft_equal_edits(diff_word.edits(), old_word, new_word).contains(true),
  )
}

///|
test "cleanup comparison emphasizes visible improvements" (t : @test.Test) {
  let body = StringBuilder::new()
  body <+ "<style>\n"
  body <+ ".intro { max-width: 90ch; color: #333; }\n"
  body <+
    ".case { margin: 2rem 0; padding-top: .5rem; border-top: 2px solid #ddd; }\n"
  body <+ ".note { color: #555; }\n"
  body <+
    ".compare { width: 100%; table-layout: fixed; border-spacing: 1rem 0; }\n"
  body <+ ".compare > tbody > tr > th { text-align: left; }\n"
  body <+ ".compare > tbody > tr > td { width: 50%; vertical-align: top; }\n"
  body <+
    ".control { margin: .75rem 0; padding: .5rem; border: 1px solid #ddd; }\n"
  body <+ ".ok { color: #176b2c; font-weight: bold; }\n"
  body <+ "</style>\n"
  body <+ "<h1>ldiff cleanup comparison</h1>\n"
  body <+
    "<p class=\"intro\">The main cases below are required to change visibly. Token cases compare the minimum weighted traceback with lossless boundary cleanup; line cases compare <code>line_cleanup=false</code> and <code>true</code>. Historical no-regression controls are collapsed at the end.</p>\n"

  fn improvement(
    title : String,
    note : String,
    before_label : String,
    before : String,
    after_label : String,
    after : String,
  ) -> Unit raise {
    assert_false(before == after)
    body <+ "<section class=\"case\"><h3>\{esc(title)}</h3>\n"
    body <+ "<p class=\"note\">Observe: \{esc(note)}</p>\n"
    body <+ "<table class=\"compare\"><tr>"
    body <+ "<th>\{esc(before_label)}</th><th>\{esc(after_label)}</th>"
    body <+
      "</tr><tr><td>\{before}</td><td>\{after}</td></tr></table></section>\n"
  }

  fn token_table(old : String, new : String, cleaned : Bool) -> String {
    let old_tokens = tokenize_line(old)
    let new_tokens = tokenize_line(new)
    let ops = if cleaned {
      pair_ops(old_tokens, new_tokens)
    } else {
      pair_ops_min(old_tokens, new_tokens)
    }
    let (old_html, new_html) = pair_row_html(ops)
    "<table class=\"split\"><tr><td class=\"del\">\{old_html}</td><td class=\"add\">\{new_html}</td></tr></table>"
  }

  fn token_case(
    title : String,
    note : String,
    old : String,
    new : String,
  ) -> Unit raise {
    improvement(
      title,
      note,
      "Minimum traceback",
      token_table(old, new, false),
      "Lossless boundary cleanup",
      token_table(old, new, true),
    )
  }

  fn line_case(
    title : String,
    note : String,
    expected_context : String,
    old : Array[String],
    new : Array[String],
  ) -> Unit raise {
    let before = side_by_side_html(old~, new~, context=99)
    let after = side_by_side_html(old~, new~, context=99, line_cleanup=true)
    assert_false(
      before.contains(expected_context),
      msg="raw diff unexpectedly promoted context in ‘\{title}’",
    )
    assert_true(
      after.contains(expected_context),
      msg="cleanup did not promote expected context in ‘\{title}’",
    )
    improvement(
      title, note, "line_cleanup=false", before, "line_cleanup=true", after,
    )
  }

  body <+ "<h2>Token boundary placement</h2>\n"
  token_case(
    "Repeated identifier", "the deletion moves from the leading copy to the trailing ‘ x’, keeping the surviving identifier at the line start",
    "x x", "x",
  )
  token_case(
    "Comment filler", "the shared // marker and spacing remain equal instead of being pulled into the edit",
    "// foo foo", "// foo",
  )
  token_case(
    "Repeated punctuation", "the removed parentheses attach to punctuation boundaries around the unchanged expression",
    "f((x))", "f(x)",
  )

  body <+ "<h2>Realistic multi-line soft-anchor cleanup</h2>\n"
  body <+
    "<p class=\"intro\">These examples keep the complete function in view. Each refactor contains a low-information line that the raw diff can mistake for context and a meaningful unchanged code line that cleanup should promote instead.</p>\n"
  line_case(
    "Configuration parser refactor",
    "the moved blank separator yields to the unchanged endpoint declaration, so the reader sees scanner setup and option parsing as one coherent refactor",
    "<tr><td class=\"ctx\">  let endpoint = resolve_endpoint(scanner, defaults.endpoint)</td><td class=\"ctx\">  let endpoint = resolve_endpoint(scanner, defaults.endpoint)</td></tr>",
    [
      "///|", "fn load_config(input : String, defaults : Config) -> Config raise {",
      "  guard input.trim() != \"\" else { raise ConfigError::Empty }", "  let scanner = Scanner::new(input)",
      "  let endpoint = resolve_endpoint(scanner, defaults.endpoint)", "  let retries = parse_retries(scanner, defaults.retries)",
      "  let timeout = parse_timeout(scanner, defaults.timeout)", "", "  validate_config(endpoint, retries, timeout)",
      "  Config::{ endpoint, retries, timeout }", "}",
    ],
    [
      "///|", "fn load_config(text : String, defaults : Config) -> Config raise {",
      "  guard text.trim() != \"\" else { raise ConfigError::Empty }", "  let scanner = Scanner::new(text)",
      "", "  let endpoint = resolve_endpoint(scanner, defaults.endpoint)", "  let retries = read_retries(scanner, defaults.retries)",
      "  let timeout = read_timeout(scanner, defaults.timeout)", "  validate_config(endpoint, retries, timeout)",
      "  Config::{ endpoint, retries, timeout }", "}",
    ],
  )
  line_case(
    "Expression lowering branch refactor",
    "a repeated arm-closing brace yields to the stable Value fallback, so Call/Invoke, Literal, and Pipe/Pipeline changes stay grouped by semantic match arm",
    "<tr><td class=\"ctx\">    Value(value) =&gt; lower_value(value)</td><td class=\"ctx\">    Value(value) =&gt; lower_value(value)</td></tr>",
    [
      "///|", "fn lower_expr(expr : Expr, context : Context) -> CoreExpr {", "  match expr {",
      "    Call(name, args) => emit_call(name, args, context.options)", "    Value(value) => lower_value(value)",
      "    Literal(value) => { lower_literal(value, context)", "    }", "    Pipe(lhs, rhs) => { emit_pipe(lhs, rhs)",
      "    }", "  }", "}",
    ],
    [
      "///|", "fn lower_expr(expr : Expr, context : Context) -> CoreExpr {", "  match expr {",
      "    Invoke(callee, args) => { emit_call(callee, args, context.options)", "    }",
      "    Value(value) => lower_value(value)", "    Literal(value) => lower_constant(value, context)",
      "    Pipeline(input, stages) => { emit_pipeline(input, stages, context.options)",
      "    }", "  }", "}",
    ],
  )
  line_case(
    "Authorization pipeline reorder",
    "the repeated visual separator yields to the unchanged policy lookup, making the account-resolution, permission-check, and audit changes read in execution order",
    "<tr><td class=\"ctx\">  let policy = policy_for(account)</td><td class=\"ctx\">  let policy = policy_for(account)</td></tr>",
    [
      "///|", "fn authorize(request : Request, store : Store) -> Decision raise {",
      "  let account = store.find_account(request.account_id)", "  let policy = policy_for(account)",
      "  ensure_allowed(policy, request.action)", "  // ----", "  let audit = build_audit(request, account)",
      "  persist_audit(store, audit)", "  // ----", "  Decision::Allow(account.id)",
      "}",
    ],
    [
      "///|", "fn authorize(request : Request, store : Store) -> Decision raise {",
      "  let account = store.resolve_account(request.account_id)", "  // ----", "  let policy = policy_for(account)",
      "  check_permission(policy, request.action)", "  let audit = Audit::from_request(request, account)",
      "  persist_audit(store, audit)", "  // ----", "  Decision::Allow(account.id)",
      "}",
    ],
  )

  fn historical_control(
    title : String,
    source : String,
    old : Array[String],
    new : Array[String],
  ) -> Unit raise {
    let without_cleanup = side_by_side_html(old~, new~, context=1)
    let with_cleanup = side_by_side_html(
      old~,
      new~,
      context=1,
      line_cleanup=true,
    )
    assert_eq(without_cleanup, with_cleanup)
    body <+
      "<details class=\"control\"><summary><span class=\"ok\">✓ unchanged</span> \{esc(title)}</summary>\n"
    body <+ "<p>Source: <code>\{esc(source)}</code></p>\n"
    body <+ "\{with_cleanup}</details>\n"
  }

  body <+ "<h2>Historical no-regression controls</h2>\n"
  body <+
    "<p class=\"intro\">These are intentionally identical with the option off and on. They stay collapsed so controls do not dominate the visual comparison.</p>\n"
  historical_control(
    "token.mbt — Marker classification",
    "2ef6788..184aef2",
    [
      "  Space // inter-token whitespace", "} derive(Eq)", "pub fn weight(k : TokKind) -> Int {",
      "  match k {", "    Word | Str => 20",
    ],
    [
      "  Space // inter-token whitespace", "  Marker // the `///|` block separator",
      "} derive(Eq)", "pub fn weight(k : TokKind) -> Int {", "  match k {", "    Word | Str | Marker => 20",
    ],
  )
  historical_control(
    "distance.mbt — fixed internal DP arrays",
    "44762b7..8068a04",
    [
      "  let m = olds.length()", "  let n = news.length()", "  let dp = Array::makei(m + 1, _ => Array::make(n + 1, 0))",
      "  let bp = Array::makei(m + 1, _ => Array::make(n + 1, 0))", "  for j in 1..<(n + 1) {",
    ],
    [
      "  let m = olds.length()", "  let n = news.length()", "  let dp = FixedArray::makei(m + 1, _ => FixedArray::make(n + 1, 0))",
      "  let bp = FixedArray::makei(m + 1, _ => FixedArray::make(n + 1, 0))", "  for j in 1..<(n + 1) {",
    ],
  )
  historical_control(
    "html.mbt — guard assertion spelling",
    "184aef2..44762b7",
    [
      "        Delete(old_index~, old_len~, ..) => {", "          guard edits[i + 1] is Insert(new_index~, new_len~, ..)",
      "          split_replacement(buf, old_lines, new_lines)", "        }",
    ],
    [
      "        Delete(old_index~, old_len~, ..) => {", "          guard! edits[i + 1] is Insert(new_index~, new_len~, ..)",
      "          split_replacement(buf, old_lines, new_lines)", "        }",
    ],
  )
  t.write(html_page(title="ldiff cleanup comparison", body.to_string()))
  t.snapshot(filename="cleanup_comparison.html")
}
