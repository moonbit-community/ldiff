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

// HTML rendering: a GitHub-style split view and a unified view, both with
// intraline highlights taken from the alignment DP's own traceback.

///|
fn esc(s : String) -> String {
  let buf = StringBuilder::new()
  for c in s {
    match c {
      '&' => buf <+ "&amp;"
      '<' => buf <+ "&lt;"
      '>' => buf <+ "&gt;"
      _ => buf.write_char(c)
    }
  }
  buf.to_string()
}

///|
/// Render one aligned pair's ops as (left row, right row) HTML, merging
/// adjacent highlighted tokens into single runs.
fn pair_row_html(ops : Array[Op]) -> (String, String) {
  let l = StringBuilder::new()
  let r = StringBuilder::new()
  let lrun = StringBuilder::new()
  let rrun = StringBuilder::new()
  fn flushes() {
    if !lrun.is_empty() {
      l <+ "<b class=\"wd\">\{lrun.to_string()}</b>"
      lrun.reset()
    }
    if !rrun.is_empty() {
      r <+ "<b class=\"wa\">\{rrun.to_string()}</b>"
      rrun.reset()
    }
  }

  for op in ops {
    match op {
      OEq(t) => {
        flushes()
        l <+ "\{esc(t.text)}"
        r <+ "\{esc(t.text)}"
      }
      OSub(a, b) => {
        lrun <+ "\{esc(a.text)}"
        rrun <+ "\{esc(b.text)}"
      }
      ODel(a) => lrun <+ "\{esc(a.text)}"
      OIns(b) => rrun <+ "\{esc(b.text)}"
    }
  }
  flushes()
  (l.to_string(), r.to_string())
}

///|
/// Render a replacement block (paired rows and gaps) into the split table.
/// Budget discipline: dimension guards first, then a per-line token cap
/// (which also bounds every budget term, so the counter cannot overflow),
/// then an early-exit cell budget; over budget the whole block renders as
/// PLAIN unpaired rows. Selected pairs additionally get a per-pair traceback
/// guard: an oversized pair stays paired but is rendered without highlights.
fn split_replacement(
  buf : StringBuilder,
  old_lines : ArrayView[String],
  new_lines : ArrayView[String],
) -> Unit {
  fn row(l : String, lc : String, r : String, rc : String) {
    buf <+
      "<tr><td class=\"\{lc}\">\{l}</td><td class=\"\{rc}\">\{r}</td></tr>\n"
  }

  let mut fallback = old_lines.length() > 64 || new_lines.length() > 64
  let olds : Array[Array[Tok]] = []
  let news : Array[Array[Tok]] = []
  if !fallback {
    cap~: for l in old_lines {
      let t = tokenize_line(l)
      if t.length() > 1024 {
        fallback = true
        break cap~
      }
      olds.push(t)
    }
  }
  if !fallback {
    cap~: for l in new_lines {
      let t = tokenize_line(l)
      if t.length() > 1024 {
        fallback = true
        break cap~
      }
      news.push(t)
    }
  }
  if !fallback {
    let mut work = 0
    budget~: for ta in olds {
      for tb in news {
        work += (ta.length() + 1) * (tb.length() + 1)
        if work > 2_000_000 {
          fallback = true
          break budget~
        }
      }
    }
  }
  if fallback {
    for l in old_lines {
      row(esc(l), "del", "", "empty")
    }
    for l in new_lines {
      row("", "empty", esc(l), "add")
    }
  } else {
    for pair in align(olds, news) {
      match pair {
        (Some(ii), Some(jj)) =>
          if (olds[ii].length() + 1) * (news[jj].length() + 1) > 262144 {
            row(esc(old_lines[ii]), "del", esc(new_lines[jj]), "add")
          } else {
            let (lh, rh) = pair_row_html(pair_ops(olds[ii], news[jj]))
            row(lh, "del", rh, "add")
          }
        (Some(ii), None) => row(esc(old_lines[ii]), "del", "", "empty")
        (None, Some(jj)) => row("", "empty", esc(new_lines[jj]), "add")
        (None, None) => ()
      }
    }
  }
}

///|
/// GitHub-style split (side-by-side) view of a diff, as an HTML `<table>`.
/// Equal lines appear on both sides; replacement blocks are aligned by
/// weighted similarity and their paired rows carry word-level highlights;
/// unpaired lines leave the other cell empty. Style it with `html_page` or
/// your own CSS (classes: split, hunk-header, ctx, del, add, empty, wd, wa).
pub fn side_by_side_html(
  old~ : ArrayView[String],
  new~ : ArrayView[String],
  context? : Int = 3,
) -> String {
  let buf = StringBuilder::new()
  buf <+ "<table class=\"split\">\n"
  for h in @diff.Diff(old~, new~).group(context~) {
    buf <+
      "<tr><td class=\"hunk-header\" colspan=\"2\">\{esc(h.header())}</td></tr>\n"
    let edits = h.edits()
    let o = h.old_view()
    let n = h.new_view()
    let mut i = 0
    while i < edits.length() {
      match edits[i] {
        Delete(old_index~, old_len~, ..) if i + 1 < edits.length() &&
          edits[i + 1] is Insert(..) => {
          guard edits[i + 1] is Insert(new_index~, new_len~, ..)
          split_replacement(
            buf,
            o.view(start=old_index, end=old_index + old_len),
            n.view(start=new_index, end=new_index + new_len),
          )
          i += 2
        }
        Equal(old_index~, len~, ..) => {
          for l in o.view(start=old_index, end=old_index + len) {
            buf <+
              "<tr><td class=\"ctx\">\{esc(l)}</td><td class=\"ctx\">\{esc(l)}</td></tr>\n"
          }
          i += 1
        }
        Delete(old_index~, old_len~, ..) => {
          for l in o.view(start=old_index, end=old_index + old_len) {
            buf <+
              "<tr><td class=\"del\">\{esc(l)}</td><td class=\"empty\"></td></tr>\n"
          }
          i += 1
        }
        Insert(new_index~, new_len~, ..) => {
          for l in n.view(start=new_index, end=new_index + new_len) {
            buf <+
              "<tr><td class=\"empty\"></td><td class=\"add\">\{esc(l)}</td></tr>\n"
          }
          i += 1
        }
      }
    }
  }
  buf <+ "</table>\n"
  buf.to_string()
}

