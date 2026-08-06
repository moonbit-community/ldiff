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

// Weighted token alignment: all-integer Wagner-Fischer scoring (weights x20,
// similarity in permille, stored backpointers) so results are bit-identical
// on every backend. Design and thresholds hardened through adversarial
// review; see README.

///|
/// Same-kind substitution at 1.5x the class weight: cheaper than
/// delete+insert (2x) so renames align, but expensive enough that two lines
/// with nothing in common score ~250 permille, under the pairing threshold.
/// Cross-kind substitution is not offered; it decomposes into delete+insert.
fn subst_cost(a : Tok, b : Tok) -> Int? {
  if a.kind == b.kind {
    if a.text == b.text {
      Some(0)
    } else {
      Some(weight(a.kind) * 3 / 2)
    }
  } else {
    None
  }
}

///|
fn tok_mass(ts : ArrayView[Tok]) -> Int {
  let mut m = 0
  for t in ts {
    m += weight(t.kind)
  }
  m
}

///|
/// Weighted token edit distance (scoring only: rolling rows).
fn wdist(a : ArrayView[Tok], b : ArrayView[Tok]) -> Int {
  let n = b.length()
  let mut prev = Array::make(n + 1, 0)
  let mut acc = 0
  for j in 1..<(n + 1) {
    acc += weight(b[j - 1].kind)
    prev[j] = acc
  }
  let mut cur = Array::make(n + 1, 0)
  for i in 1..<(a.length() + 1) {
    cur[0] = prev[0] + weight(a[i - 1].kind)
    for j in 1..<(n + 1) {
      let del = prev[j] + weight(a[i - 1].kind)
      let ins = cur[j - 1] + weight(b[j - 1].kind)
      let mut best = if del < ins { del } else { ins }
      match subst_cost(a[i - 1], b[j - 1]) {
        Some(c) => if prev[j - 1] + c < best { best = prev[j - 1] + c }
        None => ()
      }
      cur[j] = best
    }
    let t = prev
    prev = cur
    cur = t
  }
  prev[n]
}

///|
/// Line similarity in permille: `1000 * (mass - dist) / mass` over both
/// sides' weighted mass. Zero-mass lines (empty or filler-only) carry no
/// evidence either way and pair only when textually identical.
pub fn similarity(a : String, b : String) -> Int {
  sim_toks(tokenize_line(a), tokenize_line(b))
}

///|
fn sim_toks(a : ArrayView[Tok], b : ArrayView[Tok]) -> Int {
  let m = tok_mass(a) + tok_mass(b)
  if m == 0 {
    if a.length() != b.length() {
      return 0
    }
    for i in 0..<a.length() {
      if a[i].kind != b[i].kind || a[i].text != b[i].text {
        return 0
      }
    }
    return 1000
  }
  (m - wdist(a, b)) * 1000 / m
}

///|
/// Pairing threshold in permille.
const THETA : Int = 400

///|
/// Monotone alignment of a replacement block, maximizing the total positive
/// margin `sum(sim - THETA)`; a pair is only usable when its margin is
/// positive. Deterministic: integer scores, stored backpointers, tie
/// preference diag > left > up (delete-before-insert in forward order).
fn align(
  olds : Array[Array[Tok]],
  news : Array[Array[Tok]],
) -> Array[(Int?, Int?)] {
  let m = olds.length()
  let n = news.length()
  let dp = FixedArray::makei(m + 1, _ => FixedArray::make(n + 1, 0))
  let bp = FixedArray::makei(m + 1, _ => FixedArray::make(n + 1, 0)) // 1 diag, 2 left, 3 up
  for j in 1..<(n + 1) {
    bp[0][j] = 2
  }
  for i in 1..<(m + 1) {
    bp[i][0] = 3
    for j in 1..<(n + 1) {
      let margin = sim_toks(olds[i - 1][:], news[j - 1][:]) - THETA
      let mut best = dp[i][j - 1]
      let mut way = 2
      if dp[i - 1][j] > best {
        best = dp[i - 1][j]
        way = 3
      }
      if margin > 0 && dp[i - 1][j - 1] + margin >= best {
        best = dp[i - 1][j - 1] + margin
        way = 1
      }
      dp[i][j] = best
      bp[i][j] = way
    }
  }
  let out : Array[(Int?, Int?)] = []
  let mut i = m
  let mut j = n
  while i > 0 || j > 0 {
    match bp[i][j] {
      1 => {
        out.push((Some(i - 1), Some(j - 1)))
        i -= 1
        j -= 1
      }
      2 => {
        out.push((None, Some(j - 1)))
        j -= 1
      }
      _ => {
        out.push((Some(i - 1), None))
        i -= 1
      }
    }
  }
  out.rev_in_place()
  out
}

///|
/// Tokenized inputs for one bounded line-alignment window.
priv struct AlignmentTokens {
  olds : Array[Array[Tok]]
  news : Array[Array[Tok]]
}

