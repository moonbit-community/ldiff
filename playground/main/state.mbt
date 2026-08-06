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
priv struct Model {
  input : String
  generation : Int
  view_mode : ViewMode
  phase : Phase
} derive(Eq)

///|
fn initial_model() -> Model {
  { input: "", generation: 0, view_mode: Split, phase: Idle }
}

///|
priv enum Msg {
  InputChanged(String)
  Submit
  ToggleView
  CommitPageLoaded(Int, Int, Result[ApiCommit, Error])
  ToggleFile(Int, Int)
  RetryFile(Int, Int)
  SourceLoaded(Int, Int, SourceSide, Result[String, Error])
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
  @http.get(url).expect_text(result => {
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
  let matching = filter_moonbit_files(all_files)
  let parent_sha = first_parent(first)
  let states : Array[FileState] = []
  let commands : Array[@rabbita.Cmd] = []
  for index, file in matching {
    let expanded = index < 20
    let pair = source_pair(reference, first.sha, parent_sha, file)
    states.push({
      file,
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
  }
}

///|
fn side_from_result(result : Result[String, Error]) -> SideLoad {
  match result {
    Err(error) => LoadFailed(error_message(error, false))
    Ok(text) =>
      match check_source(text) {
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
        },
        @rabbita.none,
      )
    Submit => {
      let generation = model.generation + 1
      match parse_commit_url(model.input) {
        Err(message) =>
          (
            {
              input: model.input,
              generation,
              view_mode: model.view_mode,
              phase: LoadFailed(message),
            },
            @rabbita.none,
          )
        Ok(reference) =>
          (
            {
              input: model.input,
              generation,
              view_mode: model.view_mode,
              phase: LoadingCommit(reference~, page=1, first=None, files=[]),
            },
            commit_request(reference, generation, 1, emit),
          )
      }
    }
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
      let changed = { file: file.file, expanded: true, old_side, new_side }
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
            expanded: file.expanded,
            old_side: loaded,
            new_side: file.new_side,
          }
        New =>
          {
            file: file.file,
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
