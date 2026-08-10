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

// Plain line renderers. These deliberately use the core line-level diff
// directly: they do not tokenize source text, reopen equal anchors, or run
// intraline alignment.

///|
fn split_line_replacement(
  buf : StringBuilder,
  old_lines : ArrayView[String],
  new_lines : ArrayView[String],
  old_start : Int,
  new_start : Int,
  line_numbers : Bool,
) -> Unit {
  let row_count = if old_lines.length() > new_lines.length() {
    old_lines.length()
  } else {
    new_lines.length()
  }
  for offset in 0..<row_count {
    let has_old = offset < old_lines.length()
    let has_new = offset < new_lines.length()
    split_row(
      buf,
      if has_old {
        Some(old_start + offset + 1)
      } else {
        None
      },
      if has_old {
        "del"
      } else {
        "empty"
      },
      if has_old {
        esc(old_lines[offset])
      } else {
        ""
      },
      if has_new {
        Some(new_start + offset + 1)
      } else {
        None
      },
      if has_new {
        "add"
      } else {
        "empty"
      },
      if has_new {
        esc(new_lines[offset])
      } else {
        ""
      },
      line_numbers,
    )
  }
}

///|
fn append_split_line_hunk(
  buf : StringBuilder,
  h : @diff.Hunk[String],
  hunk_index : Int,
  line_numbers : Bool,
  hunk_notes : ArrayView[HunkNote?],
) -> Unit {
  if line_numbers {
    buf <+
      "<tr><td class=\"hunk-header\" colspan=\"4\">\{esc(h.header())}</td></tr>\n"
  } else {
    buf <+
      "<tr><td class=\"hunk-header\" colspan=\"2\">\{esc(h.header())}</td></tr>\n"
  }
  match hunk_note_at(hunk_notes, hunk_index) {
    Some(note) => table_hunk_note(buf, note, if line_numbers { 4 } else { 2 })
    None => ()
  }
  let edits = h.edits()
  let old_view = h.old_view()
  let new_view = h.new_view()
  let mut index = 0
  while index < edits.length() {
    match edits[index] {
      Delete(old_index~, old_len~, ..) if index + 1 < edits.length() &&
        edits[index + 1] is Insert(..) => {
        guard! edits[index + 1] is Insert(new_index~, new_len~, ..)
        split_line_replacement(
          buf,
          old_view.view(start=old_index, end=old_index + old_len),
          new_view.view(start=new_index, end=new_index + new_len),
          old_index,
          new_index,
          line_numbers,
        )
        index += 2
      }
      Equal(old_index~, new_index~, len~) => {
        for offset, line in old_view.view(start=old_index, end=old_index + len) {
          split_row(
            buf,
            Some(old_index + offset + 1),
            "ctx",
            esc(line),
            Some(new_index + offset + 1),
            "ctx",
            esc(line),
            line_numbers,
          )
        }
        index += 1
      }
      Delete(old_index~, old_len~, ..) => {
        for
          offset, line in old_view.view(
            start=old_index,
            end=old_index + old_len,
          ) {
          split_row(
            buf,
            Some(old_index + offset + 1),
            "del",
            esc(line),
            None,
            "empty",
            "",
            line_numbers,
          )
        }
        index += 1
      }
      Insert(new_index~, new_len~, ..) => {
        for
          offset, line in new_view.view(
            start=new_index,
            end=new_index + new_len,
          ) {
          split_row(
            buf,
            None,
            "empty",
            "",
            Some(new_index + offset + 1),
            "add",
            esc(line),
            line_numbers,
          )
        }
        index += 1
      }
    }
  }
}

///|
/// Render a plain line-level diff as a GitHub-style side-by-side HTML table.
/// Replacement blocks pair old and new lines by position, leaving the other
/// cell empty when one side has extra lines. Source text is HTML-escaped, but
/// no MoonBit lexing, line cleanup, or intraline highlighting is performed.
/// Set `line_numbers=true` for old-number, old-code, new-number, new-code
/// columns. `hunk_notes[index]` optionally annotates that zero-based hunk.
pub fn side_by_side_line_html(
  old~ : ArrayView[String],
  new~ : ArrayView[String],
  context? : Int = 3,
  line_numbers? : Bool = false,
  hunk_notes? : ArrayView[HunkNote?] = [],
) -> String {
  let buf = StringBuilder::new()
  buf <+ "<table class=\"split\">\n"
  for
    hunk_index, h in @diff.Diff(old~, new~, algorithm=Patience).group(context~) {
    append_split_line_hunk(buf, h, hunk_index, line_numbers, hunk_notes)
  }
  buf <+ "</table>\n"
  buf.to_string()
}

