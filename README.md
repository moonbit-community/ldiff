# ldiff — lexer-based diff for MoonBit code

## GitHub commit playground

The static Rabbita playground accepts either of these public GitHub URLs:

```text
https://github.com/{owner}/{repo}/commit/{sha}
https://github.com/{owner}/{repo}/pull/{number}/changes/{sha}
```

Both forms compare the commit with its first parent (or an empty old side for
a root commit). Every changed file receives a card in GitHub's order. Files
whose old or new path ends in `.mbt` use ldiff's MoonBit-aware lexical diff;
other valid UTF-8 text files use a plain line diff. The first 20 MoonBit diffs
open automatically, while all other files load on demand.

Each downloaded side is limited to 1 MiB and 20,000 lines. Invalid UTF-8,
NUL-containing, binary, and over-limit content keeps its file card and shows
an explanatory message instead of a rendered diff. The browser fetches
anonymous GitHub REST and raw-content endpoints and never accepts, stores, or
sends a personal access token. Anonymous GitHub API rate limits therefore
apply.

Submitting a GitHub URL updates the browser to a static-host-friendly share
route:

```text
https://{playground-host}/{base}/#/owner/repo/commit/sha
```

Opening that URL restores and loads the same commit automatically. The result
page also exposes the full URL in a read-only field with a one-click copy
button. Hash routing keeps shared links working on GitHub Pages without a
server-side rewrite rule.

Run the live development server from the Warren app directory:

```sh
cd playground
warren dev --direct
```

Create the release site with:

```sh
cd playground
warren build
```


The playground also has Chromium end-to-end tests. They build the MoonBit JS
release into a temporary directory, serve it with the static assets in
`playground/public`, and mock every GitHub API and raw-content request. Install
the pinned Node dependencies and Playwright browser once, then run the suite:

```sh
cd playground
npm ci
npx playwright install chromium
npm run test:e2e
```

On a machine that is missing Chromium system libraries, use
`npx playwright install --with-deps chromium` instead. For an interactive
Playwright session, run `npm run test:e2e:ui`.