///|
/// Wrap rendered diff HTML in a complete standalone page with default
/// styling (light red/green rows, deeper word-level highlights).
pub fn html_page(title~ : String, body : String) -> String {
  let buf = StringBuilder::new()
  buf <+ "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\">"
  buf <+ "<title>\{esc(title)}</title><style>\n"
  buf <+ "body { font-family: monospace; }\n"
  buf <+ ".hunk-header { color: #00a; }\n"
  buf <+ ".del { background: #ffecec; }\n"
  buf <+ ".add { background: #eaffea; }\n"
  buf <+ "td.empty { background: #fafafa; }\n"
  buf <+ "b.wd { background: #f8b4b4; font-weight: normal; }\n"
  buf <+ "b.wa { background: #97e0a0; font-weight: normal; }\n"
  buf <+ "pre.unified span { display: block; }\n"
  buf <+ "table.split { border-collapse: collapse; width: 100%; }\n"
  buf <+ "table.split td { width: 50%; vertical-align: top;\n"
  buf <+ "  white-space: pre-wrap; border: 1px solid #eee; }\n"
  buf <+ "</style></head><body>\n"
  buf <+ "\{body}"
  buf <+ "</body></html>\n"
  buf.to_string()
}

///|
/// Unified (single-column) view of a diff: hunk headers followed by
/// ` `/`-`/`+`-prefixed lines, with the same weighted alignment and
/// word-level highlights as the split view — deletions of a replacement
/// block first, then its insertions. Wrap the result in `<pre>` or use
/// `html_page`.
pub fn unified_html(
  old~ : ArrayView[String],
  new~ : ArrayView[String],
  context? : Int = 3,
) -> String {
  let buf = StringBuilder::new()
  fn line(cls : String, prefix : String, body : String) {
    buf <+ "<span class=\"\{cls}\">\{prefix}\{body}</span>\n"
  }

  buf <+ "<pre class=\"unified\">\n"
  for h in @diff.Diff(old~, new~).group(context~) {
    buf <+ "<span class=\"hunk-header\">\{esc(h.header())}</span>\n"
    let edits = h.edits()
    let o = h.old_view()
    let n = h.new_view()
    let mut i = 0
    while i < edits.length() {
      match edits[i] {
        Delete(old_index~, old_len~, ..) if i + 1 < edits.length() &&
          edits[i + 1] is Insert(..) => {
          guard edits[i + 1] is Insert(new_index~, new_len~, ..)
          let old_lines = o.view(start=old_index, end=old_index + old_len)
          let new_lines = n.view(start=new_index, end=new_index + new_len)
          let mut fallback = old_lines.length() > 64 || new_lines.length() > 64
          let olds : Array[Array[Tok]] = []
          let news : Array[Array[Tok]] = []
          if !fallback {
            cap~: for l in old_lines {
              let t = tokenize_line(l)
              if t.length() > 1024 {
                fallback = true
                break cap~
              }
              olds.push(t)
            }
          }
          if !fallback {
            cap~: for l in new_lines {
              let t = tokenize_line(l)
              if t.length() > 1024 {
                fallback = true
                break cap~
              }
              news.push(t)
            }
          }
          if !fallback {
            let mut work = 0
            budget~: for ta in olds {
              for tb in news {
                work += (ta.length() + 1) * (tb.length() + 1)
                if work > 2_000_000 {
                  fallback = true
                  break budget~
                }
              }
            }
          }
          if fallback {
            for l in old_lines {
              line("del", "-", esc(l))
            }
            for l in new_lines {
              line("add", "+", esc(l))
            }
          } else {
            let pairs = align(olds, news)
            let rights : Array[String] = []
            for pair in pairs {
              match pair {
                (Some(ii), Some(jj)) =>
                  if (olds[ii].length() + 1) * (news[jj].length() + 1) > 262144 {
                    line("del", "-", esc(old_lines[ii]))
                    rights.push(esc(new_lines[jj]))
                  } else {
                    let (lh, rh) = pair_row_html(pair_ops(olds[ii], news[jj]))
                    line("del", "-", lh)
                    rights.push(rh)
                  }
                (Some(ii), None) => line("del", "-", esc(old_lines[ii]))
                (None, Some(jj)) => rights.push(esc(new_lines[jj]))
                (None, None) => ()
              }
            }
            for r in rights {
              line("add", "+", r)
            }
          }
          i += 2
        }
        Equal(old_index~, len~, ..) => {
          for l in o.view(start=old_index, end=old_index + len) {
            line("ctx", " ", esc(l))
          }
          i += 1
        }
        Delete(old_index~, old_len~, ..) => {
          for l in o.view(start=old_index, end=old_index + old_len) {
            line("del", "-", esc(l))
          }
          i += 1
        }
        Insert(new_index~, new_len~, ..) => {
          for l in n.view(start=new_index, end=new_index + new_len) {
            line("add", "+", esc(l))
          }
          i += 1
        }
      }
    }
  }
  buf <+ "</pre>\n"
  buf.to_string()
}
