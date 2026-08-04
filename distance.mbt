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
priv enum Op {
  OEq(Tok)
  OSub(Tok, Tok)
  ODel(Tok)
  OIns(Tok)
}

///|
/// Full traceback for one aligned pair: the highlight script IS the scored
/// script (score == rendering). Backward tie preference diag > left > up
/// yields delete-before-insert forward order.
fn pair_ops(a : Array[Tok], b : Array[Tok]) -> Array[Op] {
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
