// Copyright 2026 International Digital Economy Academy
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0

///|
fn status_label(status : String) -> String {
  match status {
    "added" => "Added"
    "removed" => "Deleted"
    "renamed" => "Renamed"
    "modified" => "Modified"
    "copied" => "Copied"
    other => other
  }
}

///|
fn status_class(status : String) -> String {
  match status {
    "added" => "file-status status-added"
    "removed" => "file-status status-removed"
    "renamed" => "file-status status-renamed"
    _ => "file-status"
  }
}

///|
fn file_label(file : ApiFile) -> String {
  match file.previous_filename {
    Some(previous) if previous != file.filename =>
      "\{previous} → \{file.filename}"
    _ => file.filename
  }
}

///|
fn source_problem(side : SideLoad) -> String? {
  match side {
    CannotRender(message) | LoadFailed(message) => Some(message)
    _ => None
  }
}

///|
fn brand_view() -> @rabbita.Html {
  @html.h1(class="brand", [
    @html.span(class="brand-mark", [
      @html.span(class="mark-plus", "+"),
      @html.span(class="mark-minus", "−"),
    ]),
    @html.span("ldiff"),
    @html.span(class="brand-suffix", "playground"),
  ])
}

///|
fn commit_form(model : Model, emit : @rabbita.Emit[Msg]) -> @rabbita.Html {
  @html.form(on_submit=emit(Submit), class="commit-form", [
    @html.label(for_="commit-url", class="sr-only", "Public GitHub commit URL"),
    @html.div(class="input-row", [
      @html.input(
        id="commit-url",
        input_type=Url,
        value=model.input,
        placeholder="https://github.com/owner/repo/commit/sha",
        required=true,
        on_input=value => emit(InputChanged(value)),
      ),
      @html.button(type_="submit", class="submit-button", [
        @html.span("View diff"),
        @html.span(class="submit-arrow", "→"),
      ]),
    ]),
  ])
}

///|
fn route_example() -> @rabbita.Html {
  @html.div(class="route-example", [
    @html.code(class="route-old", [
      @html.span(class="route-prefix", "− github"),
      @html.span(".com/owner/repo/commit/sha"),
    ]),
    @html.code(class="route-new", [
      @html.span(class="route-prefix", "+ playground"),
      @html.span("/#/owner/repo/commit/sha"),
    ]),
  ])
}

///|
fn landing_details() -> @rabbita.Html {
  @html.fragment([
    @html.div(class="public-note", [
      @html.span(class="note-dot", ""),
      @html.p(
        "Public repositories only. No token is requested, stored, or sent. Anonymous GitHub API limits apply.",
      ),
    ]),
    @html.section(class="supported-links", [
      @html.h2("Supported links"),
      @html.ul([
        @html.li([
          @html.span(class="list-arrow", "→"),
          @html.code("github.com/owner/repo/commit/sha"),
        ]),
        @html.li([
          @html.span(class="list-arrow", "→"),
          @html.code("github.com/owner/repo/pull/number/changes/sha"),
        ]),
      ]),
      @html.p(
        "Opening the generated playground URL restores the same commit automatically, ready to share with a teammate.",
      ),
    ]),
  ])
}