///|
/// Render each plain Patience-diff hunk as its own split HTML table. Array
/// indexes match `unified_line_hunks` and the zero-based `hunk_notes` indexes.
pub fn side_by_side_line_hunks_html(
  old~ : ArrayView[String],
  new~ : ArrayView[String],
  context? : Int = 3,
  line_numbers? : Bool = false,
  hunk_notes? : ArrayView[HunkNote?] = [],
) -> Array[String] {
  let rendered : Array[String] = []
  for
    hunk_index, h in @diff.Diff(old~, new~, algorithm=Patience).group(context~) {
    let buf = StringBuilder::new()
    buf <+ "<table class=\"split\">\n"
    append_split_line_hunk(buf, h, hunk_index, line_numbers, hunk_notes)
    buf <+ "</table>\n"
    rendered.push(buf.to_string())
  }
  rendered
}

///|
fn append_unified_line_hunk(
  buf : StringBuilder,
  h : @diff.Hunk[String],
  hunk_index : Int,
  line_numbers : Bool,
  hunk_notes : ArrayView[HunkNote?],
) -> Unit {
  if line_numbers {
    buf <+
      "<tr><td class=\"hunk-header\" colspan=\"3\">\{esc(h.header())}</td></tr>\n"
  } else {
    buf <+ "<span class=\"hunk-header\">\{esc(h.header())}</span>\n"
  }
  match hunk_note_at(hunk_notes, hunk_index) {
    Some(note) =>
      if line_numbers {
        table_hunk_note(buf, note, 3)
      } else {
        pre_hunk_note(buf, note)
      }
    None => ()
  }
  let old_view = h.old_view()
  let new_view = h.new_view()
  for edit in h.edits() {
    match edit {
      Equal(old_index~, new_index~, len~) =>
        for offset, value in old_view.view(start=old_index, end=old_index + len) {
          if line_numbers {
            unified_numbered_line(
              buf,
              "ctx",
              " ",
              Some(old_index + offset + 1),
              Some(new_index + offset + 1),
              esc(value),
            )
          } else {
            unified_text_line(buf, "ctx", " ", esc(value))
          }
        }
      Delete(old_index~, old_len~, ..) =>
        for
          offset, value in old_view.view(
            start=old_index,
            end=old_index + old_len,
          ) {
          if line_numbers {
            unified_numbered_line(
              buf,
              "del",
              "-",
              Some(old_index + offset + 1),
              None,
              esc(value),
            )
          } else {
            unified_text_line(buf, "del", "-", esc(value))
          }
        }
      Insert(new_index~, new_len~, ..) =>
        for
          offset, value in new_view.view(
            start=new_index,
            end=new_index + new_len,
          ) {
          if line_numbers {
            unified_numbered_line(
              buf,
              "add",
              "+",
              None,
              Some(new_index + offset + 1),
              esc(value),
            )
          } else {
            unified_text_line(buf, "add", "+", esc(value))
          }
        }
    }
  }
}

///|
/// Render a plain line-level diff in unified HTML form. Replacement blocks
/// emit every deletion before every insertion. Source text is HTML-escaped,
/// but no MoonBit lexing, line cleanup, or intraline highlighting is
/// performed. Set `line_numbers=true` for old-number, new-number, and
/// prefixed-code columns. `hunk_notes[index]` optionally annotates that
/// zero-based hunk.
pub fn unified_line_html(
  old~ : ArrayView[String],
  new~ : ArrayView[String],
  context? : Int = 3,
  line_numbers? : Bool = false,
  hunk_notes? : ArrayView[HunkNote?] = [],
) -> String {
  let buf = StringBuilder::new()
  if line_numbers {
    buf <+ "<table class=\"unified numbered\">\n"
  } else {
    buf <+ "<pre class=\"unified\">\n"
  }
  for
    hunk_index, h in @diff.Diff(old~, new~, algorithm=Patience).group(context~) {
    append_unified_line_hunk(buf, h, hunk_index, line_numbers, hunk_notes)
  }
  if line_numbers {
    buf <+ "</table>\n"
  } else {
    buf <+ "</pre>\n"
  }
  buf.to_string()
}

///|
/// Render each plain Patience-diff hunk as its own unified HTML block. Array
/// indexes match `unified_line_hunks` and the zero-based `hunk_notes` indexes.
pub fn unified_line_hunks_html(
  old~ : ArrayView[String],
  new~ : ArrayView[String],
  context? : Int = 3,
  line_numbers? : Bool = false,
  hunk_notes? : ArrayView[HunkNote?] = [],
) -> Array[String] {
  let rendered : Array[String] = []
  for
    hunk_index, h in @diff.Diff(old~, new~, algorithm=Patience).group(context~) {
    let buf = StringBuilder::new()
    if line_numbers {
      buf <+ "<table class=\"unified numbered\">\n"
    } else {
      buf <+ "<pre class=\"unified\">\n"
    }
    append_unified_line_hunk(buf, h, hunk_index, line_numbers, hunk_notes)
    if line_numbers {
      buf <+ "</table>\n"
    } else {
      buf <+ "</pre>\n"
    }
    rendered.push(buf.to_string())
  }
  rendered
}
