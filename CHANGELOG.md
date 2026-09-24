# Changelog

`MAJOR.MINOR.BUILD`, where the last number counts published builds rather than
bug fixes: it goes up for every build that ships and resets when the minor
moves. A minor is a milestone worth telling someone about; a major is a
breaking change to stored data.

## Unreleased

### Added

- **A branch kept when its worktree was removed can be deleted from the toast
  that says so.** Delete Branch deletes it only while it is where it was when
  it was kept, and says so instead when something was committed to it since;
  the toast after it names the commit the branch was at, which is all it
  takes to bring it back.

- **Clean Up Worktrees…** — in a worktree heading's menu, the Project menu and
  the palette — lists every worktree the project could lose, with what stands
  in the way of each on its row: a lock, an agent working or waiting for you,
  uncommitted files, commits only a detached `HEAD` holds, a checkout git cannot
  read. Filters narrow it to the merged, the clean and the ones idle for more
  than a chosen number of days; the finished ones — merged, clean, nothing
  running, untouched for a day — are ticked to begin with. Uncommitted files
  can be let go on their own row. Remove takes what is ticked one at a time,
  closing the sessions in each, and says once at the end how many went, which
  branches were kept and what git refused. Nothing is ever removed without
  being ticked.

- **Say where the work in each worktree stands.** A worktree heading's menu
  sets a status — To Do, In Progress, In Review or Completed — shown as a small
  disc filling up beside the name, and a comment, shown as a line under the
  heading with the whole of it on hover. Both survive a relaunch, and go when
  the worktree does.

- **A `relay` command in every Relay terminal**, for the agent working there as
  much as for you: `relay worktree list`, `current`, `create`, `rm` and `set`.
  `create` makes a worktree the way New Worktree does and can start an agent
  in it with a first prompt; `rm` removes one — and its branch, when Relay
  made it and its work is already merged, squashed or rebased in — and asks
  for `--force` before throwing away uncommitted work; `set` gives a worktree a status and a comment. The
  app carries each one out, so it shows in the sidebar at once. `--json` gives
  an answer a program can read, and `relay help` says the rest.

### Fixed

- **A branch squashed or rebased in by a pull request goes with its worktree.**
  Removing a worktree deleted its branch only when `git branch -d` agreed,
  which it never does once a forge has squashed or rebased the pull request,
  and not for one merged normally either until the local `main` had been
  pulled: the branch stayed, with a toast saying it had commits merged
  nowhere. Relay now asks git whether the branch's work is in the remote's
  default branch — fetching that one branch first when it has to — and
  deletes the branch when git proves it is. A branch Relay did not make is
  still never touched.
- **Removing a worktree says what happens to its branch before it goes.** A
  worktree whose branch had work merged nowhere disappeared on Remove, and
  only a toast afterwards said the branch had been kept. The branch is now
  judged first, and the question says whether it goes, stays with so many
  unmerged commits, or stays because Relay did not make it; the button reads
  "Remove, keep branch" when it stays, and the toast that follows is a warning.
  Clean Up Worktrees names the branches that will stay before it removes
  anything.
- **A worktree with no sessions in it can be gone to.** Its heading only
  folded, so the way into a worktree was a session already running there. A
  click on the heading now turns the right-hand panel and new sessions to it,
  shows one of its sessions if it has any, and marks it as the worktree in
  use; the chevron folds it.
- **Relay Dev opened from a Relay terminal is Relay Dev.** Started with
  `open -a "Relay Dev"` in a terminal of the released app, it took that
  terminal's build for its own: it connected to the released app's daemon and
  read and wrote its workspace. The app now goes by its own identity, whatever
  it inherits.
- **The sidebar no longer rearranges itself at launch.** A project with
  worktrees showed its sessions as one list until git had read every
  worktree's status, then regrouped them all. It now shows a spinner until the
  worktrees are known, and knows them after one call to git rather than one
  per worktree.

## 0.7.0 — 2026-09-24

### Added

- **Worktrees: a piece of work in a checkout of its own.** New worktree… — in
  the `+` menu, the Projects menu and the palette — asks for a branch, where to
  start it from, and what to run there first, with a prompt to hand an agent
  once it is ready. The branch is checked out in `~/.relay/worktrees`, so two
  agents working at once no longer edit the same files, a diff in the Git panel
  is one task's rather than everyone's, and switching branches no longer pulls
  the files out from under every session in the project. Once a project has a
  second worktree the sidebar groups its sessions under each one, with the
  branch and its diff on the heading; choosing a session turns the Git panel,
  the file tree, search and TODO to the checkout it is working in. Worktrees
  made in a terminal — by hand, `claude --worktree` or `codex --worktree` —
  appear on their own. Removing one asks first when it has uncommitted work,
  closes what was running in it, and deletes its branch only if Relay made it
  and nothing on it is unmerged. The branch switcher sends a branch that is
  already open elsewhere to where it is, instead of failing on it.
- **Browser tabs, and design mode in them.** A tab opens from the "+" beside
  the sessions, or with ⇧⌘B, and is listed under them — as many as a project
  needs, each in Chromium, the engine the page is being built for, and a new one
  starting at the project's dev service when it is running. The Services panel,
  the Ports window and the palette open an address in the tab already on that
  server, or in a new one. ⇧⌘E turns on design mode: point at an element,
  click it, and what it is goes into an agent's prompt — its markup, the styles
  it computes to, the component that rendered it and the file and line that
  component is written in (React, Vue and Svelte in development), a picture of
  it, and a line saying what you want changed. It is typed and not sent, and
  the overlay comes back for the next click, so the change can be checked where
  it was asked for. ⌘R reloads the page and ⌥⌘I opens Chromium's inspector.

### Changed

- **A session's status is told by its shape, not only its colour** — a ring
  that turns while it works, a question mark when it is waiting for you, a
  tick when it has finished, and a plain dot for an error or for rest. Nothing
  pulses any more, and every spinner on screen turns in step; with Reduce
  Motion on, the ring closes and holds still.
- **Relay is larger to download, because it now carries Chromium** — about
  150 MB where it was 14. Chromium starts the first time a browser tab is
  looked at, and costs nothing before that.
- **An agent's status comes from the agent.** Relay adds its own hook to
  Claude Code's and Codex's settings, beside whatever hooks are already there,
  and the agent reports every prompt, tool call, permission prompt and end of
  turn through it; outside a Relay terminal the hook does nothing.
  "Waiting for you" now means a permission prompt or a question, not a
  sentence that happened to end in a question mark, and an agent that has
  finished no longer goes on showing as working. Where there is no hook, the
  mark the agent puts in the terminal's title is read instead. Codex is told
  to trust the hook in its own `config.toml`, so it runs without asking.
- **A plain terminal carries no status mark.** A shell, a build running in it
  or an editor is not news on a project's tile, and marking one said
  "working" whenever it printed anything. An agent started by hand in a
  terminal still shows its status for as long as it runs there.

### Fixed

- **A session chosen from the sidebar no longer takes the place of a file open
  to the left of the terminals.** A session takes a terminal's pane, and
  arrives beside the others when there is none.
- **A workspace saved by a newer build no longer loses every project when an
  older one opens it.** An arrangement of panes the older build cannot read is
  dropped on its own, instead of the whole workspace being set aside.
- **Typing into an agent no longer marks it working, and then finished, before
  anything is sent.** Every key counted as a command, and the input box
  redrawing around it as work done; only a line that is sent counts now.

## 0.6.0 — 2026-09-23

### Added

- **A file dragged onto a terminal arrives as its full path** — from Finder
  or from the project's file tree, several at once if need be. It is spelled
  the way Terminal.app spells it, with a backslash before anything a shell
  would read as syntax, so one drop works in a shell and in an agent's prompt
  alike; and it goes over as a paste, one per file, so an image dropped on
  Claude Code or Codex is attached as an image rather than typed out as text.
- **Pictures, PDFs, videos and recordings open in the file pane** instead of
  failing to: a picture fitted to the pane, zoomed with a pinch or ⌘+ and ⌘−
  and put back with ⌘0 or a double click; a PDF as pages to scroll, select and
  follow links in; a video or a recording with the system's own player, which
  says so plainly when macOS cannot play the format. The header shows the size,
  the dimensions, the page count or the length, and opens the file in the app
  it belongs to.
