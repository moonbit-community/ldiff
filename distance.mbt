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
/// The four traceback states distinguish a closed edit run from an open run
/// that has consumed old tokens, new tokens, or both. Keeping this state in
/// the DP makes opening and closing boundary scores globally composable.
const PAIR_EQUAL : Int = 0

///|
const PAIR_OLD_CHANGED : Int = 1

///|
const PAIR_NEW_CHANGED : Int = 2

///|
const PAIR_BOTH_CHANGED : Int = 3

///|
const PAIR_STATE_COUNT : Int = 4

///|
/// Lexicographic path score. Lower edit cost and run count win; all other
/// fields are maximized in the order used by `pair_score_better`.
priv struct PairScore {
  cost : Int
  exact : Int
  runs : Int
  boundary : Int
  right : Int
}

///|
fn pair_unreachable_score() -> PairScore {
  { cost: 1_000_000_000, exact: 0, runs: 0, boundary: 0, right: 0 }
}

///|
fn pair_score_better(a : PairScore, b : PairScore) -> Bool {
  if a.cost != b.cost {
    a.cost < b.cost
  } else if a.exact != b.exact {
    a.exact > b.exact
  } else if a.runs != b.runs {
    a.runs < b.runs
  } else if a.boundary != b.boundary {
    a.boundary > b.boundary
  } else {
    a.right > b.right
  }
}

///|
fn pair_score_equal(a : PairScore, b : PairScore) -> Bool {
  a.cost == b.cost &&
  a.exact == b.exact &&
  a.runs == b.runs &&
  a.boundary == b.boundary &&
  a.right == b.right
}

///|
fn pair_has_old(state : Int) -> Bool {
  state == PAIR_OLD_CHANGED || state == PAIR_BOTH_CHANGED
}

///|
fn pair_has_new(state : Int) -> Bool {
  state == PAIR_NEW_CHANGED || state == PAIR_BOTH_CHANGED
}

///|
fn pair_changed_state(
  state : Int,
  consumes_old : Bool,
  consumes_new : Bool,
) -> Int {
  let has_old = pair_has_old(state) || consumes_old
  let has_new = pair_has_new(state) || consumes_new
  if has_old && has_new {
    PAIR_BOTH_CHANGED
  } else if has_old {
    PAIR_OLD_CHANGED
  } else {
    PAIR_NEW_CHANGED
  }
}

///|
/// Boundary immediately before token `index`. `None` is used only for the
/// real beginning of the complete token line.
fn pair_open_boundary(tokens : ArrayView[Tok], index : Int) -> Int {
  let left = if index == 0 { None } else { Some(tokens[index - 1]) }
  token_boundary_score(left, Some(tokens[index]))
}

///|
/// Boundary immediately after the consumed prefix ending at `index - 1`.
/// `None` is used only for the real end of the complete token line.
fn pair_close_boundary(tokens : ArrayView[Tok], index : Int) -> Int {
  let right = if index == tokens.length() { None } else { Some(tokens[index]) }
  token_boundary_score(Some(tokens[index - 1]), right)
}

///|
/// Whitespace and comment boilerplate carry no positional evidence. This
/// keeps an equivalent leading/trailing spacer from moving a semantic edit;
/// meaningful changed tokens still resolve otherwise exact ties to the right.
fn pair_changed_position(tokens : ArrayView[Tok], index : Int) -> Int {
  if tokens[index].kind is (Space | Filler) {
    0
  } else {
    index
  }
}

///|
fn pair_changed_score(
  score : PairScore,
  state : Int,
  a : ArrayView[Tok],
  b : ArrayView[Tok],
  old_index : Int,
  new_index : Int,
  edit_cost : Int,
) -> PairScore {
  let consumes_old = old_index >= 0
  let consumes_new = new_index >= 0
  let mut boundary = score.boundary
  if consumes_old && !pair_has_old(state) {
    boundary += pair_open_boundary(a, old_index)
  }
  if consumes_new && !pair_has_new(state) {
    boundary += pair_open_boundary(b, new_index)
  }
  {
    cost: score.cost + edit_cost,
    exact: score.exact,
    runs: score.runs + (if state == PAIR_EQUAL { 1 } else { 0 }),
    boundary,
    right: score.right +
    (if consumes_old { pair_changed_position(a, old_index) } else { 0 }) +
    (if consumes_new { pair_changed_position(b, new_index) } else { 0 }),
  }
}