///|
/// Apply the shared replacement-window budgets before invoking `align`:
/// at most 64 lines per side, 1024 tokens per line, and 2M aggregate token
/// DP cells. Returning `None` means the caller must preserve its original
/// structure and render without inferred pairing/highlighting.
fn[T] alignment_tokens(
  old_lines : ArrayView[T],
  new_lines : ArrayView[T],
  line_text : (T) -> String,
) -> AlignmentTokens? {
  if old_lines.length() > 64 || new_lines.length() > 64 {
    return None
  }
  let olds : Array[Array[Tok]] = []
  for line in old_lines {
    let toks = tokenize_line(line_text(line))
    if toks.length() > 1024 {
      return None
    }
    olds.push(toks)
  }
  let news : Array[Array[Tok]] = []
  for line in new_lines {
    let toks = tokenize_line(line_text(line))
    if toks.length() > 1024 {
      return None
    }
    news.push(toks)
  }
  let mut work = 0
  for ta in olds {
    for tb in news {
      work += (ta.length() + 1) * (tb.length() + 1)
      if work > 2_000_000 {
        return None
      }
    }
  }
  Some({ olds, news })
}

///|
priv enum Op {
  OEq(Tok)
  OSub(Tok, Tok)
  ODel(Tok)
  OIns(Tok)
}

///|
/// Minimum-cost traceback for one aligned pair, before lossless boundary
/// cleanup. Backward tie preference diag > left > up yields delete-before-
/// insert forward order.
fn pair_ops_min(a : ArrayView[Tok], b : ArrayView[Tok]) -> Array[Op] {
  let m = a.length()
  let n = b.length()
  let dp = FixedArray::makei(m + 1, _ => FixedArray::make(n + 1, 0))
  let bp = FixedArray::makei(m + 1, _ => FixedArray::make(n + 1, 0))
  for j in 1..<(n + 1) {
    dp[0][j] = dp[0][j - 1] + weight(b[j - 1].kind)
    bp[0][j] = 2
  }
  for i in 1..<(m + 1) {
    dp[i][0] = dp[i - 1][0] + weight(a[i - 1].kind)
    bp[i][0] = 3
    for j in 1..<(n + 1) {
      let mut best = dp[i - 1][j] + weight(a[i - 1].kind)
      let mut way = 3
      let ins = dp[i][j - 1] + weight(b[j - 1].kind)
      if ins <= best {
        best = ins
        way = 2
      }
      match subst_cost(a[i - 1], b[j - 1]) {
        Some(c) =>
          if dp[i - 1][j - 1] + c <= best {
            best = dp[i - 1][j - 1] + c
            way = 1
          }
        None => ()
      }
      dp[i][j] = best
      bp[i][j] = way
    }
  }
  let out : Array[Op] = []
  let mut i = m
  let mut j = n
  while i > 0 || j > 0 {
    match bp[i][j] {
      1 => {
        if a[i - 1].kind == b[j - 1].kind && a[i - 1].text == b[j - 1].text {
          out.push(OEq(a[i - 1]))
        } else {
          out.push(OSub(a[i - 1], b[j - 1]))
        }
        i -= 1
        j -= 1
      }
      2 => {
        out.push(OIns(b[j - 1]))
        j -= 1
      }
      _ => {
        out.push(ODel(a[i - 1]))
        i -= 1
      }
    }
  }
  out.rev_in_place()
  out
}

///|
/// One alternating chunk in a pair traceback. `PairEdit` keeps only the two
/// reconstructed token spans; its minimum-cost operations are regenerated
/// after lossless boundary placement.
priv enum PairChunk {
  PairEqual(Array[Tok])
  PairEdit(Array[Tok], Array[Tok])
}

///|
fn same_tok(a : Tok, b : Tok) -> Bool {
  a.kind == b.kind && a.text == b.text
}

///|
fn same_toks(a : ArrayView[Tok], b : ArrayView[Tok]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i in 0..<a.length() {
    if !same_tok(a[i], b[i]) {
      return false
    }
  }
  true
}

///|
fn append_toks(out : Array[Tok], xs : ArrayView[Tok]) -> Unit {
  for x in xs {
    out.push(x)
  }
}

///|
fn concat_toks(
  left : ArrayView[Tok],
  middle : ArrayView[Tok],
  right : ArrayView[Tok],
) -> Array[Tok] {
  let out : Array[Tok] = []
  append_toks(out, left)
  append_toks(out, middle)
  append_toks(out, right)
  out
}

///|
/// Naturalness of a boundary between two adjacent token spans. The score is
/// deliberately language-class based (not character based): line ends win,
/// then whitespace/comment filler, punctuation, and a token-kind transition.
fn token_boundary_score(left : Tok?, right : Tok?) -> Int {
  match (left, right) {
    (None, _) | (_, None) => 4
    (Some(a), Some(b)) =>
      if a.kind is (Space | Filler) || b.kind is (Space | Filler) {
        3
      } else if a.kind is Punct || b.kind is Punct {
        2
      } else if a.kind != b.kind {
        1
      } else {
        0
      }
  }
}