- **Markdown can be read as the page it makes** — with GitHub's tables, task
  lists and anchors, fenced code coloured the way the editor colours it, and
  pictures beside the file shown in place. Links open other files in Relay and
  web addresses in the browser; the page runs no scripts. The header, or ⇧⌘V,
  switches between the page and its source, and a Markdown file opens as
  whichever was chosen last.

## 0.5.1 — 2026-09-21

### Fixed

- **Nothing in the app: this is 0.5.0 with a green build behind it.** The suite
  that has to pass before a release is cut had been failing for a day, on two
  things that were never about the app — a compiler older than the one it is
  written on reading a rule about threads more strictly, and a three-core build
  machine running a hundred tests at once and then timing one of them. Both are
  fixed where they belong, in the tests and in CI. The number moves because a
  published build takes the next one, whatever went into it.

## 0.5.0 — 2026-09-21

### Changed

- **Text starts at 13 pt, in terminals and in files alike.** The terminal
  opened at 12.5 and a file at 12 — half a point apart for no reason anybody
  could give, and both a size smaller than the one every other editor on this
  machine starts at. A size already chosen is untouched; Reset now returns to
  13.
- **Relay keeps its files in `~/.relay`.** They were in Application Support,
  where a document-based app puts state nobody opens; these are not that — a
  workspace file worth reading when something looks wrong, a daemon log worth
  tailing, and now a directory agents write into. All three are reached from a
  terminal, and the old path was one nobody types twice. An existing install is
  moved on first launch, so there is nothing to do; the development build uses
  `~/.relay-dev`, as separate from it as it ever was.
- **The context strip under a terminal is gone.** It said how full the agent's
  window was, under every agent pane, and the agents' own interfaces now say
  it themselves — Claude Code puts it in its status line. Two places for one
  number is one place too many, and the one that was ours had to be kept in
  step with a transcript format we do not own. The setting that told it which
  window a Claude session runs with goes too, since it existed only to read
  that number. What still reads those transcripts is the conversation
  history, which is unaffected.

### Added

- **The terminal's text size can be typed in.** Getting from 13 to 20 was seven
  presses of a button, and the number beside them could be read but not
  changed. It is a field now: Return applies it, so does clicking away, "14 pt"
  and "13,5" are both understood, and a number past either end of the range
  comes back as that end rather than being ignored.
- **The rail opens with a chat, for the questions that belong to no project.**
  Asking one used to mean leaving Relay for a terminal, or adopting a directory
  as a project to hold a conversation that was never about it. Sessions started
  in the chat run in `~/.relay/chat`, a directory Relay makes the first time one
  is started, so an agent begins there knowing nothing about any codebase. It
  cannot be removed, reordered or renamed, and the panel beside it shows its
  conversations and nothing else.
- **⌘← and ⌘→ go to the ends of the line in a terminal.** They mean that in
  every text field on this system and meant nothing at all here: ⌘ has no
  encoding a terminal can send, so the keystroke was offered to the menus and
  then dropped. They are now sent as `^A` and `^E`, which is the same
  instruction in the only alphabet the other end reads — and left alone once
  a program has negotiated the Kitty keyboard protocol, since it is then told
  about the ⌘ itself.

### Fixed

- **The Claude limits are the ones Claude Code shows.** Relay read them from
  the cache the CLI keeps in `~/.claude.json`, and that cache is only rewritten
  when the CLI asks Anthropic for the figure itself — something it does rarely,
  since the numbers in its own status line come from the headers of ordinary
  answers and are never written down. A cache days old was the normal case: a
  five-hour bar could sit at 31% while the terminal beside it said 44%, and a
  window that had reset two days earlier was still drawn as a third spent.
  Relay now asks the same endpoint the CLI does, with the token the CLI already
  holds — macOS asks once whether Relay may read it — and falls back to the
  cache when there is no token or no answer. A cached window whose reset has
  passed is no longer shown at all, because "Relay does not know" is the truth
  and a stale bar is not.
- **The Codex limits follow the newest reading, not the newest file.** They
  were taken from whichever rollout log was written last, which is routinely an
  old conversation that has just been resumed — so the weekly bar could show a
  figure from a month ago — or a session opened a moment ago that has heard
  nothing from the provider yet, which left the bar empty. Relay now compares
  the time on the records themselves. A window whose reset has passed reads as
  empty rather than as whatever it last held, since Codex writes a record for
  every answer it gets and anything spent since would have left a newer one.

## 0.4.0 — 2026-09-20

### Changed

- **⌘+ and ⌘− resize the file in front of you.** They always resized the
  terminal, whatever was on screen. They now follow the same rule ⌘W does —
  the shortcut is about what the keyboard is in — and a file is read at its
  own size, kept apart from the terminal's and remembered between launches.
  The size reaches the pane that is already open, too: a text view keeps what
  it was built at, since its font is in the view, in what it types with and on
  every character at once, so the new size only showed on a file closed and
  opened again.
- **⌘W closes the pane in front of you.** It always closed the selected
  session, whatever was on screen — so a file opened beside a terminal could
  not be closed with the key every window on this machine closes things with,
  and pressing it took down the agent in the pane next door instead. The
  command is now called Close Pane, and closes a file when a file is what the
  keyboard is in. A rebinding of it is kept: it is stored under what the
  command is, not what it is called.

### Fixed

- **Closing a terminal no longer closes the file open beside it.** Closing a
  pane picks the next session to show, and when nothing else on screen was a
  session — because the only other pane was an editor — it replaced the whole
  arrangement rather than that pane. The terminal closed and took the file with
  it, which from the outside looked as though the close button had shut the
  wrong pane. A session now takes over the first pane of its own kind, and
  arrives beside an editor rather than instead of it.
- **A review sent to a new agent no longer disappears on the way.** The notes
  were forgotten at the moment the session was asked for rather than when the
  text reached it, and the text itself was only handed over on the next update
  the daemon sent. A session that reached its prompt while the request was
  still in flight never got another update — so nothing was typed, and there
  was nothing left in the panel to send again. The notes now travel with the
  text and are forgotten only once it is in the prompt, and the hand-over is
  tried again when the session answers and when its terminal appears. It also
  waits for the terminal rather than only for the status: without one Relay
  cannot ask whether a bracketed paste is understood, and a review then went in
  as plain keystrokes — every newline sending the half-written message before
  it.

### Added

- **The project's own linter marks the file as you write it.** A wavy line
  under what it objected to — red for an error, amber for a warning, and the
  message under the pointer when the hand stops on one — and a strip under the
  header saying how many there are, what the one nearest the caret says and
  which tool said it; clicking the strip walks to the next. A complaint about
  blank space is marked on what the space follows: half of what a linter
  objects to is a line break, and a range of two empty lines underlines
  nothing at all. A file that could not be parsed at all — a string opened
  with one quote and closed with another — is marked along the whole line the
  parser gave up on, because what it reports is where it stopped rather than
  what broke it, and one character there is a dot nobody reads as a mark. It runs the checker the checkout already
  carries and installs nothing: ESLint or oxlint from `node_modules` for
  JavaScript, TypeScript, Vue, Svelte and the rest, `php -l` for PHP,
  `gofmt` for Go, `shellcheck` for shell scripts, `ruby -c` for Ruby, Ruff or
  Python's own compiler for Python, and SwiftLint for Swift where it is
  installed with `swiftc -parse` where it is not. A syntax error is reported
  by all of them, which is what an unterminated string or a stray brace is.
  ⌘S writes the file at once and corrects it after: waiting for the formatter
  first made the save take as long as the formatter does, and in that time
  what is on disk is not what is on screen — which the agent in the pane next
  door may be reading. The correction is a second write when there is one to
  make and none when there is not. What corrects it is what the tool can:
  ESLint's own
  `--fix`, `gofmt`, Ruff, Pint for a Laravel project and SwiftLint where it is
  installed — one run does it: ESLint answers with the corrected text and what
  it still objects to at the same time, and asking it twice is two node
  processes for one question — most of a second each on a real project. The
  same text is never asked about twice either, so the redraw that follows a
  save asks nothing at all. The wait before a check is a third of a second
  rather than a whole one — it is added to the checker's own, and a second of
  waiting in front of two thirds of a second of ESLint made an error take
  over two seconds to appear — and a run whose answer stops being wanted is
  killed rather than left to finish. What a terminal's `PATH` is, which takes
  a login shell three quarters of a second to answer, is asked for at launch
  rather than by the first person waiting on a linter. Where a project keeps `eslint_d`, that is used
  instead: the same ESLint with the process kept warm between runs. The corrected text goes into the buffer and is written once, so
  the file changes once and undo still means something — and a keystroke made
  while the tool was running is never overwritten by a correction made before
  it. Only ⌘S: leaving a pane or closing it writes the file as it stands,
  since a deliberate save is a moment to rewrite a file in and a glance
  elsewhere is not.
  They are found the way a terminal finds them rather than the way an
  application launched from the Dock does: a GUI process is started with four
  directories on its `PATH` and none of them is where node, Homebrew or a
  virtual environment put anything — so `node_modules/.bin/eslint`, whose
  first line is `#!/usr/bin/env node`, did not start at all and the linter
  looked switched off rather than broken. What is checked is the buffer rather than the file on disk — ESLint is
  given it on standard input with the real file name so that its own config
  still governs it — a moment after the typing stops, and again when the file
  is written out. A project with no such tool is not told about it: the strip
  stays away and nothing is underlined.
