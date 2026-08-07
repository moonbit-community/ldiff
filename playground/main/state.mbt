// Copyright 2026 International Digital Economy Academy
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0

///|
priv enum ViewMode {
  Split
  Unified
} derive(Eq)

///|
priv enum SourceSide {
  Old
  New
}

///|
priv enum SideLoad {
  NotRequested
  Loading
  Ready(Array[String])
  CannotRender(String)
  LoadFailed(String)
} derive(Eq)

///|
priv struct FileState {
  file : ApiFile
  diff_mode : FileDiffMode
  expanded : Bool
  old_side : SideLoad
  new_side : SideLoad
} derive(Eq)

///|
priv struct CommitView {
  reference : CommitRef
  sha : String
  parent_sha : String?
  message : String
  html_url : String
  stats : ApiStats
  total_files : Int
  files : Array[FileState]
} derive(Eq)

///|
priv enum Phase {
  Idle
  LoadingCommit(
    reference~ : CommitRef,
    page~ : Int,
    first~ : ApiCommit?,
    files~ : Array[ApiFile]
  )
  LoadFailed(String)
  Showing(CommitView)
} derive(Eq)

///|
priv enum CopyStatus {
  CopyReady
  Copied
  CopyError(String)
} derive(Eq)

///|
priv struct Model {
  input : String
  generation : Int
  view_mode : ViewMode
  phase : Phase
  route : CommitRef?
  share_url : String?
  copy_status : CopyStatus
} derive(Eq)

///|
fn initial_model() -> Model {
  {
    input: "",
    generation: 0,
    view_mode: Split,
    phase: Idle,
    route: None,
    share_url: None,
    copy_status: CopyReady,
  }
}

///|
priv enum Msg {
  InputChanged(String)
  Submit
  RouteChanged(@url.Url)
  ToggleView
  CopyShareLink
  ShareCopied
  ShareCopyFailed(String)
  CommitPageLoaded(Int, Int, Result[ApiCommit, Error])
  ToggleFile(Int, Int)
  RetryFile(Int, Int)
  SourceLoaded(Int, Int, SourceSide, Result[(String, Bytes), Error])
}

///|
fn error_message(error : Error, api : Bool) -> String {
  let detail = error.to_string()
  if api && detail.contains("HTTP 403") {
    "GitHub rejected the request (HTTP 403). The anonymous API limit may be exhausted; try again later."
  } else if api && detail.contains("HTTP 404") {
    "GitHub could not find that public repository or commit."
  } else {
    detail
  }
}

