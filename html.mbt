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
/// One renderer-neutral row in a prepared replacement block. `None` means an
/// absent side; `Some("")` is a present blank line and must remain distinct.
priv struct ReplacementRow {
  old_html : String?
  new_html : String?
  old_offset : Int?
  new_offset : Int?
}

///|
/// Prepare replacement pairing and intraline markup once for both HTML
/// views. The shared alignment budgets return plain, unpaired rows. A chosen
/// pair beyond 262144 traceback cells remains paired but carries no `<b>`
/// highlight, preserving the existing deterministic safety fallback.
fn prepare_replacement(
  old_lines : ArrayView[DiffLine],
  new_lines : ArrayView[DiffLine],
) -> Array[ReplacementRow] {
  let rows : Array[ReplacementRow] = []
  match alignment_tokens(old_lines, new_lines, line => line.text) {
    None => {
      for offset, line in old_lines {
        rows.push({
          old_html: Some(esc(line.text)),
          new_html: None,
          old_offset: Some(offset),
          new_offset: None,
        })
      }
      for offset, line in new_lines {
        rows.push({
          old_html: None,
          new_html: Some(esc(line.text)),
          old_offset: None,
          new_offset: Some(offset),
        })
      }
    }
    Some(tokens) =>
      for pair in align(tokens.olds, tokens.news) {
        match pair {
          (Some(old_index), Some(new_index)) => {
            let (old_html, new_html) = if (tokens.olds[old_index].length() + 1) *
              (tokens.news[new_index].length() + 1) >
              262144 {
              (esc(old_lines[old_index].text), esc(new_lines[new_index].text))
            } else {
              pair_row_html(
                pair_ops(tokens.olds[old_index], tokens.news[new_index]),
              )
            }
            rows.push({
              old_html: Some(old_html),
              new_html: Some(new_html),
              old_offset: Some(old_index),
              new_offset: Some(new_index),
            })
          }
          (Some(old_index), None) =>
            rows.push({
              old_html: Some(esc(old_lines[old_index].text)),
              new_html: None,
              old_offset: Some(old_index),
              new_offset: None,
            })
          (None, Some(new_index)) =>
            rows.push({
              old_html: None,
              new_html: Some(esc(new_lines[new_index].text)),
              old_offset: None,
              new_offset: Some(new_index),
            })
          (None, None) => ()
        }
      }
  }
  rows
}

///|
fn line_number_text(number : Int?) -> String {
  match number {
    Some(value) => value.to_string()
    None => ""
  }
}

///|
fn split_row(
  buf : StringBuilder,
  old_number : Int?,
  old_class : String,
  old_html : String,
  new_number : Int?,
  new_class : String,
  new_html : String,
  line_numbers : Bool,
) -> Unit {
  if line_numbers {
    buf <+
      "<tr><td class=\"line-number old-line-number\">\{line_number_text(old_number)}</td><td class=\"\{old_class}\">\{old_html}</td><td class=\"line-number new-line-number\">\{line_number_text(new_number)}</td><td class=\"\{new_class}\">\{new_html}</td></tr>\n"
  } else {
    buf <+
      "<tr><td class=\"\{old_class}\">\{old_html}</td><td class=\"\{new_class}\">\{new_html}</td></tr>\n"
  }
}

///|
fn split_replacement(
  buf : StringBuilder,
  old_lines : ArrayView[DiffLine],
  new_lines : ArrayView[DiffLine],
  old_start : Int,
  new_start : Int,
  line_numbers : Bool,
) -> Unit {
  for prepared in prepare_replacement(old_lines, new_lines) {
    let (old_html, old_class) = match prepared.old_html {
      Some(body) => (body, "del")
      None => ("", "empty")
    }
    let (new_html, new_class) = match prepared.new_html {
      Some(body) => (body, "add")
      None => ("", "empty")
    }
    split_row(
      buf,
      prepared.old_offset.map(offset => old_start + offset + 1),
      old_class,
      old_html,
      prepared.new_offset.map(offset => new_start + offset + 1),
      new_class,
      new_html,
      line_numbers,
    )
  }
}

