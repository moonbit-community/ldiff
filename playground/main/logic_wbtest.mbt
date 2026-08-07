// Copyright 2026 International Digital Economy Academy
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0

///|
extern "js" fn read_fixture(path : String) -> String =
  #| (path) => require("node:fs").readFileSync(path, "utf8")

///|
fn fixture_file(
  filename : String,
  status : String,
  previous_filename? : String,
) -> ApiFile {
  {
    filename,
    previous_filename,
    status,
    additions: 1,
    deletions: 2,
    changes: 3,
  }
}

///|
test "parse supported GitHub commit URL forms" {
  guard parse_commit_url(
      "https://github.com/moonbit-community/ldiff/commit/aBcDeF1?diff=split#files",
    )
    is Ok(commit) else {
    fail("expected commit URL to parse")
  }
  assert_eq(commit.owner, "moonbit-community")
  assert_eq(commit.repo, "ldiff")
  assert_eq(commit.sha, "aBcDeF1")

  guard parse_commit_url(
      "https://github.com/moonbitlang/core/pull/42/changes/0123456789abcdef",
    )
    is Ok(pr) else {
    fail("expected PR changes URL to parse")
  }
  assert_eq(pr.owner, "moonbitlang")
  assert_eq(pr.repo, "core")
  assert_eq(pr.sha, "0123456789abcdef")
}

///|
test "shared playground routes round-trip to canonical GitHub commit URLs" {
  let reference = CommitRef::{
    owner: "moonbit-community",
    repo: "ldiff",
    sha: "aBcDeF1",
  }
  assert_eq(
    playground_route(reference),
    "#/moonbit-community/ldiff/commit/aBcDeF1",
  )
  assert_eq(
    canonical_github_url(reference),
    "https://github.com/moonbit-community/ldiff/commit/aBcDeF1",
  )
  guard reference_from_playground_url(
      "https://example.github.io/ldiff/#/moonbit-community/ldiff/commit/aBcDeF1",
    )
    is Ok(Some(parsed)) else {
    fail("expected the shared route to parse")
  }
  assert_true(parsed == reference)
  assert_true(
    reference_from_playground_url("https://example.com/ldiff/") is Ok(None),
  )
  assert_true(
    reference_from_playground_url(
      "https://example.com/ldiff/#/moonbit-community/ldiff/pull/1",
    )
    is Err(_),
  )
  assert_true(
    reference_from_playground_url(
      "https://example.com/ldiff/#/bad owner/ldiff/commit/abcdef1",
    )
    is Err(_),
  )
}

///|
test "reject unsupported or malformed URLs" {
  for
    url in [
      "http://github.com/a/b/commit/abcdef1", "https://git.example.com/a/b/commit/abcdef1",
      "https://github.example.com/a/b/commit/abcdef1", "https://github.com/a/b/pull/1/files",
      "https://github.com/a/b/compare/abcdef1...abcdef2", "https://github.com/-bad/b/commit/abcdef1",
      "https://github.com/a/bad%2Frepo/commit/abcdef1", "https://github.com/a/b/commit/abcdef",
      "https://github.com/a/b/pull/nope/changes/abcdef1", "https://github.com/a/b/pull/0/changes/abcdef1",
      "https://github.com:443/a/b/commit/abcdef1",
    ] {
    assert_true(parse_commit_url(url) is Err(_), msg=url)
  }
}

///|
test "select MoonBit diff only when either path ends with lowercase mbt" {
  for
    file in [
      fixture_file("main.mbt", "modified"),
      fixture_file("new.txt", "renamed", previous_filename="old.mbt"),
      fixture_file("new.mbt", "renamed", previous_filename="old.txt"),
    ] {
    assert_true(file_diff_mode(file) is MoonBitDiff, msg=file.filename)
  }
  for
    file in [
      fixture_file("README.md", "modified"),
      fixture_file("types.mbti", "modified"),
      fixture_file("guide.mbt.md", "modified"),
      fixture_file("MAIN.MBT", "modified"),
      fixture_file("moon.pkg", "modified"),
      fixture_file("new.txt", "renamed", previous_filename="old.txt"),
    ] {
    assert_true(file_diff_mode(file) is LineDiff, msg=file.filename)
  }
}

///|
test "raw content URLs percent-encode each path byte" {
  let reference = CommitRef::{
    owner: "moonbit-community",
    repo: "ldiff",
    sha: "abcdef1",
  }
  assert_eq(
    raw_url(reference, "abcdef1", "src/a b#中?.mbt"),
    "https://raw.githubusercontent.com/moonbit-community/ldiff/abcdef1/src/a%20b%23%E4%B8%AD%3F.mbt",
  )
}

///|
test "decode local GitHub fixtures and select the first merge parent" {
  let merge = decode_commit(
    read_fixture("playground/main/fixtures/commit_page1.json"),
  )
  assert_eq(merge.sha, "abcdef1234567890abcdef1234567890abcdef12")
  assert_eq(
    merge.commit.message,
    "Add playground\n\nRender public MoonBit commits.",
  )
  assert_eq(
    first_parent(merge),
    Some("1111111111111111111111111111111111111111"),
  )
  assert_eq(merge.files.length(), 3)
  assert_eq(merge.files[0].previous_filename, None)
  assert_eq(merge.files[1].previous_filename, Some("src/old_name.txt"))

  let root = decode_commit(
    read_fixture("playground/main/fixtures/root_commit.json"),
  )
  assert_eq(first_parent(root), None)
  assert_eq(root.stats.additions, 2)
}

