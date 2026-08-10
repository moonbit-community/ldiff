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
/// A short annotation rendered immediately below a diff hunk header.
pub(all) struct HunkNote {
  title : String
  body : String
} derive(Eq)

///|
fn append_diff_line_hunk(
  buf : StringBuilder,
  hunk : @diff.Hunk[DiffLine],
) -> Unit {
  buf <+ "\{hunk.header()}\n"
  let old_view = hunk.old_view()
  let new_view = hunk.new_view()
  for edit in hunk.edits() {
    match edit {
      Equal(old_index~, len~, ..) =>
        for line in old_view.view(start=old_index, end=old_index + len) {
          buf <+ " \{line.text}\n"
        }
      Delete(old_index~, old_len~, ..) =>
        for line in old_view.view(start=old_index, end=old_index + old_len) {
          buf <+ "-\{line.text}\n"
        }
      Insert(new_index~, new_len~, ..) =>
        for line in new_view.view(start=new_index, end=new_index + new_len) {
          buf <+ "+\{line.text}\n"
        }
    }
  }
}

///|
/// Return unified patch hunks using the same MoonBit-aware grouping boundaries
/// as `side_by_side_html` and `unified_html`.
pub fn unified_hunks(
  old~ : ArrayView[String],
  new~ : ArrayView[String],
  context? : Int = 3,
  line_cleanup? : Bool = false,
) -> Array[String] {
  let hunks : Array[String] = []
  for hunk in rendering_diff(old, new, line_cleanup).group(context~) {
    let buf = StringBuilder::new()
    append_diff_line_hunk(buf, hunk)
    hunks.push(buf.to_string())
  }
  hunks
}

///|
fn append_plain_line_hunk(
  buf : StringBuilder,
  hunk : @diff.Hunk[String],
) -> Unit {
  buf <+ "\{hunk.header()}\n"
  let old_view = hunk.old_view()
  let new_view = hunk.new_view()
  for edit in hunk.edits() {
    match edit {
      Equal(old_index~, len~, ..) =>
        for line in old_view.view(start=old_index, end=old_index + len) {
          buf <+ " \{line}\n"
        }
      Delete(old_index~, old_len~, ..) =>
        for line in old_view.view(start=old_index, end=old_index + old_len) {
          buf <+ "-\{line}\n"
        }
      Insert(new_index~, new_len~, ..) =>
        for line in new_view.view(start=new_index, end=new_index + new_len) {
          buf <+ "+\{line}\n"
        }
    }
  }
}

///|
/// Return unified patch hunks using the same plain Patience-diff grouping
/// boundaries as `side_by_side_line_html` and `unified_line_html`.
pub fn unified_line_hunks(
  old~ : ArrayView[String],
  new~ : ArrayView[String],
  context? : Int = 3,
) -> Array[String] {
  let hunks : Array[String] = []
  for hunk in @diff.Diff(old~, new~, algorithm=Patience).group(context~) {
    let buf = StringBuilder::new()
    append_plain_line_hunk(buf, hunk)
    hunks.push(buf.to_string())
  }
  hunks
}