- **One file at a time.** Opening another writes the current one out and gives
  it the same pane, rather than splitting again for every file somebody
  glances at — the pane is somewhere to read and correct the file an agent is
  working on, beside the agent, not a desk to stack documents on. A layout
  saved before this rule opens its first file and drops the other panes
  instead of leaving them behind saying the file is unavailable.
- **A file can be opened beside the terminal and edited there.** The Git panel's
  hover strip has a pencil: it opens that file in a pane next to whatever is
  focused, with the agent still visible and still working in the pane beside
  it. Code is coloured from a real parse of the file rather than a list of
  keywords, so a keyword inside a string stays a string and the forty-odd
  languages tree-sitter ships with — Swift, Go, PHP, TypeScript, Python, SQL,
  YAML, shell and the rest — are coloured without a word list per language
  having to be kept. A file is rarely one language, so the markup inside a PHP
  template, the script and the styles inside a page, and a fenced block inside
  Markdown are each coloured as what they are; and a template whose own grammar
  nobody ships — Vue, Svelte, Twig, ERB, Blade — is read as the language it is
  mostly made of rather than left white, with the tags that language is
  actually for painted over the top: `@section` and `{{ }}` in Blade,
  `defineModel` and `v-if` in Vue, `{% %}` in Twig, `<% %>` in ERB. Saving is not something to remember: ⌘S writes the file,
  and so does leaving the pane or closing it, because an agent reading the file
  in the terminal beside it must not be reading a version that only exists on
  screen. The merge panes are coloured by the same parse.