///|
fn pair_equal_score(
  score : PairScore,
  state : Int,
  a : ArrayView[Tok],
  b : ArrayView[Tok],
  old_index : Int,
  new_index : Int,
) -> PairScore {
  let mut boundary = score.boundary
  if pair_has_old(state) {
    boundary += pair_close_boundary(a, old_index)
  }
  if pair_has_new(state) {
    boundary += pair_close_boundary(b, new_index)
  }
  let evidence = weight(a[old_index].kind)
  {
    cost: score.cost,
    exact: score.exact + (if evidence > 0 { evidence } else { 1 }),
    runs: score.runs,
    boundary,
    right: score.right,
  }
}

///|
fn pair_finish_score(
  score : PairScore,
  state : Int,
  a : ArrayView[Tok],
  b : ArrayView[Tok],
) -> PairScore {
  if score.cost == pair_unreachable_score().cost {
    return score
  }
  let mut boundary = score.boundary
  if pair_has_old(state) {
    boundary += pair_close_boundary(a, a.length())
  }
  if pair_has_new(state) {
    boundary += pair_close_boundary(b, b.length())
  }
  { ..score, boundary, }
}

///|
fn pair_row_index(column : Int, state : Int) -> Int {
  column * PAIR_STATE_COUNT + state
}

///|
fn pair_backpointer_index(
  row : Int,
  column : Int,
  width : Int,
  state : Int,
) -> Int {
  (row * width + column) * PAIR_STATE_COUNT + state
}

///|
/// Store one candidate. Backpointer ways are 1 diagonal, 2 insert, 3 delete;
/// their numeric order supplies the final deterministic tie preference.
fn pair_consider(
  scores : FixedArray[PairScore],
  score_index : Int,
  backpointers : FixedArray[Int],
  backpointer_index : Int,
  candidate : PairScore,
  previous_state : Int,
  way : Int,
) -> Unit {
  let current = scores[score_index]
  let current_way = backpointers[backpointer_index] % PAIR_STATE_COUNT
  if pair_score_better(candidate, current) ||
    (
      pair_score_equal(candidate, current) &&
      (current_way == 0 || way < current_way)
    ) {
    scores[score_index] = candidate
    backpointers[backpointer_index] = previous_state * PAIR_STATE_COUNT + way
  }
}