///|
fn hero_view(
  model : Model,
  landing : Bool,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Html {
  @html.header(
    class=if landing { "hero hero-landing" } else { "hero hero-workspace" },
    [
      @html.div(class="hero-copy", [
        brand_view(),
        if landing {
          @html.fragment([
            @html.p(
              class="lede",
              "Review text changes from a public GitHub commit in a fast, focused diff — then share the exact playground URL with anyone.",
            ),
            route_example(),
          ])
        } else {
          @html.p(
            class="workspace-caption",
            "Public GitHub commits, rendered with ldiff",
          )
        },
      ]),
      @html.div(class="hero-controls", [
        @html.div(class="input-panel", commit_form(model, emit)),
        if landing {
          landing_details()
        } else {
          @html.nothing
        },
      ]),
    ],
  )
}

///|
#warnings("-alert_xss_vulnerable")
fn file_diff_view(
  file : FileState,
  generation : Int,
  index : Int,
  mode : ViewMode,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Html {
  let problem = match source_problem(file.old_side) {
    Some(message) => Some(message)
    None => source_problem(file.new_side)
  }
  if problem is Some(message) {
    let retry = file.old_side is LoadFailed(_) || file.new_side is LoadFailed(_)
    return @html.div(class="file-message error", [
      @html.p(message),
      if retry {
        @html.button(
          type_="button",
          class="secondary",
          on_click=emit(RetryFile(generation, index)),
          "Retry file",
        )
      } else {
        @html.nothing
      },
    ])
  }
  match (file.old_side, file.new_side) {
    (Ready(old), Ready(new)) => {
      let rendered = match (file.diff_mode, mode) {
        (MoonBitDiff, Split) =>
          @ldiff.side_by_side_html(
            old~,
            new~,
            context=3,
            line_cleanup=true,
            line_numbers=true,
          )
        (MoonBitDiff, Unified) =>
          @ldiff.unified_html(
            old~,
            new~,
            context=3,
            line_cleanup=true,
            line_numbers=true,
          )
        (LineDiff, Split) =>
          @ldiff.side_by_side_line_html(
            old~,
            new~,
            context=3,
            line_numbers=true,
          )
        (LineDiff, Unified) =>
          @ldiff.unified_line_html(old~, new~, context=3, line_numbers=true)
      }
      // `rendered` is the only raw HTML accepted by the application. ldiff
      // has already escaped every source line and hunk header.
      @html.div(
        class="diff-scroll",
        attrs=@html.Attrs::build().inner_html(rendered),
        ([] : Array[@rabbita.Html]),
      )
    }
    (Loading, _) | (_, Loading) =>
      @html.p(class="file-message loading-inline", "Loading file contents…")
    _ => @html.p(class="file-message", "Expand this file to load its diff.")
  }
}

///|
fn file_card(
  file : FileState,
  generation : Int,
  index : Int,
  mode : ViewMode,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Html {
  @html.article(
    class=if file.expanded { "file-card expanded" } else { "file-card" },
    [
      @html.div(class="file-heading", [
        @html.div(class="file-identity", [
          @html.span(
            class=status_class(file.file.status),
            status_label(file.file.status),
          ),
          @html.code(class="file-path", file_label(file.file)),
        ]),
        @html.div(class="file-actions", [
          @html.span(class="file-stats", [
            @html.span(class="additions", "+\{file.file.additions}"),
            @html.span(class="deletions", "−\{file.file.deletions}"),
          ]),
          @html.button(
            type_="button",
            class="secondary compact",
            on_click=emit(ToggleFile(generation, index)),
            if file.expanded {
              "Collapse"
            } else {
              "Expand"
            },
          ),
        ]),
      ]),
      if file.expanded {
        file_diff_view(file, generation, index, mode, emit)
      } else {
        @html.nothing
      },
    ],
  )
}

///|
fn copy_button_label(status : CopyStatus) -> String {
  match status {
    CopyReady => "Copy link"
    Copied => "Copied"
    CopyError(_) => "Try copy again"
  }
}

///|
fn share_view(model : Model, emit : @rabbita.Emit[Msg]) -> @rabbita.Html {
  match model.share_url {
    None => @html.nothing
    Some(url) =>
      @html.div(class="share-panel", [
        @html.div(class="share-copy", [
          @html.label(for_="share-url", "Shareable playground URL"),
          @html.p("Anyone with this link can open the same public commit."),
        ]),
        @html.div(class="share-row", [
          @html.input(
            id="share-url",
            value=url,
            read_only=true,
            class="share-url",
          ),
          @html.button(
            type_="button",
            class=if model.copy_status is Copied {
              "copy-button copied"
            } else {
              "copy-button"
            },
            title=match model.copy_status {
              CopyError(message) => message
              _ => "Copy the shareable playground URL"
            },
            on_click=emit(CopyShareLink),
            copy_button_label(model.copy_status),
          ),
        ]),
        match model.copy_status {
          CopyError(message) =>
            @html.p(class="copy-error", "Clipboard access failed: \{message}")
          _ => @html.nothing
        },
      ])
  }
}

///|
fn commit_view(
  commit : CommitView,
  model : Model,
  emit : @rabbita.Emit[Msg],
) -> @rabbita.Html {
  let file_views : Array[@rabbita.Html] = []
  for index, file in commit.files {
    file_views.push(
      file_card(file, model.generation, index, model.view_mode, emit),
    )
  }
  @html.section(class="results", [
    @html.div(class="commit-card", [
      @html.div(class="commit-title", [
        @html.div(class="commit-identity", [
          @html.p(class="section-label", "Public commit"),
          @html.a(
            href=commit.html_url,
            target=Blank,
            rel="noopener noreferrer",
            "\{commit.reference.owner}/\{commit.reference.repo}@\{commit.sha}",
          ),
          @html.p(
            class="parent",
            match commit.parent_sha {
              Some(parent) => "Compared with first parent \{parent}."
              None => "Root commit; compared with an empty tree."
            },
          ),
        ]),
        @html.button(
          type_="button",
          class="view-toggle",
          on_click=emit(ToggleView),
          match model.view_mode {
            Split => "Use unified view"
            Unified => "Use split view"
          },
        ),
      ]),
      @html.pre(class="commit-message", commit.message),
      @html.div(class="summary-grid", [
        @html.span(class="summary-add", "+\{commit.stats.additions} additions"),
        @html.span(
          class="summary-del",
          "−\{commit.stats.deletions} deletions",
        ),
        @html.span("\{commit.total_files} files processed"),
        @html.span("\{commit.files.length()} changed files shown"),
      ]),
      share_view(model, emit),
    ]),
    if commit.files.length() == 0 {
      @html.div(
        class="empty-state",
        "No changed files were returned for this commit.",
      )
    } else {
      @html.div(class="file-list", file_views)
    },
  ])
}

///|
fn phase_view(model : Model, emit : @rabbita.Emit[Msg]) -> @rabbita.Html {
  match model.phase {
    Idle => @html.nothing
    LoadingCommit(page~, ..) =>
      @html.div(class="empty-state loading", [
        @html.span(class="spinner", ""),
        @html.span(
          "Loading commit metadata (page \{page}, up to 100 files per page)…",
        ),
      ])
    LoadFailed(message) =>
      @html.div(class="empty-state error", [
        @html.p(message),
        @html.button(
          type_="button",
          class="secondary",
          on_click=emit(Submit),
          "Try again",
        ),
      ])
    Showing(commit) => commit_view(commit, model, emit)
  }
}

///|
fn landing_mode(model : Model) -> Bool {
  match model.phase {
    Idle => true
    LoadFailed(_) => model.route is None
    _ => false
  }
}

///|
fn app_view(model : Model, emit : @rabbita.Emit[Msg]) -> @rabbita.Html {
  let landing = landing_mode(model)
  @html.main_(class=if landing { "shell landing" } else { "shell workspace" }, [
    hero_view(model, landing, emit),
    phase_view(model, emit),
    @html.footer([
      @html.span("Built with ldiff · "),
      @html.a(
        href="https://github.com/moonbit-community/ldiff",
        target=Blank,
        rel="noopener noreferrer",
        "Source on GitHub",
      ),
    ]),
  ])
}