- **⌘-click a name to go to where it comes from.** Hold ⌘ and the name under
  the pointer is drawn as a link and the pointer becomes a hand; click it and
  the file that declares it opens in a pane with the caret on the declaration. The file being read answers
  first — a helper declared above the call needs nothing else — and the project
  answers after it, from an index built by reading the project once with the
  grammars' own tags queries, the same ones GitHub's code navigation is built
  on. That covers C, C#, C++, Dart, Elixir, Go, Java, JavaScript, Lua, OCaml,
  PHP, Python, Ruby, Rust, Swift and TypeScript, with nothing to install: no
  language server, no `gopls`, no toolchain of somebody else's. A page and a
  single-file component are read through to the script inside them, so a `.vue`
  or a `.svelte` declares what its `<script>` declares rather than nothing at
  all — and a script that says `lang="ts"` is read as TypeScript, without
  which a type argument turned into a chain of comparisons and took the
  declarations around it down with it. What counts as a declaration is wider
  than a grammar's own table of contents: a `const` holding a store, a
  composable or a number is one, so are a type alias, an enum, a class
  constant and the names a destructured `const` binds — and so is everything a
  module's own factory declares, which is what a Pinia store or a composable
  is made of: a `const` inside a function that is an argument of a call, which
  is neither the top level of a file nor a local of anybody's. A name nothing declares
  but a file is named after — `<UserCard />`, and the import above it — opens
  that file. Last of all it asks the dependencies, which are read in the
  background once a file has been opened: a JavaScript package as the one
  bundled declaration file its manifest points at, `node_modules/.pnpm` and
  its links included, so a framework's compiler macro like `defineProps` is
  found where it is actually declared. A Composer package is indexed by file
  name rather than read — 96 MB of source is forty seconds of parsing for an
  answer that is usually the file name, since PHP puts one class in a file and
  names the file after it — so `Model` opens `Model.php` and a method of it
  does not. Anything opened out of a dependency is read-only, because an edit
  there is undone by the next install without a word. What is not read is what the project did not write: `node_modules`,
  `vendor` and the rest are skipped, so a name that only a dependency declares
  — a framework's compiler macro, say — is reported as not found rather than
  jumped to. What it knows
  is names rather than types, so a popular name comes back from several places
  at once. A key written as a string — `t('common.seo.subtitle')` —
  is looked for where a project keeps its translations rather than among its
  names: the file is usually called after the key's first segment, so the path
  is tried both with that segment and without it, and a file that merely
  contains the words does not count as defining the key. When nothing
  declares a name at all, the answer offers to search for it in every file
  instead of stopping at "not found" — unless what was clicked was a word
  inside a plain string, which is a value rather than a name: nothing declares
  `'theme_preference'` anywhere, so it is not drawn as a link, nothing is said
  about it, and nothing is gone to: a `const max` in another file has nothing
  to do with the word `max` inside `value === 'max'`. A string with dots or slashes in it keeps
  its link, because a key and a path do name something.
  A name that is local to where it is written — a parameter, a `const`
  inside a function — is not asked of the index at all: the grammars carry a
  second query for scopes, and it answers from the twelve lines around the
  click. The caret goes to the declaration and every use of it inside its own
  scope is marked, until the caret leaves them. It goes to the likeliest of them rather than stopping to ask —
  ranked by what the click itself says: the module or namespace the file has
  already named at the top of itself, a declaration beside the caller over one
  across the project, the project over what it depends on — and says quietly
  that there were others, with one press to see them. ⌘[ goes back to where
  the jump started, and the Editor menu carries both. The index is read in the
  background when a file is opened, re-read for one file when it is saved, and
  forgotten for the project when the file tree is re-read.
- **⌘F finds in the file in front of you, ⇧⌘F in every file of the project.**
  ⌘F puts a field at the top of the pane: every match is picked out in the
  text, the one being looked at more strongly than the rest, Return walks
  forward and ⇧Return back — both wrapping round — and Escape gives the file
  back. ⇧⌘F opens a panel over the window with the caret already in it: the
  lines come back grouped by file with the match picked out, from the
  project's own files rather than from `node_modules` and `vendor`, and
  Return or a click opens the file in a pane with the caret on the match.
  Pressing ⌘F where no file is open opens that panel instead, since somebody
  pressing find in a terminal is still looking for something. The panel is
  laid out the way every find-in-files is: the query and its three switches —
  match case, whole words, regular expression — then the matching lines with
  the file each came from on the right, and the file itself below, coloured
  and scrolled to the line — coloured by the same parse the editor uses, which
  needed teaching that a text view whose contents were swapped has to be
  coloured again: nothing announces that, since the notification a text view
  sends is about editing. A line on its own rarely settles whether it is the
  one that was meant, and opening each candidate to find out is what the panel
  exists to save. The search is
  Relay's own — a `rg` that may not be installed is a feature that works on
  the machine it was written on — spread over the cores the way the symbol
  index is, and run a quarter of a second after the typing stops.
- **⌘P finds a file by its name.** The command palette ranks the project's
  files alongside its commands and by the same reading of what was typed, so a
  file name answers with the file and a verb answers with the command without
  the palette having to be told which was meant. A name may be matched by its
  parts — `gtpnl` finds `GitPanel.swift` — while a folder is matched only by
  what is written out, because a path is long enough that letters scattered
  through it match almost anything. The list of files is walked when the
  palette first opens and re-read with the file tree.
- **The file tree has the menu it should have.** Right-click a row: New File
  and New Folder — the name is typed in the tree, where the file will be —
  Copy Path and Copy Native Path, Reveal in Finder, Rename, and Delete. Right-
  clicking the empty space below the rows offers the same for the project
  itself. A rename takes the open buffer and its pane with it, saving before
  the move rather than after — a save that lands after a rename writes the old
  name back into existence — and Delete moves the file to the Trash, where it
  can be got back, after asking.
- **The Files tab is a file tree.** The last of the placeholder tabs is built:
  the project's folders, read when they are opened rather than at launch, with
  dotfiles listed — `.env` and `.gitignore` are what a tree is opened for — and
  git's own database left out. A click opens the file in a pane; an open file
  is marked, and one with unsaved work carries the same dot the pane header
  does. Opening a file the other way round — from the Git panel, from a
  ⌘-click, from a saved layout — opens the folders down to it and brings its
  row into view, and the file being worked in is marked apart from the ones
  merely open beside it: with several open the mark follows the caret, and it
  stays on the last one when the caret moves to a terminal. Nothing watches the directory yet, so a file an agent has just written
  appears when the tree is re-read.

- **Projects and sessions can be dragged into the order you want them in.** Take
  hold of a tile in the rail or a session in the sidebar: it lifts, follows the
  pointer, and the rest slide aside to leave the gap it will drop into. The
  arrangement is remembered — sessions outlive the window, so their order does
  now too. A session can no longer be dragged from the sidebar onto a pane;
  clicking it still shows it in the focused pane, and a pane's own header still
  moves the terminal between panes.
- **Pull and push ask where they are going.** The Git panel's menu opens a
  panel where the remote, the branch and the flags are one row reading as the
  command they spell, with that command written out underneath. A pull offers
  `--rebase`, `--ff-only`, `--no-ff`, `--squash`, `--no-commit`, `--autostash`
  and `--no-verify`; a push offers `--force-with-lease`, `--tags`,
  `--set-upstream` and `--no-verify`. Whatever the chosen flags rule out goes
  grey rather than quietly unticking itself, so which flag is in the way is
  visible. A pull sets uncommitted work aside and puts it back, which is what
  every other client does and what git will not do unasked — it refuses to
  pull at all while anything is uncommitted. A push also lists the commits it would send, and says when the
  remote has no such branch yet — and when there is nothing to send it is
  refused rather than offered, since a panel that has just said "nothing to
  push" should not have a live Push button under it. Counted from
  `remote..HEAD` rather than from how far ahead git says the branch is, because
  after an amend those two disagree exactly where it matters; a branch the
  remote has never heard of, and `--tags`, both still count as something to
  send. Force pushing lives here now rather than in
  the menu, because it is worth seeing spelled out; it is always with a lease,
  so it refuses when the remote has moved since you last fetched.
- **⌘⇧T brings back the session you just closed.** A shift on top of the
  shortcut that opens a terminal, exactly as it is in a browser: press it again
  and it goes further back, up to ten. What comes back is the command in its
  directory under its name — the same definition of "the same session again"
  that the restart button uses — and the list survives a relaunch, since Relay
  is restarted often enough that forgetting it on quit would be forgetting it
  altogether. It works on the project in front of you, and a service is not on
  the list: those are started and stopped by the buttons beside them, and the
  shortcut for reopening a terminal has no business starting a dev server.
- **⌘⌫ clears the line in a terminal.** ⌘ never reaches the program running
  there, so the one deletion shortcut every other field on macOS answers did
  nothing at all.
- **Relay can be told which context window Claude sessions run with.** General
  settings, beside the text size. Claude Code records which model answered but
  not whether it was the long-context variant of it, so a 1M session read as
  though it were on 200K until more than 200K had been put in it.

- **Conflicts are resolved in Relay.** When a pull stops on a conflict the panel
  that answers it opens by itself: the conflicted files, what each side did to
  each of them, and three ways out — take ours, take theirs, or open the file in
  a merge of three panes.

  The middle pane is the file, not git's hand-over notation. There are no
  `<<<<<<<` markers in it at any point: a passage nobody has answered stands
  there as what both sides had before either of them touched it, and what is
  still in dispute is held beside the text rather than spelled out in it. Each
  passage is answered where it stands — the arrow in the gutter beside it takes
  that side, the cross refuses both and leaves the ancestor — and once it has an
  answer it stops being marked at all: no tint, no arrows, because the mark is a
  question rather than a record of one. Everything only one side changed is
  already applied when the panel opens, because git's own merge did it.

  It is still an editor, because the answer to a conflict is often a line from
  each rather than either as written: taking a side is a shortcut for an edit,
  the passages are followed through whatever is typed around them, and Apply is
  refused until every one of them has an answer. The three panes are set to one
  line height and a passage shorter in one of them than the others has the
  difference left as empty room, so line 40 is line 40 in all three. The sides
  are named by the operation — "Already rebased" against "Being rebased:
  85a186c" — since which of them is "mine" reverses between a merge and a
  rebase, and `HEAD` on its own says nothing at all. The footer then finishes
  the rebase, merge, cherry-pick or revert — or aborts it.

### Changed

- **A conflicted file in the Git panel carries no badge.** The word "conflict"
  sat in a row whose width belongs to the file's name, and squeezed into what
  was left of a narrow panel it broke across lines a letter at a time. It is
  gone: anything conflicted opens the panel that resolves it, which says so
  louder than a word in a row ever did. Nothing else in that row gives way
  either — the name truncates instead, since a shortened name still reads and a
  wrapped count does not.
- **The cross on a service's pane closes the view, not the service.** It ended
  the process, so the gesture that everywhere else on macOS means "I am done
  looking at this" killed the dev server being looked at. Now the pane goes
  away and the service keeps running, still in the sidebar and one click from
  being looked at again; ⌘W does the same thing, being the same gesture by
  keyboard. Stopping a service is the stop button beside it, which is named
  after what it does. Nothing else changes: a shell's cross still closes the
  shell.
- **A tab in the right-hand panel no longer closes it.** Clicking the tab that
  was already open took the panel away, which made one target mean two things —
  and the meaning nobody intended is the one that happened whenever the panel
  was already showing what was asked for. The toggle in the title bar, and its
  shortcut, still close it.
- **A Git tab that says "not a repository" can be asked again.** Answered once
  when the project was adopted, it stayed answered for the life of the app —
  which is wrong for a folder that has been cloned or `git init`-ed since.
  Clicking it looks again, the way the Docker tab already did.
- **The Session and Project menus no longer list nine numbered entries.**
  `Session 1` through `Session 9` were there to carry ⌘1…⌘9, which macOS can
  only attach to a menu item; they filled half of each menu and named nothing.
  The shortcuts are unchanged, and Settings is where they are described.

### Fixed

- **Updating no longer ends every session.** The sessions live in a daemon that
  outlives the app, and the app used to retire any daemon that was not the one
  it shipped with — which after an update is always true, so the terminals and
  the agents in them died on the way. A daemon with sessions in it is kept now,
  scrollback and all; the changeover finishes by itself once the last session is
  closed.
- **A 127K conversation on the 1M window no longer reads as 64% full.** Where
  nothing states the window, Relay now takes the model the project last ran as
  evidence of which variant it is on, and a model named on the command line as
  the answer outright.

## 0.3.2 — 2026-09-17

### Changed

- **The project header is two lines, not one crowded one.** The name has the
  whole width to itself; the path and the two buttons share the line below,
  since a path can be truncated and a button cannot. Renaming used to happen in
  a field about a word wide, squeezed between the name and the icons.
- **One click on the project name renames it.** It took two, which is a gesture
  nobody guesses at and nothing on that line competes for.

### Fixed

- **Renaming anything while a session runs is possible again.** The focused
  terminal claimed the keyboard on every redraw, and a redraw happens on every
  change to the model — so with an agent writing output, the caret was pulled
  out of the field several times a second and the name could not be typed. The
  terminal now takes the keyboard only when nothing else in the window is
  taking text; clicking the terminal still works, because that asks outright
  rather than as a side effect of drawing.
- **A project is called what its folder is called.** A directory named
  `storefront` was added as `nuxt-app`, because `package.json` was allowed to
  overrule the folder — and what `package.json` says is what the scaffold wrote
  there: every Nuxt app is `nuxt-app`, every Vite one `vite-project`, until
  somebody edits it, and nobody does. The name and the path beneath it
  disagreed on the same screen. Projects already added keep the name they have;
  Project Settings renames them.

## 0.3.1 — 2026-09-17

### Added

- **SSH hosts can be added, edited and deleted from the list.** Until now the
  panel could only read `~/.ssh/config` and connect to what it found there, so
  every new machine meant leaving the app for an editor. The list now carries a
  plus, and every row a pencil and a bin.
- **Edits go into the config OpenSSH itself reads.** A host added in Relay is a
  host `ssh` reaches from any terminal, and a host edited in Relay is edited
  where it was already written — including in a file pulled in by `Include`,
  which is where a work machine usually keeps them. Nothing is kept in a list
  of Relay's own, because a second place to look is a second place to be wrong.
- **The rest of the file is left exactly as it was.** Only the lines of the
  block being changed are rewritten, so comments, blank lines, the order of
  directives and somebody's preference for `Hostname` over `HostName` all
  survive. Directives Relay has no field for — `ControlMaster`,
  `ServerAliveInterval`, anything — are shown in a text box and written back
  untouched, so the editor cannot become a way of deleting what it does not
  understand. Before the first write, a copy of the file is kept beside it as
  `config.relay-backup`.

- **The config file itself is one click away.** A form is the quick way to add
  a machine; it is not the way to write a `Match` block or move twenty hosts
  around. The list now opens `~/.ssh/config` in a Relay session with whatever
  `$EDITOR` says, and a host's context menu opens it at that host's own block.
  Neither replaces the other: the form knows what a host usually needs, the
  file knows everything else.
- **A key's passphrase is asked for once, in a dialog, and then never again.**
  The prompt people actually meet is not the server's password but their own
  key's. The host editor now shows which key the host would authenticate with
  and whether `ssh-agent` is holding it; when it is not, one button opens a
  sheet, and what is typed there goes straight to `ssh-add
  --apple-use-keychain`. From then on the login keychain remembers it and `ssh`
  reads it back by itself — Relay is not in the loop at all, and never was:
  the passphrase is never written to a file, never passed as an argument and
  never put in the environment, each of which any other process of this user
  could read. A second button offers the `Host *` settings that make that
  survive a restart.

- **A development build that can be worked in without ending your day.**
  `make dev-install` produces Relay Dev: its own identity, name, icon, data and
  daemon, standing beside the released app rather than replacing it. Before
  this there was no safe way to use Relay for real work while changing it —
  the client retires a daemon whose binary is not the one it shipped with, and
  that hash changes on every build, so launching a freshly built app shut down
  the daemon holding every session that was being worked in.

- **The first project is added from the middle of the window.** With nothing
  in it, the only thing to do was a plus at the foot of an empty strip — the
  smallest target on screen for the one action available. The welcome pane
  carries the button now, and the rail grows its own back once there is
  something to add to.

### Fixed

- **Restarting a session starts the same session again.** It was rebuilt from
  the kind alone, so everything else was thrown away: an SSH connection came
  back as a bare `ssh` answering with its usage message, an agent started with
  arguments came back without them, a session opened in a subdirectory came
  back in the project root under a new name, and a service came back as an
  ordinary terminal its own panel no longer recognised. The daemon knew all of
  it the whole time; the button simply never asked.
- **An SSH session no longer reports the branch of the Mac it was started
  from.** Every session row carried the project's git branch and diff, so a
  connection to somebody else's server sat under `master +589 −36` — true about
  the wrong computer. An SSH row now says where it is connected instead,
  `user@host` as the configuration spells it.
- **Connecting to a host closes the host list.** It started the session and
  then stayed open in front of it, so every connection ended with dismissing a
  panel that had already done its job. The command palette and the branch list
  have always closed themselves on the way out; this one had not.

### Changed

- **Opening the diff leaves the panel the width it was.** It used to widen the
  right-hand panel to fit a line of code, which is a reasonable width and not
  ours to impose: the panel is dragged to a size on purpose, and a button that
  moves the window's furniture as a side effect of showing something is a
  button nobody can predict.

## 0.3.0 — 2026-09-16

### Added

- **A TODO panel, after Git in the right-hand strip.** It searches the
  project's comments for the words it marks unfinished work with — `TODO`,
  `FIXME`, `HACK`, `XXX` and `BUG` unless the project says otherwise — and
  lists what it finds with the file and line each one sits on. A note written
  in a comment is written to be found later, and later never arrives, because
  nobody greps their own codebase for the word.
- **Notes can be handed to an agent.** Tick the ones that belong together,
  write what should be done about them, and send it to the agent already
  working or to a new one; it lands in the prompt unsent, the way a review
  does, so it can be read over first. Each row also carries a button that
  opens it in the project's editor, at its line.
- **Which words count is a project setting.** A codebase that marks its work
  some other way has no other way to be found. Set it in Project Settings, or
  from the gear in the TODO panel itself — a list you are looking at is where
  you notice it is looking for the wrong things. Both write the same setting,
  so neither can go stale while the other is used.
- **Projects that build a Mac app are drawn with their own icon.** The search
  for a project's mark knew every way a website carries one and no way a native
  app does, so a repository with an `AppIcon.icns` in `Resources` was shown as
  two letters over a colour.

### Fixed

- **The app no longer dies when it cannot find its own string table.** Looking
  a word up was the first thing the menu bar did, before any window existed,
  and the lookup trapped rather than returned — so a bundle assembled or
  unpacked wrong did not start in English, it crashed with a stack trace
  blaming a menu. The keys are the English text, so there is always something
  readable to fall back to. The build script now also refuses to assemble a
  bundle without the strings in it.
- **Every project tile has an outline.** It was drawn under the artwork rather
  than over it, so any icon that filled its tile painted over the very line
  meant to contain it — and those were the tiles that most needed one.
- **The project rail draws every icon at one size.** The inset was the same for
  every project and the artwork was not: an application icon fills its canvas
  and a logo exported for a readme carries a third of its width in empty space,
  so one was drawn half the size of the other. Artwork is now trimmed to what
  it actually draws, and an icon that is a tile in its own right is drawn edge
  to edge instead of on a plate inside a plate.
- **The TODO list no longer shows the project its own test data.** A line of
  code that quotes a comment — `"a.swift:9:// TODO: earlier"` in a fixture — was
  read as the comment it quotes, so the panel filled with fragments ending in
  stray quotes and brackets. A marker inside a string literal is a value, and
  the search now says so — including inside a Swift raw string, whose whole
  purpose is that nothing in it means anything.
- **The TODO list no longer lurches when it is overscrolled.** Every row
  carried Relay's own tooltip, which measures the control it is attached to and
  reports its position as the list moves — a hundred of those talking at once
  during a scroll is the scroll. Rows now use the system's tooltip, which costs
  nothing, and are a uniform height, so the list no longer revises its guess
  about how tall it is mid-gesture.
- **Docker's stack controls sit on the section's own line.** Up, down, restart
  and logs had a strip of their own under the heading, at a size nothing else
  used — a toolbar for a section that already had one. They are now beside the
  refresh button, at the size every other panel action is drawn at.
- **Panel buttons are all one size.** The actions in the right-hand panels were
  drawn at 18, 20, 22 and 24 points depending on where they had been added, and
  the send button used a different glyph ratio again, so it read a size larger
  than the button beside it.
- **The ahead and behind counts are the same colour wherever they appear.** The
  project tile drew commits to push in green and commits to pull in blue, and
  the Git panel drew both in grey — the same two facts, stated twice, looking
  like two different ones.
- **The Git tab works from the moment the window opens.** It used to wait for
  the session daemon to start and then for the first poll twelve seconds later,
  and until both had happened it was disabled and claimed the project was not a
  repository. Whether a project holds one is a question for the filesystem, and
  it is now asked before anything else is started.

### Documentation

- **The readme says to move the app before opening it.** macOS runs a freshly
  downloaded app from a temporary copy until it is moved, and that copy is
  where it fails to find parts of itself. The step was missing, and it is not a
  tidiness one.
- **The readme installs the app instead of building it.** It opened with Xcode
  version requirements and a `git clone`, which is a door most people will not
  walk through to try something. It now points at the releases page; building
  from source has moved to the development section, where it was always the
  audience.

## 0.2.1 — 2026-09-16

### Changed

- **Clicking a container opens a prompt inside it.** It used to open the
  container's log, which is something you ask for rather than the thing you
  came for — getting inside is. Bash where the image has it and `sh` where it
  does not, which is most of them. A container that is not running has nothing
  to step into, so it still opens the log, which is the only account of why it
  stopped. Both stay in the right-click menu.

### Fixed

- **Arrowing through a list left the list where it was.** In the branch window
  and the command palette the highlight walked off the bottom and carried on
  going, so the keyboard was somewhere the window was not showing — while the
  ports and SSH windows followed it, which made it look like a list that
  sometimes worked rather than two that never did. All four follow it now.
- **Compose Up reported that the project had no Compose file, with that
  project's containers listed beside the button.** Relay looked for the four
  names Compose looks for and gave up, while a stack split into
  `docker-compose.local.yml`, `.stage.yml` and `.prod.yml` has none of them.
  Docker writes the file it was given onto every container it creates, so the
  running stack is now asked rather than guessed at, and the file and the
  project name are passed to Compose rather than left to whichever directory the
  command started in — which is what made Up act on a different stack than the
  one on screen. When nothing is running the search knows the environment
  suffixes too, preferring the local one and never a production file: the file
  this picks is the one the button starts.
- **Relay reads containers from the engine itself rather than from the `docker`
  command.** Every engine on a Mac serves an HTTP API on a unix socket, and
  Relay now asks that directly — which means the panel fills for whichever
  engine is actually running rather than for whichever one a CLI context points
  at, without needing a `docker` binary on a PATH that a daemon launched by the
  GUI never inherits, and without starting a process every few seconds for as
  long as the panel is open. Docker Desktop, Colima, OrbStack and Rancher
  Desktop are all looked for, as is an explicit `DOCKER_HOST`. Compose is
  unchanged and still goes through the CLI: it is a client-side tool with no
  presence in the engine's API at all.
- **The Docker panel answered a closed engine with four lines about a socket
  path.** It is one thing — nothing is running — and it is now said in one
  line, with a button that starts what Relay found: Docker Desktop, or Colima
  for a machine that would rather not run a desktop app at all. A machine with
  no engine installed gets neither a button nor the socket, but the one
  sentence that applies: Relay shows the containers an engine is running and
  does not carry one. Anything Relay has not been taught to read is still
  passed on word for word, because an error it cannot name is one it must not
  paraphrase.
- **A project's status dot was missing its right-hand side.** The tile drew it
  three points outside its own frame, which works exactly as long as nothing
  laying the tile out clips — and the tile carries a context menu, which does.
  The dot sits inside the tile now, where the ring around it was already doing
  the job of separating it from the artwork.
- **Panels showed what was true when they were opened.** Containers are started
  in Docker Desktop, files are written by agents, branches are checked out in a
  terminal — none of which Relay is told about, so the Docker panel, the review
  panel, the branch window and the history list each sat on an answer from
  whenever they had last been asked. They keep themselves current while they are
  on screen now, and stop the moment they are not. An answer that has not
  changed is not applied, so a panel nobody is touching does not redraw, and a
  diff being read does not reload under the reader.

## 0.2.0 — 2026-09-16

Reviewing what an agent just did, beside the terminal it is still running in.

### Added

- **Review what an agent changed without leaving Relay.** The Git panel lists
  the working copy — conflicts, staged, and everything still in flight — and
  `⌘G` opens the review window: files on the left, the diff of the one you
  picked on the right, with staging, unstaging, discarding and committing where
  you are already looking. Discarding asks first, because for an untracked file
  it means deleting it.
- **Terminals draw on the GPU.** Scrolling a full window of text was redrawing
  every glyph on the CPU, which is exactly the work a graphics card exists for;
  the same scroll now costs a fraction of it. A machine that cannot manage it
  falls back to the old path on its own, and the switch is in Settings →
  General → Terminal for one that can but should not.
- **`⇧↩` starts a new line instead of sending the prompt.** A terminal sends a
  bare carriage return for Return whatever is held down with it, so an agent
  cannot tell the two apart — which is why other terminals have to be
  configured by hand. Relay sends the sequence that means "another line" itself,
  and leaves the keystroke alone for a program that has asked to see modifiers
  on its own.
- **The terminal text size can be changed**, with `⌘+`, `⌘-` and `⌘0` for the
  size it started at, in the View menu, and in Settings. It applies to every
  terminal at once and survives a relaunch.

### Changed

- **⌘P finds a command by whatever you call it.** The palette used to match the
  text on screen, character for character, so an interface in Russian could not
  be searched in English — «Переключить ветку» was invisible to "branch" — and
  neither could an interface in English be searched in Russian. It now matches
  every language Relay ships, reads a query typed on the wrong keyboard layout
  ("икфтср" is "branch"), understands Russian written in Latin letters
  ("vetka"), tolerates the ending of an inflected word, accepts letters in order
  without being together ("swbr" finds Switch Branch), and orders what it found
  by how well it fits rather than by where it happens to sit in the list. The
  shortcut list in Settings searches the same way.
- **Releases are signed with Developer ID and notarised by Apple.** Until now a
  build carried a development certificate, which signs an app for the machine
  that made it: every other Mac refused to open it without being talked round in
  System Settings. `./Scripts/release.sh` now builds, signs, notarises and
  staples, and produces both the archive the in-app updater downloads and a disk
  image to drag into Applications. Because the signing identity changes, macOS
  will ask once more for the permissions it has already been given.

### Fixed

- **The pointer never changed shape.** Every button, row, tab and field kept the
  arrow, so nothing on screen admitted to being clickable until it was clicked.
  The shape was declared with an AppKit cursor rectangle registered on a view
  sitting behind the SwiftUI content, and on a current macOS that view is never
  consulted: the rectangle was registered and then never applied. SwiftUI has
  stated the pointer itself since macOS 15, and Relay now says it that way,
  keeping the old route for macOS 14. The places that had never declared a shape
  were filled in at the same time — switches, pop-up menus and the header that
  collapses a section show the hand, text fields the caret, a pane's header the
  open hand it is dragged by — and the divider between two panes holds the
  resize pointer through a drag that outruns it.
- **The context line under a terminal went missing.** The readers were pointed
  at the panes as they were a moment *before* the session was shown, so the
  terminal in front of you was never the one being read — the figure appeared
  for whatever had been on screen previously. They now follow the panes as they
  change, and a newly shown terminal is read at once rather than at the next
  ten-second tick.
- **A freshly started agent had no context line at all**, while the pane beside
  it had one — which reads as a broken pane rather than as a session nobody has
  spoken to yet. The row is now under every agent terminal, showing a dash until
  there is something to read: the CLI writes its transcript as it answers, so
  before the first reply the figure exists nowhere to be read from.
- **The context bar's tooltip appeared in the middle of the terminal.** The bar
  is a strip the width of the pane, but only its left end is drawn on — and the
  button underneath ran the whole width, so the label describing the numbers
  floated above the empty half, and a click on blank strip opened the panel. The
  control is now as wide as what it shows, and says nothing at all while the
  panel it opens is already up.
- **A resumed conversation showed no context figure.** Resuming appends to the
  transcript the earlier conversation left behind, so the file is always older
  than the session reading it, and Relay — which matches a session to the
  transcript that began alongside it — found nothing. The command says which
  conversation it is resuming, and that is now what is looked up.
- **The palette described a session in English** while every other place showing
  a status had it translated.

## 0.1.0 — 2026-09-15

The first release.

### Added

- **Every past conversation, not just Relay's own.** The History panel now lists
  the Claude and Codex conversations belonging to a project — read from the
  agents' own transcripts, so it is the same list their `/resume` offers,
  whether the conversation was started in Relay or in a terminal. Clicking one
  resumes it: the agent continues where it left off rather than starting again.
- **How full each agent's context window is**, under the terminal it belongs to:
  a meter, the percentage and the token count, with the breakdown behind a
  click — what is cached, what was sent fresh, what the reply and its reasoning
  cost. Read from the transcripts the CLIs write as they go, so nothing is asked
  of anyone and the figure cannot disagree with the agent's own.
- **Clicking the usage opens it properly.** The popover always shows every
  window — it is where you go to look properly — and its Detailed/Compact switch
  governs the bar alone. The bar starts compact, keeping one line per agent: the
  window nearest to running out rather than the shortest one, because that is
  the limit that will actually stop you. Hovering the bar still lists them all.
- **A status bar along the bottom** showing what each agent has left of its rate
  limits: a meter per window, the percentage, and how long until the nearest one
  rolls over. The figures come from the CLIs' own caches on disk, so they cannot
  disagree with what Claude Code or Codex would tell you, and Relay asks nobody
  for them. It appears only when there is something to report, and can be turned
  off in Settings.
- **Relay updates itself.** It asks GitHub for the newest release on launch and
  every six hours; when one is newer than the running build a pill appears in
  the title bar, and clicking it downloads, checks and installs the new version,
  then restarts into it. Sessions are untouched — they belong to the daemon.
  The check lives in Settings → About and can be turned off, which stops the
  request rather than hiding its answer; it carries a user agent and nothing
  else.
- **Projects wear their own icon.** A repository nearly always ships a favicon
  or an app icon, and it says which project this is far better than two letters
  over a colour. One can also be chosen or dropped in the project's settings.
- **A control under the keyboard looks like a control under the pointer**, and
  carries an accent ring on top: one shade of grey away from near-black is not
  an answer to "where am I".
- **Left and right walk a row's actions.** Up and down pick the port or host,
  left and right move along what that row can do, Return runs it. Arriving on a
  row always starts from its first action, so Return is never a keystroke away
  from killing a process you had not looked at. Settings changes section with
  the same keys.
- **The panels take the keyboard.** Arrows move through the ports and hosts,
  Return acts on the highlighted row, Escape closes. The highlight stops at the
  ends rather than wrapping, and follows the list when filtering shortens it.
- **Ports, SSH hosts and Settings open over the window** instead of as separate
  windows with their own traffic lights. Escape or a click outside puts them
  away, and the shortcut that opened one closes it.
- **The Docker tab can be asked again.** A project whose containers were not
  running when it was opened left the tab off with no way to re-check short of
  restarting. Clicking it now probes again, with a spinner while it does, and
  opens the tab if anything turned up.
- **A stop button on every port row**, rather than only in its context menu.
  Relay's own processes stop on the click; anything else still asks first.
- **The right-hand panel resizes**, and its width is remembered.
- **Splitting is visible, not just bound to a key.** Every pane header carries
  split-right and split-down buttons, and a session can be dragged — from the
  sidebar or by its own header — onto any pane. The half it will occupy is
  previewed while the pointer moves: the four edges divide, the middle takes the
  pane over. A session dragged across a split moves rather than appearing twice.
- **The rename field says how to leave it.** Renaming a session — or a project,
  by double-clicking its name in the sidebar header — now offers a tick and a
  cross beside the field, and puts the caret there without a second click.
- **Split terminals.** `⌘D` splits right, `⇧⌘D` splits down, `⌥⌘]` moves focus
  between panes. Dividers drag, the arrangement is remembered per project, and a
  pane whose session has gone is dropped rather than left blank. Choosing a
  session from the sidebar shows it in the focused pane instead of tearing the
  split down, the same as opening a file into the active editor.
- **Where a port came from.** Each listening process reports its working
  directory, so two `node` servers on 5173 are finally distinguishable. Rows are
  named after the project the directory belongs to, and the path is searchable.

- **The app's own icon and mark.** An open ring with a dot resting in its gap:
  the ring is the app, which you can close, and the dot is the process, which
  stays. Traced once from the source SVG and shared by the icon generator and
  the interface, so they cannot drift.

- **Localisation.** English and Russian, switched in Settings and applied
  immediately without a restart. The English text is the lookup key, so a gap in
  a translation shows readable English rather than a raw identifier, and a test
  fails if the two tables drift apart.
- **Session presets are customisable.** The menu offers Terminal, Claude and
  Codex out of the box; Gemini, OpenCode and the supervised variants are one
  toggle away in Settings. A preset you create is always offered.
- **Toasts** in the bottom-right corner for things that happen rather than
  things you asked for: the daemon dropping, a session that would not start, a
  failing `docker` command. Repeats of the same condition replace each other
  instead of stacking, and anything the user has to act on stays until it is
  dismissed rather than expiring quietly.
- **A real title bar** spanning the window, with a command-palette search field
  in the middle, sidebar toggles on the left and project controls on the right.
  It also owns dragging and double-click-to-zoom, which is why those never
  worked reliably before: the behaviour was scattered across three panel
  headers that each also held buttons.
- **Notification inbox** in the title bar. Agents waiting on you, failures and
  finished work collect there with an unread badge, so a banner missed is not a
  notice lost. Clicking one jumps to its session.
- **Add Project sheet** with a drop target, and the project rail accepts a
  dropped folder directly.
- `⌘B` toggles the sessions sidebar; `⌥⌘B` toggles the project panel.
- **History** of finished runs per project: what ran, for how long, how it
  ended, and a one-click rerun.
- Working-tree diff statistics next to the branch.
- Builds are signed with a real certificate when one is available, so macOS
  stops re-asking for folder permissions after every rebuild.
- **Services** — start, stop, restart, logs, automatic port detection and Open
  URL, seeded from the project's `package.json`.
- **Ports** — a window listing every TCP port on the machine, with the ones
  Relay started attributed to their session.
- **Docker** — containers for a project, discovered through Compose labels, with
  start, stop, restart and logs.
- **SSH** — a window listing hosts from `~/.ssh/config` including `Include`
  directives, with per-project pinning.
- **Notifications** — for agents waiting on input, failures and completions,
  with global, per-project and per-type opt-out.
- **Settings window** with rebindable shortcuts and conflict detection.
- **Session presets** behind the sessions `+`, defaulting agents to their own
  automatic-approval flag.
- Sessions name themselves from the terminal title the running program reports.
- Tooltips showing both the action and its shortcut.

### Changed

- **Versions are numbered the way a continuously updated app is.** The last
  component is a build counter, not a bug count: it goes up for every published
  build and resets when the minor moves. `0.2.47` is the forty-seventh build of
  the 0.2 line. `Scripts/bump-version.sh` moves it on, so "is this enough for a
  release?" — a question about nothing — never has to be answered again.
- **`⌘R` no longer starts the dev service.** It means reload everywhere else on
  the machine, and Relay will want it for reloading something of its own. The
  command keeps its place in the menu and the palette, and can still be given a
  key by hand; restarting stays on `⌥⌘R`.
- **One mechanism for every panel and dialog,** not just one frame. The project
  settings, the add-project dialog and the two editors were SwiftUI sheets: they
  opened differently, and a click outside did nothing. They are all panels now,
  closing on Escape or on the overlay. A panel opened from inside another —
  the preset editor lives in Settings — returns to it rather than to nothing.
- **One frame for every panel and dialog.** Ports, hosts, settings, the project
  sheet and the two editors were each built by hand and had drifted: the same
  dialog was tighter at the top than at the bottom, and no two of them agreed.
  They now share a surface, with generous insets that match.
- The traffic lights sit on the centre line of Relay's own title bar rather than
  the shorter one macOS would have drawn.
- One draggable divider for the whole app. The sidebars and the splits each drew
  and handled their own, and only one of them had a hover state — or moved at
  the speed of the pointer.
- The project screen offers your own presets rather than a hardcoded trio, each
  with its agent's real mark, and shows the branch with a Git glyph.
- One icon control for the whole app. Hover, disabled and selected states were
  being reimplemented per site and drifting — the notification bell had no hover
  while the gear beside it did. Row and header buttons also grew from 16 to 24
  points, which is the difference between aiming and pressing.
- Right panel tab order: Files, Git, History, Services, Docker.
- The Docker tab is disabled, with a reason, when a project has no containers
  and no compose file.
- Project tiles in the rail use Relay's own tooltip, showing the name and the
  aggregated status.
- The connection banner is gone; its job belongs to the toast stack.
- **Left sidebar is sessions only.** Each row now carries the agent's own mark
  with its status riding on it, the session name, what it is doing, and the
  branch with a working-tree diff. The working directory is gone from the row:
  it is already in the project header.
- **New right-hand panel** with icon tabs for Services, Docker and History, plus
  disabled placeholders for Git and Files so the shape of the app is honest
  about where it is going. Toggles with `⌥⌘B`.
- **SSH moved to its own window** (`⇧⌘S`). Hosts describe the machine, not the
  repository, so they no longer take up room in a project sidebar.
- **The Project section is gone.** Its one useful fact, the branch, now sits
  under the path in the header.

### Fixed

- **A resumed conversation refused to save its transcript.** Relay handed every
  session its own environment, markers and all — so an agent started from Relay
  inherited the identity of whatever agent session had launched Relay, decided
  it was that session's child, and turned its own transcript saving off. A
  session now starts as though from a fresh login shell.
- **A new session showed another conversation's context.** Relay matched a
  session to the most recently written transcript in its directory, which for a
  freshly opened pane was whichever long conversation was busy — so an empty
  session read 93% full. It now matches the transcript that began when the
  session did, and reports nothing when there is none.
- **An agent at work could read as idle.** Whether a session is working was
  being inferred from the timing of its output, so an agent whose spinner
  redraws slowly looked like one doing nothing. Every agent says it is busy by
  offering a way to interrupt, and Relay now reads that instead — with a
  question on screen still outranking a spinner behind it.
- **The state line in a session row comes and goes no longer.** It was shown
  only when there was something to say, which changed the row's height as an
  agent worked and left "what is this doing" answerable only by a dot.
- **Closing sessions froze every other one.** Tearing a session down waited for
  its process to be reaped, on the same queue that carries terminal output — so
  closing a project with ten sessions could hold every pane for five seconds.
  The wait now happens where it cannot be felt.
- **The project's default agent now does something.** It was written down and
  read back by its own settings row and by nothing else — a control that
  pretends. It decides which start on the project screen is the prominent one.
- **Russian windows still spoke English in places.** Around forty phrases never
  reached the translation table at all — section headings like "All hosts", the
  empty states, every field label in the dialogs, the command palette's entries,
  the keyboard recorder, and every notification Relay sends. A test now reads the
  source and fails on any phrase the app looks up and the table does not have,
  which the previous check — the two tables agreeing with each other — could
  never catch.
- **"Session … is not known to the daemon" appeared out of nowhere.** Closing a
  pane while the daemon was still answering the request that created it put the
  session back: the reply arrived after the decision, reinstated it, and
  attaching then failed. A closed session now stays closed, whatever is still in
  flight about it — and an attach that finds no session quietly drops it instead
  of raising an error nobody can act on.
- **An idle agent flickered between Working and Idle.** Every byte of output
  counted as work, and a terminal interface repaints while doing nothing at all.
  Work is sustained output now; a repaint is a blip.
- **Dragging a divider oscillated instead of resizing.** The drag was measured
  against the handle, which is the thing that moves: each event moved the
  divider to the pointer, the pointer then appeared not to have moved, and the
  divider was put back. Drags are measured against the window now, and land on
  whole points.
- **A split pane's header fell apart.** Written for the full window, it wrapped
  the session name down the pane and grew tall enough to push the terminal off
  screen. It now drops what will not fit — the pid, then the status text — and
  keeps its height.
- **Clicking a terminal did not focus its pane**, because the terminal is an
  AppKit view and consumes its own mouse events, so `⌘D` always split whichever
  pane the sidebar had last selected.
- **Splitting could flatten an existing layout** when the pane it was aimed at
  had gone.
- **Splitting a pane froze the window.** Drawing a pane asked the model for its
  terminal renderer, and that call recorded the session as recently used — a
  write that invalidated the very view which had just read it, so every draw
  scheduled another. One pane happened to settle; two kept each other going at
  100% of a core. The renderers are a cache rather than state the interface
  watches, and now live outside it.
- **Typing landed in the wrong pane.** Every pane claimed the keyboard on every
  update, so two of them traded it back and forth.
- **`docker compose up` failed with "no configuration file provided"** for any
  project keeping its stack in a subdirectory. Compose now runs where the file
  actually is, and a project with no compose file is not asked about one.
- Localised labels re-resolved their `.lproj` and reopened a bundle on every
  redraw, and the startup hint kept a timer redrawing a whole terminal pane
  forever to say nothing.
- **Terminals took a minute to start, and often never did.** Two separate
  faults, both of which left a session at "Starting" with nothing on screen.
  The app's event stream was closed for good the first time the daemon
  connection was rebuilt — which happens on every launch that retires an older
  daemon — so replies kept working while every status change and every byte of
  terminal output was silently dropped. And the daemon answered `lsof`, `docker
  ps` and `docker compose up` on the same serial queue that carries PTY output,
  keystrokes and session creation, so pressing Start in the Docker tab froze
  every terminal in the app until the command returned.
- **Session rows twitched under the pointer.** The close button was being
  inserted on hover, pushing everything beside it; it now holds its place and
  only fades in, as do the other hover-revealed row controls.
- `⌘\\`, `⇧⌘S` and `⌘,` only ever opened their window. They now toggle: front
  and focused closes, anything else brings it forward.

- **A service could sit at "Starting" forever.** The reply to `createSession`
  carries the session as it was when the daemon answered, and it was overwriting
  the newer state the events had already delivered. For anything that starts and
  then goes quiet — a dev server, exactly — nothing ever arrived to correct it.
- **The window dragged from anywhere in the title bar, buttons included.** A
  SwiftUI hierarchy hit-tests as one `NSHostingView` that reports itself as
  draggable, so AppKit could not tell a button from empty chrome. Relay now
  moves the window itself, only from regions it knows are empty.
- The process id was rendered with a thousands separator: "pid 85 258".
- The window reserved a full title bar's height of empty space above Relay's
  own title bar.
- A toast reporting the daemon going away offered no way to reconnect, which
  the banner it replaced did. Toasts can now carry an action, and the app also
  retries on its own when a daemon stops on purpose — usually it is being
  replaced by a newer one.
- Ports and SSH appeared both in the title bar and in the rail; the palette and
  settings appeared in the rail as well as the title bar. Each now has one home.
- The search field had no hover state.
- History recorded plain terminals alongside agent runs. It is a record of what
  agents did, so shells no longer clutter it.
- An expanding drag region stretched the sidebar, the project panel and the
  terminal header, pushing their contents down the window.
- Only the glyph inside an icon button was clickable, not the button.
- A bare trailing closure on a section header bound to the wrong parameter, so
  the header's button was silently dropped.
- Closing a session waited on the daemon before the row disappeared.
- The build failed on Swift 6.1, which is what CI runs.
- A test asserted that the machine had unrelated listening ports, which is not
  true on a clean runner.



Interface restructuring, and the fixes that came out of using it.
- Docker containers were only found when a compose file sat in the project root.
  They are now matched by Compose's working-directory label, so a stack in
  `<project>/docker` under an unrelated project name is picked up.
- The window drag region covered the whole header, so clicking the project
  settings button zoomed the window instead.
- Settings did not open at all: a short-circuited condition returned before
  sending the action.



The rest of the v0.1 scope from the spec, plus the workflow around it.
- Sessions were spawned without a controlling terminal, so interactive CLIs
  rendered nothing.
- `Terminate` sent SIGHUP into a process that had inherited an ignored
  disposition and silently did nothing.
- Status classification depended on how the PTY happened to split output.
- Spawned processes inherited the daemon's log handle and its IPC sockets.
- A daemon left running from a previous build kept serving stale behaviour.
- Releasing a suspended dispatch source aborted the app whenever a handshake was
  rejected.
- Session numbering climbed forever, so a lone session could be called
  "Claude 4".



First working milestone: the session daemon, projects, sessions, the terminal,
status detection and the dark UI. Predates this repository, so it has no tag.