///|
fn edit_span_score(tokens : Array[Tok], start : Int, len : Int) -> Int {
  if len == 0 {
    0
  } else {
    token_boundary_score(tokens.get(start - 1), tokens.get(start)) +
    token_boundary_score(tokens.get(start + len - 1), tokens.get(start + len))
  }
}

///|
fn ops_to_chunks(ops : ArrayView[Op]) -> Array[PairChunk] {
  let chunks : Array[PairChunk] = [PairEqual([])]
  let equals : Array[Tok] = []
  let old_edit : Array[Tok] = []
  let new_edit : Array[Tok] = []
  let mut in_edit = false
  fn flush_equal() {
    if !equals.is_empty() {
      guard! chunks.last() is Some(PairEqual(current))
      append_toks(current, equals)
      equals.clear()
    }
  }

  fn flush_edit() {
    if in_edit {
      chunks.push(PairEdit(old_edit.copy(), new_edit.copy()))
      chunks.push(PairEqual([]))
      old_edit.clear()
      new_edit.clear()
      in_edit = false
    }
  }

  for op in ops {
    match op {
      OEq(t) => {
        flush_edit()
        equals.push(t)
      }
      OSub(a, b) => {
        flush_equal()
        in_edit = true
        old_edit.push(a)
        new_edit.push(b)
      }
      ODel(a) => {
        flush_equal()
        in_edit = true
        old_edit.push(a)
      }
      OIns(b) => {
        flush_equal()
        in_edit = true
        new_edit.push(b)
      }
    }
  }
  flush_edit()
  flush_equal()
  chunks
}

///|
/// Enumerate every left/right rotation of one edit span that leaves equal
/// prefixes and suffixes on both reconstructions. Only candidates whose
/// weighted edit distance is unchanged are eligible. Iteration is left to
/// right and `>=` resolves score ties to the stable rightmost placement.
fn cleanup_edit_chunk(
  left : Array[Tok],
  old_edit : Array[Tok],
  new_edit : Array[Tok],
  right : Array[Tok],
) -> (Array[Tok], Array[Tok], Array[Tok], Array[Tok]) {
  let old_all = concat_toks(left, old_edit, right)
  let new_all = concat_toks(left, new_edit, right)
  let old_len = old_edit.length()
  let new_len = new_edit.length()
  let original_cost = wdist(old_edit, new_edit)
  let mut best_shift = 0
  let mut best_score = edit_span_score(old_all, left.length(), old_len) +
    edit_span_score(new_all, left.length(), new_len)
  for shift in -left.length()..<=right.length() {
    let start = left.length() + shift
    let old_end = start + old_len
    let new_end = start + new_len
    let old_prefix = old_all.view(end=start)
    let new_prefix = new_all.view(end=start)
    let old_suffix = old_all.view(start=old_end)
    let new_suffix = new_all.view(start=new_end)
    if !same_toks(old_prefix, new_prefix) || !same_toks(old_suffix, new_suffix) {
      continue
    }
    let old_candidate = old_all.view(start~, end=old_end)
    let new_candidate = new_all.view(start~, end=new_end)
    if wdist(old_candidate, new_candidate) != original_cost {
      continue
    }
    let score = edit_span_score(old_all, start, old_len) +
      edit_span_score(new_all, start, new_len)
    if score >= best_score {
      best_score = score
      best_shift = shift
    }
  }
  let start = left.length() + best_shift
  let old_end = start + old_len
  let new_end = start + new_len
  (
    old_all.view(end=start).to_owned(),
    old_all.view(start~, end=old_end).to_owned(),
    new_all.view(start~, end=new_end).to_owned(),
    old_all.view(start=old_end).to_owned(),
  )
}

///|
/// Lossless token-boundary cleanup layered on the minimum weighted
/// traceback. It never changes either reconstruction or the scored `wdist`;
/// it only chooses a more natural, deterministic placement among equivalent
/// rotations of an edit span.
fn pair_ops(a : Array[Tok], b : Array[Tok]) -> Array[Op] {
  let chunks = ops_to_chunks(pair_ops_min(a, b))
  for i in 1..<(chunks.length() - 1) {
    guard chunks[i] is PairEdit(old_edit, new_edit) else { continue }
    guard! chunks[i - 1] is PairEqual(left)
    guard! chunks[i + 1] is PairEqual(right)
    let (new_left, new_old_edit, new_new_edit, new_right) = cleanup_edit_chunk(
      left, old_edit, new_edit, right,
    )
    chunks[i - 1] = PairEqual(new_left)
    chunks[i] = PairEdit(new_old_edit, new_new_edit)
    chunks[i + 1] = PairEqual(new_right)
  }
  let out : Array[Op] = []
  for chunk in chunks {
    match chunk {
      PairEqual(ts) =>
        for t in ts {
          out.push(OEq(t))
        }
      PairEdit(old_edit, new_edit) =>
        for op in pair_ops_min(old_edit, new_edit) {
          out.push(op)
        }
    }
  }
  out
}