///|
/// GitHub-style split (side-by-side) view of a diff, as an HTML `<table>`.
/// Equal lines appear on both sides; replacement blocks are aligned by
/// weighted similarity and their paired rows carry word-level highlights;
/// unpaired lines leave the other cell empty. Style it with `html_page` or
/// your own CSS (classes: split, hunk-header, ctx, del, add, empty, wd, wa,
/// line-number, old-line-number, new-line-number).
/// Set `line_cleanup=true` to reopen bounded low-information equal anchors;
/// it is disabled by default. Set `line_numbers=true` for old-number,
/// old-code, new-number, new-code columns; it is disabled by default so the
/// historical two-column HTML remains byte-for-byte unchanged.
pub fn side_by_side_html(
  old~ : ArrayView[String],
  new~ : ArrayView[String],
  context? : Int = 3,
  line_cleanup? : Bool = false,
  line_numbers? : Bool = false,
) -> String {
  let buf = StringBuilder::new()
  buf <+ "<table class=\"split\">\n"
  for h in rendering_diff(old, new, line_cleanup).group(context~) {
    if line_numbers {
      buf <+
        "<tr><td class=\"hunk-header\" colspan=\"4\">\{esc(h.header())}</td></tr>\n"
    } else {
      buf <+
        "<tr><td class=\"hunk-header\" colspan=\"2\">\{esc(h.header())}</td></tr>\n"
    }
    let edits = h.edits()
    let o = h.old_view()
    let n = h.new_view()
    let mut i = 0
    while i < edits.length() {
      match edits[i] {
        Delete(old_index~, old_len~, ..) if i + 1 < edits.length() &&
          edits[i + 1] is Insert(..) => {
          guard! edits[i + 1] is Insert(new_index~, new_len~, ..)
          split_replacement(
            buf,
            o.view(start=old_index, end=old_index + old_len),
            n.view(start=new_index, end=new_index + new_len),
            old_index,
            new_index,
            line_numbers,
          )
          i += 2
        }
        Equal(old_index~, new_index~, len~) => {
          for offset, l in o.view(start=old_index, end=old_index + len) {
            split_row(
              buf,
              Some(old_index + offset + 1),
              "ctx",
              esc(l.text),
              Some(new_index + offset + 1),
              "ctx",
              esc(l.text),
              line_numbers,
            )
          }
          i += 1
        }
        Delete(old_index~, old_len~, ..) => {
          for offset, l in o.view(start=old_index, end=old_index + old_len) {
            split_row(
              buf,
              Some(old_index + offset + 1),
              "del",
              esc(l.text),
              None,
              "empty",
              "",
              line_numbers,
            )
          }
          i += 1
        }
        Insert(new_index~, new_len~, ..) => {
          for offset, l in n.view(start=new_index, end=new_index + new_len) {
            split_row(
              buf,
              None,
              "empty",
              "",
              Some(new_index + offset + 1),
              "add",
              esc(l.text),
              line_numbers,
            )
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
  buf <+
    "table.split, table.unified { border-collapse: collapse; width: 100%; }\n"
  buf <+ "table.split td { width: 50%; vertical-align: top;\n"
  buf <+ "  white-space: pre-wrap; border: 1px solid #eee; }\n"
  buf <+
    "table.unified td { vertical-align: top; white-space: pre-wrap; border: 1px solid #eee; }\n"
  buf <+ "td.line-number { width: 1%; min-width: 3em; padding: 0 .5em;\n"
  buf <+
    "  color: #6e7781; background: #f6f8fa; text-align: right; user-select: none; }\n"
  buf <+ "table.unified td:last-child { width: 100%; }\n"
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
/// `html_page`. Set `line_cleanup=true` to opt into bounded soft-anchor
/// cleanup; it is disabled by default. Set `line_numbers=true` to render a
/// three-column table containing old number, new number, and prefixed code;
/// it is disabled by default so the historical `<pre>` HTML is unchanged.
pub fn unified_html(
  old~ : ArrayView[String],
  new~ : ArrayView[String],
  context? : Int = 3,
  line_cleanup? : Bool = false,
  line_numbers? : Bool = false,
) -> String {
  let buf = StringBuilder::new()
  fn line(cls : String, prefix : String, body : String) {
    buf <+ "<span class=\"\{cls}\">\{prefix}\{body}</span>\n"
  }
  fn numbered_line(
    cls : String,
    prefix : String,
    old_number : Int?,
    new_number : Int?,
    body : String,
  ) {
    buf <+
      "<tr><td class=\"line-number old-line-number\">\{line_number_text(old_number)}</td><td class=\"line-number new-line-number\">\{line_number_text(new_number)}</td><td class=\"\{cls}\">\{prefix}\{body}</td></tr>\n"
  }

  if line_numbers {
    buf <+ "<table class=\"unified numbered\">\n"
  } else {
    buf <+ "<pre class=\"unified\">\n"
  }
  for h in rendering_diff(old, new, line_cleanup).group(context~) {
    if line_numbers {
      buf <+
        "<tr><td class=\"hunk-header\" colspan=\"3\">\{esc(h.header())}</td></tr>\n"
    } else {
      buf <+ "<span class=\"hunk-header\">\{esc(h.header())}</span>\n"
    }
    let edits = h.edits()
    let o = h.old_view()
    let n = h.new_view()
    let mut i = 0
    while i < edits.length() {
      match edits[i] {
        Delete(old_index~, old_len~, ..) if i + 1 < edits.length() &&
          edits[i + 1] is Insert(..) => {
          guard! edits[i + 1] is Insert(new_index~, new_len~, ..)
          let old_lines = o.view(start=old_index, end=old_index + old_len)
          let new_lines = n.view(start=new_index, end=new_index + new_len)
          let prepared = prepare_replacement(old_lines, new_lines)
          for row in prepared {
            match row.old_html {
              Some(body) =>
                if line_numbers {
                  numbered_line(
                    "del",
                    "-",
                    row.old_offset.map(offset => old_index + offset + 1),
                    None,
                    body,
                  )
                } else {
                  line("del", "-", body)
                }
              None => ()
            }
          }
          for row in prepared {
            match row.new_html {
              Some(body) =>
                if line_numbers {
                  numbered_line(
                    "add",
                    "+",
                    None,
                    row.new_offset.map(offset => new_index + offset + 1),
                    body,
                  )
                } else {
                  line("add", "+", body)
                }
              None => ()
            }
          }
          i += 2
        }
        Equal(old_index~, new_index~, len~) => {
          for offset, l in o.view(start=old_index, end=old_index + len) {
            if line_numbers {
              numbered_line(
                "ctx",
                " ",
                Some(old_index + offset + 1),
                Some(new_index + offset + 1),
                esc(l.text),
              )
            } else {
              line("ctx", " ", esc(l.text))
            }
          }
          i += 1
        }
        Delete(old_index~, old_len~, ..) => {
          for offset, l in o.view(start=old_index, end=old_index + old_len) {
            if line_numbers {
              numbered_line(
                "del",
                "-",
                Some(old_index + offset + 1),
                None,
                esc(l.text),
              )
            } else {
              line("del", "-", esc(l.text))
            }
          }
          i += 1
        }
        Insert(new_index~, new_len~, ..) => {
          for offset, l in n.view(start=new_index, end=new_index + new_len) {
            if line_numbers {
              numbered_line(
                "add",
                "+",
                None,
                Some(new_index + offset + 1),
                esc(l.text),
              )
            } else {
              line("add", "+", esc(l.text))
            }
          }
          i += 1
        }
      }
    }
  }
  if line_numbers {
    buf <+ "</table>\n"
  } else {
    buf <+ "</pre>\n"
  }
  buf.to_string()
}