///|
test "pagination appends file metadata and stops at GitHub's 30-page cap" {
  let first = [fixture_file("a.mbt", "modified")]
  let second = [fixture_file("b.mbt", "added")]
  let merged = merge_file_pages(first, second)
  assert_eq(merged.map(file => file.filename), ["a.mbt", "b.mbt"])
  assert_true(should_fetch_next_page(1, 100))
  assert_false(should_fetch_next_page(1, 99))
  assert_false(should_fetch_next_page(30, 100))
  assert_true(
    commit_api_url({ owner: "a", repo: "b", sha: "abcdef1" }, 30).has_suffix(
      "?per_page=100&page=30",
    ),
  )
}

///|
test "added deleted renamed merge and root commits choose the correct raw sides" {
  let reference = CommitRef::{ owner: "owner", repo: "repo", sha: "abcdef1" }
  let parent = Some("1111111")
  let added = source_pair(
    reference,
    "2222222",
    parent,
    fixture_file("new.mbt", "added"),
  )
  assert_eq(added.old_url, None)
  assert_true(added.new_url is Some(_))

  let deleted = source_pair(
    reference,
    "2222222",
    parent,
    fixture_file("old.mbt", "removed"),
  )
  assert_true(deleted.old_url is Some(_))
  assert_eq(deleted.new_url, None)

  let renamed = source_pair(
    reference,
    "2222222",
    parent,
    fixture_file("new.mbt", "renamed", previous_filename="old name.mbt"),
  )
  assert_true(renamed.old_url.unwrap().has_suffix("/old%20name.mbt"))
  assert_true(renamed.new_url.unwrap().has_suffix("/new.mbt"))

  let root = source_pair(
    reference,
    "2222222",
    None,
    fixture_file("main.mbt", "modified"),
  )
  assert_eq(root.old_url, None)
  assert_true(root.new_url is Some(_))
}

///|
test "source validation accepts Unicode and normalizes CRLF" {
  guard check_source(@utf8.encode("a\r\n名😀\r\n")) is Renderable(lines) else {
    fail("expected source to render")
  }
  assert_eq(lines, ["a", "名😀", ""])
}

///|
test "source validation rejects invalid UTF-8, NUL, byte and line limits" {
  guard check_source([0xff]) is Rejected(invalid_utf8) else {
    fail("expected invalid UTF-8 to be rejected")
  }
  assert_true(invalid_utf8.contains("not valid UTF-8"))
  guard check_source(b"a\x00b") is Rejected(nul) else {
    fail("expected NUL to be rejected")
  }
  assert_true(nul.contains("NUL byte"))
  assert_true(
    check_source(Bytes::make(MAX_SOURCE_BYTES + 1, b'x')) is Rejected(_),
  )
  assert_true(
    check_source(@utf8.encode("\n".repeat(MAX_SOURCE_LINES))) is Rejected(_),
  )
}

///|
test "stale commit responses are discarded by generation" {
  let model = Model::{
    input: "https://github.com/a/b/commit/abcdef1",
    generation: 2,
    view_mode: Split,
    phase: Idle,
    route: None,
    share_url: None,
    copy_status: CopyReady,
  }
  let fixture = decode_commit(
    read_fixture("playground/main/fixtures/root_commit.json"),
  )
  let emit : @rabbita.Emit[Msg] = Emit(_ => @rabbita.none)
  let (after, _) = update(model, CommitPageLoaded(1, 1, Ok(fixture)), emit)
  assert_true(after == model)
}

///|
test "all files remain listed but only the first twenty MoonBit diffs auto-load" {
  let fixture = decode_commit(
    read_fixture("playground/main/fixtures/root_commit.json"),
  )
  let files : Array[ApiFile] = []
  files.push(fixture_file("README.md", "added"))
  for index in 0..<21 {
    if index == 5 {
      files.push(
        fixture_file(
          "src/file_5.txt",
          "renamed",
          previous_filename="src/file_5.mbt",
        ),
      )
    } else {
      files.push(fixture_file("src/file_\{index}.mbt", "added"))
    }
    if index == 9 {
      files.push(fixture_file("assets/logo.bin", "added"))
    }
  }
  let emit : @rabbita.Emit[Msg] = Emit(_ => @rabbita.none)
  let reference = CommitRef::{
    owner: "example",
    repo: "root",
    sha: fixture.sha,
  }
  let (view, _) = finish_commit(reference, fixture, files, 7, emit)
  assert_eq(view.files.length(), files.length())
  assert_eq(
    view.files.map(state => state.file.filename),
    files.map(file => file.filename),
  )
  let mut moonbit_index = 0
  for state in view.files {
    match state.diff_mode {
      MoonBitDiff => {
        if moonbit_index < 20 {
          assert_true(state.expanded, msg=state.file.filename)
          assert_true(state.old_side is Ready([]), msg=state.file.filename)
          assert_true(state.new_side is Loading, msg=state.file.filename)
        } else {
          assert_false(state.expanded, msg=state.file.filename)
          assert_true(state.new_side is NotRequested, msg=state.file.filename)
        }
        moonbit_index += 1
      }
      LineDiff => {
        assert_false(state.expanded, msg=state.file.filename)
        assert_true(state.new_side is NotRequested, msg=state.file.filename)
      }
    }
  }
  assert_eq(moonbit_index, 21)

  let model = Model::{
    input: "",
    generation: 7,
    view_mode: Split,
    phase: Showing(view),
    route: Some(reference),
    share_url: None,
    copy_status: CopyReady,
  }
  let (after, _) = update(
    model,
    SourceLoaded(6, 0, New, Ok(("text/plain", @utf8.encode("stale")))),
    emit,
  )
  assert_true(after == model)
}