///|
/// Global minimum-cost traceback for one aligned pair. Equal-cost paths are
/// selected by exact evidence, changed-run count, real line boundaries, and
/// rightmost changed-token placement, then diagonal > insert > delete.
/// Scores use rolling rows while all four-state backpointers are retained.
fn pair_ops_min(a : ArrayView[Tok], b : ArrayView[Tok]) -> Array[Op] {
  let m = a.length()
  let n = b.length()
  let width = n + 1
  let row_size = width * PAIR_STATE_COUNT
  let impossible = pair_unreachable_score()
  let mut prev = FixedArray::make(row_size, impossible)
  let mut cur = FixedArray::make(row_size, impossible)
  let backpointers = FixedArray::make((m + 1) * width * PAIR_STATE_COUNT, 0)
  prev[pair_row_index(0, PAIR_EQUAL)] = {
    cost: 0,
    exact: 0,
    runs: 0,
    boundary: 0,
    right: 0,
  }
  for j in 1..<(n + 1) {
    for state in 0..<PAIR_STATE_COUNT {
      let source = prev[pair_row_index(j - 1, state)]
      if source.cost == impossible.cost {
        continue
      }
      let candidate = pair_changed_score(
        source,
        state,
        a,
        b,
        -1,
        j - 1,
        weight(b[j - 1].kind),
      )
      let next_state = pair_changed_state(state, false, true)
      pair_consider(
        prev,
        pair_row_index(j, next_state),
        backpointers,
        pair_backpointer_index(0, j, width, next_state),
        candidate,
        state,
        2,
      )
    }
  }
  for i in 1..<(m + 1) {
    cur.fill(impossible)
    for state in 0..<PAIR_STATE_COUNT {
      let source = prev[pair_row_index(0, state)]
      if source.cost == impossible.cost {
        continue
      }
      let candidate = pair_changed_score(
        source,
        state,
        a,
        b,
        i - 1,
        -1,
        weight(a[i - 1].kind),
      )
      let next_state = pair_changed_state(state, true, false)
      pair_consider(
        cur,
        pair_row_index(0, next_state),
        backpointers,
        pair_backpointer_index(i, 0, width, next_state),
        candidate,
        state,
        3,
      )
    }
    for j in 1..<(n + 1) {
      for state in 0..<PAIR_STATE_COUNT {
        let delete_source = prev[pair_row_index(j, state)]
        if delete_source.cost != impossible.cost {
          let candidate = pair_changed_score(
            delete_source,
            state,
            a,
            b,
            i - 1,
            -1,
            weight(a[i - 1].kind),
          )
          let next_state = pair_changed_state(state, true, false)
          pair_consider(
            cur,
            pair_row_index(j, next_state),
            backpointers,
            pair_backpointer_index(i, j, width, next_state),
            candidate,
            state,
            3,
          )
        }
        let insert_source = cur[pair_row_index(j - 1, state)]
        if insert_source.cost != impossible.cost {
          let candidate = pair_changed_score(
            insert_source,
            state,
            a,
            b,
            -1,
            j - 1,
            weight(b[j - 1].kind),
          )
          let next_state = pair_changed_state(state, false, true)
          pair_consider(
            cur,
            pair_row_index(j, next_state),
            backpointers,
            pair_backpointer_index(i, j, width, next_state),
            candidate,
            state,
            2,
          )
        }
        let diagonal_source = prev[pair_row_index(j - 1, state)]
        if diagonal_source.cost != impossible.cost {
          if a[i - 1].kind == b[j - 1].kind && a[i - 1].text == b[j - 1].text {
            let candidate = pair_equal_score(
              diagonal_source,
              state,
              a,
              b,
              i - 1,
              j - 1,
            )
            pair_consider(
              cur,
              pair_row_index(j, PAIR_EQUAL),
              backpointers,
              pair_backpointer_index(i, j, width, PAIR_EQUAL),
              candidate,
              state,
              1,
            )
          } else {
            match subst_cost(a[i - 1], b[j - 1]) {
              Some(cost) => {
                let candidate = pair_changed_score(
                  diagonal_source,
                  state,
                  a,
                  b,
                  i - 1,
                  j - 1,
                  cost,
                )
                let next_state = pair_changed_state(state, true, true)
                pair_consider(
                  cur,
                  pair_row_index(j, next_state),
                  backpointers,
                  pair_backpointer_index(i, j, width, next_state),
                  candidate,
                  state,
                  1,
                )
              }
              None => ()
            }
          }
        }
      }
    }
    let tmp = prev
    prev = cur
    cur = tmp
  }
  let mut best_state = PAIR_EQUAL
  let mut best = impossible
  let mut best_way = PAIR_STATE_COUNT
  for state in 0..<PAIR_STATE_COUNT {
    let candidate = pair_finish_score(
      prev[pair_row_index(n, state)],
      state,
      a,
      b,
    )
    let way = backpointers[pair_backpointer_index(m, n, width, state)] %
      PAIR_STATE_COUNT
    if pair_score_better(candidate, best) ||
      (pair_score_equal(candidate, best) && way < best_way) {
      best = candidate
      best_state = state
      best_way = way
    }
  }
  let out : Array[Op] = []
  let mut i = m
  let mut j = n
  let mut state = best_state
  while i > 0 || j > 0 {
    let pointer = backpointers[pair_backpointer_index(i, j, width, state)]
    let way = pointer % PAIR_STATE_COUNT
    let previous_state = pointer / PAIR_STATE_COUNT
    match way {
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
    state = previous_state
  }
  out.rev_in_place()
  out
}

///|
fn pair_ops(a : Array[Tok], b : Array[Tok]) -> Array[Op] {
  pair_ops_min(a, b)
}