///|
fn commit_request(
  reference : CommitRef,
  generation : Int,
  page : Int,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Cmd {
  @http.get(commit_api_url(reference, page)).expect_json(result => {
    emit(CommitPageLoaded(generation, page, result))
  })
}

///|
fn source_request(
  url : String,
  generation : Int,
  index : Int,
  side : SourceSide,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Cmd {
  @http.get(url).expect_bytes(result => {
    emit(SourceLoaded(generation, index, side, result))
  })
}

///|
fn initial_side(url : String?, expanded : Bool) -> SideLoad {
  match url {
    None => Ready([])
    Some(_) => if expanded { Loading } else { NotRequested }
  }
}

///|
fn commands_for_file(
  file : ApiFile,
  reference : CommitRef,
  sha : String,
  parent_sha : String?,
  generation : Int,
  index : Int,
  emit : @rabbita.Emit[Msg],
) -> Array[@rabbita.Cmd] {
  let pair = source_pair(reference, sha, parent_sha, file)
  let commands : Array[@rabbita.Cmd] = []
  if pair.old_url is Some(url) {
    commands.push(source_request(url, generation, index, Old, emit))
  }
  if pair.new_url is Some(url) {
    commands.push(source_request(url, generation, index, New, emit))
  }
  commands
}

///|
fn finish_commit(
  reference : CommitRef,
  first : ApiCommit,
  all_files : Array[ApiFile],
  generation : Int,
  emit : @rabbita.Emit[Msg],
) -> (CommitView, @rabbita.Cmd) {
  let parent_sha = first_parent(first)
  let states : Array[FileState] = []
  let commands : Array[@rabbita.Cmd] = []
  let mut moonbit_file_count = 0
  for index, file in all_files {
    let diff_mode = file_diff_mode(file)
    let expanded = diff_mode is MoonBitDiff && moonbit_file_count < 20
    if diff_mode is MoonBitDiff {
      moonbit_file_count += 1
    }
    let pair = source_pair(reference, first.sha, parent_sha, file)
    states.push({
      file,
      diff_mode,
      expanded,
      old_side: initial_side(pair.old_url, expanded),
      new_side: initial_side(pair.new_url, expanded),
    })
    if expanded {
      for
        command in commands_for_file(
          file,
          reference,
          first.sha,
          parent_sha,
          generation,
          index,
          emit,
        ) {
        commands.push(command)
      }
    }
  }
  (
    {
      reference,
      sha: first.sha,
      parent_sha,
      message: first.commit.message,
      html_url: first.html_url,
      stats: first.stats,
      total_files: all_files.length(),
      files: states,
    },
    @rabbita.batch(commands),
  )
}

///|
fn set_file_state(
  view : CommitView,
  index : Int,
  state : FileState,
) -> CommitView {
  let files = view.files.copy()
  files[index] = state
  {
    reference: view.reference,
    sha: view.sha,
    parent_sha: view.parent_sha,
    message: view.message,
    html_url: view.html_url,
    stats: view.stats,
    total_files: view.total_files,
    files,
  }
}

///|
fn with_phase(model : Model, phase : Phase) -> Model {
  {
    input: model.input,
    generation: model.generation,
    view_mode: model.view_mode,
    phase,
    route: model.route,
    share_url: model.share_url,
    copy_status: model.copy_status,
  }
}

///|
fn begin_commit_load(
  model : Model,
  reference : CommitRef,
  emit : @rabbita.Emit[Msg],
) -> (Model, @rabbita.Cmd) {
  let generation = model.generation + 1
  (
    {
      input: canonical_github_url(reference),
      generation,
      view_mode: model.view_mode,
      phase: LoadingCommit(reference~, page=1, first=None, files=[]),
      route: Some(reference),
      share_url: Some(playground_share_url(reference)),
      copy_status: CopyReady,
    },
    commit_request(reference, generation, 1, emit),
  )
}

///|
fn app_init(emit : @rabbita.Emit[Msg]) -> (Model, @rabbita.Cmd) {
  let model = initial_model()
  match reference_from_playground_url(browser_current_url()) {
    Ok(Some(reference)) => begin_commit_load(model, reference, emit)
    Ok(None) => (model, @rabbita.none)
    Err(message) => (with_phase(model, LoadFailed(message)), @rabbita.none)
  }
}

///|
fn app_subscriptions(_model : Model, emit : @rabbita.Emit[Msg]) -> @sub.Sub {
  @sub.on_url_changed(url => emit(RouteChanged(url)))
}

///|
fn side_from_result(result : Result[(String, Bytes), Error]) -> SideLoad {
  match result {
    Err(error) => LoadFailed(error_message(error, false))
    Ok((_, bytes)) =>
      match check_source(bytes) {
        Renderable(lines) => Ready(lines)
        Rejected(reason) => CannotRender(reason)
      }
  }
}

///|
fn update(
  model : Model,
  msg : Msg,
  emit : @rabbita.Emit[Msg],
) -> (Model, @rabbita.Cmd) {
  match msg {
    InputChanged(value) =>
      (
        {
          input: value,
          generation: model.generation,
          view_mode: model.view_mode,
          phase: model.phase,
          route: model.route,
          share_url: model.share_url,
          copy_status: CopyReady,
        },
        @rabbita.none,
      )
    ToggleView =>
      (
        {
          input: model.input,
          generation: model.generation,
          view_mode: if model.view_mode is Split {
            Unified
          } else {
            Split
          },
          phase: model.phase,
          route: model.route,
          share_url: model.share_url,
          copy_status: model.copy_status,
        },
        @rabbita.none,
      )
    Submit =>
      match parse_commit_url(model.input) {
        Err(message) =>
          (
            {
              input: model.input,
              generation: model.generation + 1,
              view_mode: model.view_mode,
              phase: LoadFailed(message),
              route: model.route,
              share_url: model.share_url,
              copy_status: CopyReady,
            },
            @rabbita.none,
          )
        Ok(reference) => {
          let already_at_route = model.route == Some(reference)
          let (next, request) = begin_commit_load(model, reference, emit)
          let navigation = if already_at_route {
            @rabbita.none
          } else {
            @nav.push_url(playground_share_url(reference))
          }
          (next, @rabbita.batch([navigation, request]))
        }
      }
    RouteChanged(url) =>
      match reference_from_route(url.fragment) {
        Err(message) =>
          (
            {
              input: "",
              generation: model.generation + 1,
              view_mode: model.view_mode,
              phase: LoadFailed(message),
              route: None,
              share_url: None,
              copy_status: CopyReady,
            },
            @rabbita.none,
          )
        Ok(None) =>
          (
            {
              input: "",
              generation: model.generation + 1,
              view_mode: model.view_mode,
              phase: Idle,
              route: None,
              share_url: None,
              copy_status: CopyReady,
            },
            @rabbita.none,
          )
        Ok(Some(reference)) =>
          if model.route == Some(reference) {
            (model, @rabbita.none)
          } else {
            begin_commit_load(model, reference, emit)
          }
      }
    CopyShareLink =>
      match model.share_url {
        None => (model, @rabbita.none)
        Some(url) =>
          (
            model,
            @clipboard.copy(Text(url), copied=emit(ShareCopied), failed=message => {
              emit(ShareCopyFailed(message))
            }),
          )
      }
    ShareCopied =>
      (
        {
          input: model.input,
          generation: model.generation,
          view_mode: model.view_mode,
          phase: model.phase,
          route: model.route,
          share_url: model.share_url,
          copy_status: Copied,
        },
        @rabbita.none,
      )
    ShareCopyFailed(message) =>
      (
        {
          input: model.input,
          generation: model.generation,
          view_mode: model.view_mode,
          phase: model.phase,
          route: model.route,
          share_url: model.share_url,
          copy_status: CopyError(message),
        },
        @rabbita.none,
      )
    CommitPageLoaded(generation, page, result) => {
      if generation != model.generation {
        return (model, @rabbita.none)
      }
      guard model.phase
        is LoadingCommit(reference~, page=expected, first~, files~) &&
        page == expected else {
        return (model, @rabbita.none)
      }
      match result {
        Err(error) =>
          (
            with_phase(model, LoadFailed(error_message(error, true))),
            @rabbita.none,
          )
        Ok(response) => {
          let accumulated = merge_file_pages(files, response.files)
          let first_commit = first.unwrap_or(response)
          if should_fetch_next_page(page, response.files.length()) {
            (
              with_phase(
                model,
                LoadingCommit(
                  reference~,
                  page=page + 1,
                  first=Some(first_commit),
                  files=accumulated,
                ),
              ),
              commit_request(reference, generation, page + 1, emit),
            )
          } else {
            let (view, command) = finish_commit(
              reference, first_commit, accumulated, generation, emit,
            )
            (with_phase(model, Showing(view)), command)
          }
        }
      }
    }
    ToggleFile(generation, index) => {
      if generation != model.generation {
        return (model, @rabbita.none)
      }
      guard model.phase is Showing(view) && view.files.get(index) is Some(file) else {
        return (model, @rabbita.none)
      }
      if file.expanded {
        let changed = {
          file: file.file,
          diff_mode: file.diff_mode,
          expanded: false,
          old_side: file.old_side,
          new_side: file.new_side,
        }
        (
          with_phase(model, Showing(set_file_state(view, index, changed))),
          @rabbita.none,
        )
      } else {
        let pair = source_pair(
          view.reference,
          view.sha,
          view.parent_sha,
          file.file,
        )
        let first_load = file.old_side is NotRequested ||
          file.new_side is NotRequested
        let changed = {
          file: file.file,
          diff_mode: file.diff_mode,
          expanded: true,
          old_side: if file.old_side is NotRequested {
            initial_side(pair.old_url, true)
          } else {
            file.old_side
          },
          new_side: if file.new_side is NotRequested {
            initial_side(pair.new_url, true)
          } else {
            file.new_side
          },
        }
        let command = if first_load {
          @rabbita.batch(
            commands_for_file(
              file.file,
              view.reference,
              view.sha,
              view.parent_sha,
              generation,
              index,
              emit,
            ),
          )
        } else {
          @rabbita.none
        }
        (
          with_phase(model, Showing(set_file_state(view, index, changed))),
          command,
        )
      }
    }
    RetryFile(generation, index) => {
      if generation != model.generation {
        return (model, @rabbita.none)
      }
      guard model.phase is Showing(view) && view.files.get(index) is Some(file) else {
        return (model, @rabbita.none)
      }
      let pair = source_pair(
        view.reference,
        view.sha,
        view.parent_sha,
        file.file,
      )
      let commands : Array[@rabbita.Cmd] = []
      let old_side = if file.old_side is LoadFailed(_) &&
        pair.old_url is Some(url) {
        commands.push(source_request(url, generation, index, Old, emit))
        Loading
      } else {
        file.old_side
      }
      let new_side = if file.new_side is LoadFailed(_) &&
        pair.new_url is Some(url) {
        commands.push(source_request(url, generation, index, New, emit))
        Loading
      } else {
        file.new_side
      }
      let changed = {
        file: file.file,
        diff_mode: file.diff_mode,
        expanded: true,
        old_side,
        new_side,
      }
      (
        with_phase(model, Showing(set_file_state(view, index, changed))),
        @rabbita.batch(commands),
      )
    }
    SourceLoaded(generation, index, side, result) => {
      if generation != model.generation {
        return (model, @rabbita.none)
      }
      guard model.phase is Showing(view) && view.files.get(index) is Some(file) else {
        return (model, @rabbita.none)
      }
      let loaded = side_from_result(result)
      let changed = match side {
        Old =>
          {
            file: file.file,
            diff_mode: file.diff_mode,
            expanded: file.expanded,
            old_side: loaded,
            new_side: file.new_side,
          }
        New =>
          {
            file: file.file,
            diff_mode: file.diff_mode,
            expanded: file.expanded,
            old_side: file.old_side,
            new_side: loaded,
          }
      }
      (
        with_phase(model, Showing(set_file_state(view, index, changed))),
        @rabbita.none,
      )
    }
  }
}
