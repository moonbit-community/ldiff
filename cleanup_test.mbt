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
test "token cleanup highlights the natural repeated-token boundary" {
  let split = @ldiff.side_by_side_html(old=["x x"], new=["x"], context=0)
  inspect(
    split.contains(
      "<td class=\"del\">x<b class=\"wd\"> x</b></td><td class=\"add\">x</td>",
    ),
    content="true",
  )
  let comment = @ldiff.unified_html(old=["// foo foo"], new=["// foo"])
  inspect(comment.contains("// <b class=\"wd\">foo </b>foo"), content="true")
  let unicode = @ldiff.side_by_side_html(old=["名 名"], new=["名"])
  inspect(unicode.contains("名<b class=\"wd\"> 名</b>"), content="true")
}
