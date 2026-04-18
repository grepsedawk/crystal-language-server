# crystal-language-server

A Language Server Protocol implementation for the
[Crystal](https://crystal-lang.org) programming language. Speaks
JSON-RPC over stdio. Built for day-to-day editing: scanner-based
structure handled in-process for responsiveness, semantic answers
delegated to the Crystal compiler so the type info stays honest.

## Status

Every LSP method advertised below is implemented. Trade-offs
between scanner-based and compiler-based answers are documented
per row.

### Supported LSP methods

| Capability                           | Implementation                                                              |
| ------------------------------------ | --------------------------------------------------------------------------- |
| `initialize` / `shutdown` / `exit`   | — |
| `textDocument/didOpen/Change/Close/Save` | incremental sync, in-memory doc store                                   |
| `textDocument/publishDiagnostics`    | `crystal build --no-codegen -f json`, debounced, on-save by default         |
| `textDocument/diagnostic` (pull)     | LSP 3.17 pull model; shares a cache with `publishDiagnostics`               |
| `textDocument/hover`                 | scanner + workspace index first, falls back to `crystal tool context`       |
| `textDocument/definition`            | scanner-first (local bindings, unambiguous workspace hits), compiler next   |
| `textDocument/declaration`           | alias of `textDocument/definition`                                          |
| `textDocument/implementation`        | scanner-walks the workspace for concrete overrides (methods) or subclasses (types), compiler `tool implementations` first |
| `textDocument/typeDefinition`        | `crystal tool context` → workspace-index lookup of the resolved type        |
| `textDocument/references`            | scanner-based workspace walk with `@ivar` / `@@cvar` / `$global` awareness  |
| `textDocument/rename` + `prepareRename` | scanner-based rewrite, token-range prepare                              |
| `textDocument/formatting`            | `crystal tool format`                                                       |
| `textDocument/rangeFormatting`       | full-document format, edits diffed to the requested range                   |
| `textDocument/onTypeFormatting`      | indent-aware newline handling                                               |
| `textDocument/documentSymbol`        | scanner-based hierarchical outline                                          |
| `textDocument/documentHighlight`     | scanner identifier matches                                                  |
| `textDocument/documentLink`          | `require "…"` lines, resolved against shard root and relative paths         |
| `textDocument/completion` + `completionItem/resolve` | keywords + pseudo-methods + scanner symbols; type-aware after `.`; snippet `insertText` for methods with required args; auto-require `additionalTextEdits` for cross-file classes; `allCommitCharacters` so `.`/`(`/`[`/`,` commit; LSP 3.17 `labelDetails` shows `(args) : ReturnType` in the popup |
| `textDocument/signatureHelp`         | nearest matching `def`, workspace fallback                                  |
| `textDocument/inlayHint`             | inferred local-variable types (compiler)                                    |
| `textDocument/semanticTokens/full` + `/range` + `/full/delta` | scanner-based highlighting; delta responses diff the last payload for large files; `declaration` / `readonly` / `defaultLibrary` modifier bits emitted on name-tokens, constants, and curated stdlib types |
| `textDocument/publishDiagnostics` tags | `Unnecessary` (dimmed) for unused-variable warnings, `Deprecated` (strikethrough) for `@[Deprecated]` calls |
| `textDocument/foldingRange`          | block-structured folds                                                      |
| `textDocument/selectionRange`        | scanner tree nesting plus word / line / document layers                     |
| `textDocument/codeAction`            | quick-fix auto-require for `undefined constant` / `undefined method`; `source.fixAll` bundles all auto-requires; `source.organizeImports` sorts + dedupes the leading require block (stdlib → shards → relative) |
| `textDocument/codeLens` + `codeLens/resolve` | "N references" over every top-level def/class; `▶ Run` over every `it` / `describe` / `context` in `*_spec.cr`, wired to the `crystal.runSpec` command |
| `textDocument/willSaveWaitUntil`     | opt-in via `CRYSTAL_LANGUAGE_SERVER_WILL_SAVE_ACTIONS=organize_imports`: runs `organizeImports` edits as the editor blocks for save |
| `textDocument/prepareCallHierarchy` + `incomingCalls` + `outgoingCalls` | scanner-driven caller/callee graph       |
| `textDocument/prepareTypeHierarchy` + `supertypes` + `subtypes` | scanner-driven inheritance tree               |
| `workspace/symbol`                   | scanner over open docs + `.cr` files under the workspace root               |
| `workspace/didChangeConfiguration`   | accepted (no-op today)                                                      |
| `workspace/didChangeWatchedFiles`    | invalidates per-file index and compiler result cache; server registers a `**/*.cr` watcher on `initialized` via `client/registerCapability` so clients that don't auto-watch still fire the notification |
| `workspace/didCreateFiles` / `didRenameFiles` / `didDeleteFiles` | explorer-driven file ops — reindex the name index for the affected paths |
| `workspace/executeCommand`           | registers `crystal.runSpec`, `crystal.runFile`, `crystal.formatFile`; each detaches the subprocess on a fiber so the LSP dispatch returns immediately |
| `window/logMessage`                  | server-originated: `LogForwarder` backend mirrors `Log.warn`/`Log.error` to the editor's output panel once the client connects |
| `window/showDocument`                | server-originated: `Server#send_show_document` lets handlers ask the editor to focus or open a URI |
| `workspace/configuration` (reverse)  | server-originated: `Server#request_configuration` asks for client settings (fire-and-forget in v1) |
| `$/progress` + `window/workDoneProgress/create` | the workspace-index warm pass shows an "Indexing Crystal workspace" progress bar when the client advertises `window.workDoneProgress` |
| `$/cancelRequest`                    | in-flight requests reply -32800 and SIGKILL any spawned compiler subprocess |

## Comparison

This project isn't a drop-in replacement for the LSPs you may have
used in other languages. Here's the honest shape of what it gets
right and where it compromises.

### vs. [crystalline](https://github.com/elbywan/crystalline)

Crystalline is the mature Crystal LSP. It embeds the compiler in
process and keeps a persistent `Crystal::Program` alive across
requests.

| Dimension              | crystal-language-server                       | crystalline                                     |
| ---------------------- | --------------------------------------------- | ----------------------------------------------- |
| Memory footprint       | 10–40 MB resident (no retained Program)       | hundreds of MB on real projects                 |
| Cold-start latency     | milliseconds (binary ~1 MB in subprocess mode) | seconds (loads compiler + Program)             |
| Per-request latency    | ~µs for goto/refs/hover/outline off the warm name index; compiler fallback capped at 10s | fast, in-process compiler |
| Type inference depth   | compiler-accurate only for hover/inlay/type-definition (via subprocess `crystal tool`); other features are scanner-heuristic | full — every feature backed by the compiler |
| Scope of goto/refs     | scanner-based workspace walk + compiler fallback; some false positives on overloads | compiler-accurate             |
| Completion after `.`   | receiver type from compiler, methods from scanner-index | compiler-accurate including inherited methods |
| Works when code doesn't compile | yes — all scanner-based features still work | partially — many features degrade          |
| Compiler version drift | subprocess mode follows `crystal` on PATH; embedded mode pinned at build time | pinned at build time              |

Pick crystalline when you want rust-analyzer-style fidelity and
don't mind the RAM cost. Pick this one when you want a light editor
companion, often-good-enough answers, and responsiveness even on
broken code.

### vs. popular LSPs in other languages

| Feature                      | this project                   | crystalline           | rust-analyzer / gopls / clangd |
| ---------------------------- | ------------------------------ | --------------------- | ------------------------------ |
| Incremental type-check       | no — subprocess recompiles     | no — full recompile   | yes — incremental              |
| Receiver-type narrowing on refs / rename | no              | partial               | yes                            |
| Cross-file macro expansion   | compiler only                  | yes                   | yes (per language)             |
| Semantic tokens              | scanner (types, constants, stdlib marked `defaultLibrary`; delta-diff responses) | compiler-backed | compiler-backed |
| Call hierarchy               | scanner heuristic (text match + enclosing def) | limited    | compiler-accurate              |
| Type hierarchy               | scanner heuristic (parses `class X < Y`) | limited     | compiler-accurate              |
| Code actions                 | quickfix (auto-require), `source.fixAll`, `source.organizeImports` | few | extensive incl. refactors (extract/inline/rewrite) |
| Inlay hints                  | compiler (locals only)         | compiler              | compiler-backed                |
| Diagnostic tags              | `Unnecessary` + `Deprecated` bits set from compiler warning text | no | yes                            |
| Work-done progress           | `$/progress` on workspace-index warm | no               | yes                            |
| Test CodeLens (▶ Run)        | scanner-detected `it`/`describe`/`context` above each spec example, dispatches `crystal.runSpec` | no | yes (Rust/Go equivalents)      |
| willSaveWaitUntil            | opt-in, runs `organizeImports` on save (env-gated)  | no               | yes                            |
| Client log forwarding        | `window/logMessage` backend mirrors `Log.warn/error` to the editor output panel | no | yes |
| Refactor code actions (extract method / inline / rewrite) | no | no                   | yes                            |

### Known limitations

- **References / rename are text-matched.** Identifiers with the same
  name on different receivers collapse into one set. The scanner
  tags `@ivar` / `@@cvar` / `$global` separately, but plain method
  names aren't disambiguated by receiver type.
- **Call hierarchy and type hierarchy are heuristics.** They work
  off scanner matches and the `class X < Y` pattern in each class's
  opener line. They do not follow `include` / `extend`, and they
  do not resolve macro-generated defs.
- **Subprocess mode pays fork+parse cost per compiler call.** The
  result cache, scanner-first fallbacks, and 10 s timeout keep most
  requests off the compiler, but a cold hover on a new file will
  wait up to a compile round-trip.
- **Workspace index is scanner-based.** A persistent
  `name → DefSite[]` index is warmed in a background fiber on
  startup and updated incrementally from the text-sync notifications,
  so `find_defs` is a hash probe rather than a file walk. It carries
  no type information — overloads and receiver narrowing still need
  the compiler.
- **Diagnostics default to on-save.** Change the default via
  `CRYSTAL_LANGUAGE_SERVER_DIAGNOSTICS=on_change` if you want per-
  keystroke-pause compiles.

## Architecture

```
stdin/stdout  ──>  Transport (Content-Length framing)
                     │
                     ▼
                  Server (fiber-per-request dispatch, $/cancelRequest)
                     │
       ┌─────────────┼──────────────┐
       ▼             ▼              ▼
   DocumentStore   Scanner       Compiler::Provider
   (open buffers,  (local parse) (subprocess or embedded,
    memoized                       cancellable, result + diagnostic
    tokens/symbols                 caches)
    per version)
                     │              │
                     └── Handlers ──┘
                        (one module per LSP method)
                     │
                     ▼
              WorkspaceIndex
    (warm name→DefSite[] index, mtime-keyed scanner cache,
     symlink-loop-safe directory walk)
```

Design choices:

- **Scanner first, compiler second.** Goto, hover, references, rename,
  outline, highlight, completion, folding, signature help, selection
  range, call hierarchy, and type hierarchy all read from a small
  hand-written tokenizer against the in-memory buffer, with a
  cross-file workspace index for cold lookups. The compiler is
  consulted only for the typed answers no tokenizer can give you:
  inferred variable types, implementations across generic
  instantiations, build diagnostics.
- **Handler-per-file.** Every LSP method has its own module under
  `src/crystal_language_server/handlers/`. Adding a method is a single
  new file plus one line in `Server#dispatch_*` and one line in
  `Handlers::Lifecycle.capabilities`.
- **Concurrent dispatch.** Each request runs in its own fiber; a slow
  hover on one file doesn't stall completion on another. Transport
  writes are mutex-guarded so replies can't interleave.
- **Bounded caches.** Compile results, build diagnostics, scanner
  trees, receiver types, and the workspace's `.cr` file list are all
  cached with bounded entries or short TTLs. Open documents memoize
  their tokens + symbols per version; closed documents drop their
  per-URI caches. `$/cancelRequest` propagates into spawned compiler
  subprocesses so stale hovers don't hold up later ones.
- **Symlink-loop safe.** Workspace walking canonicalizes each
  directory via `realpath` and skips already-seen paths, so
  `lib/foo/lib/foo/lib/foo/…` dep trees don't infinite-loop.

## Compiler modes

The server can reach the Crystal compiler two ways. Pick via
`CRYSTAL_LANGUAGE_SERVER_MODE` (defaults to `subprocess`):

| Mode         | How                                         | Pros                                                    | Cons                                                             |
| ------------ | ------------------------------------------- | ------------------------------------------------------- | ---------------------------------------------------------------- |
| `subprocess` | shells out to `crystal tool …` per request  | works with whatever `crystal` is on `PATH`; stable across versions; small binary | slower per-call; capped by a 10 s timeout to keep the editor responsive |
| `embedded`   | Crystal compiler linked in-process (opt-in) | no fork/exec; one compile serves multiple tools; larger memory-residency | locked to the exact compiler version the LSP was built against; ~37 MB binary |

```sh
# default
CRYSTAL_LANGUAGE_SERVER_MODE=subprocess crystal-language-server

# opt-in, requires a build that linked the compiler in
CRYSTAL_LANGUAGE_SERVER_MODE=embedded crystal-language-server
```

Use `subprocess` unless you want `embedded` and are willing to rebuild
the LSP when you bump your project's Crystal version.

## Install

You need Crystal / `shards` on `PATH` (the LSP is itself a Crystal
program that shells out to `crystal` at runtime in the default mode).

### As a Neovim plugin (easiest)

The repo doubles as a Neovim plugin. Ship one line to a plugin
manager, and the build hook produces the binary inside the plugin
directory — the bundled Lua then points nvim's native LSP at it
automatically. No global install needed.

**lazy.nvim**

```lua
{
  "grepsedawk/crystal-language-server",
  build = "shards build --release --no-debug",
  ft    = "crystal",
}
```

**packer.nvim**

```lua
use {
  "grepsedawk/crystal-language-server",
  run = "shards build --release --no-debug",
  ft  = "crystal",
}
```

**pckr.nvim**

```lua
{
  "grepsedawk/crystal-language-server",
  run = "shards build --release --no-debug",
}
```

Rebuild at any time with `:CrystalLspBuild`.

Customise (all fields optional):

```lua
require("crystal_language_server").setup({
  cmd          = { "/custom/path/to/crystal-language-server" },
  filetypes    = { "crystal" },
  root_markers = { "shard.yml", ".git" },
  log_level    = "debug",
  log_path     = vim.fn.stdpath("state") .. "/crystal-lsp.log",
  settings     = {},
})
```

Set `vim.g.crystal_language_server_no_autosetup = 1` before the
plugin loads to skip the automatic setup and call `setup()` yourself.

### Manual install (any editor)

```sh
git clone https://github.com/grepsedawk/crystal-language-server
cd crystal-language-server
shards build --release --no-debug
cp bin/crystal-language-server ~/.local/bin/   # or any dir in PATH
```

### VS Code

Add a thin extension that points at the binary; the generic LSP
client recipe from the VS Code docs works unchanged.

## Claude Code

Claude Code has native LSP support, so this repo doubles as a
Claude Code plugin. The repo root ships a one-plugin marketplace in
`.claude-plugin/marketplace.json` pointing at `./plugin/`. Install:

```
/plugin marketplace add grepsedawk/crystal-language-server
/plugin install crystal-lsp
```

After install, Claude Code spawns `crystal-language-server` on `.cr`
files automatically — you still need the binary on `$PATH`. The
`plugin/README.md` inside the repo walks through `shards build
--release`. Once installed, Claude gets hover, goto-definition,
diagnostics, completion, and everything else on the supported-methods
list alongside your editor session.

You can also run it directly in your editor (nvim / VS Code /
JetBrains) without the plugin and just let Claude Code edit files
alongside — the two workflows coexist.

## Environment

| Variable                                     | Effect                                                         |
| -------------------------------------------- | -------------------------------------------------------------- |
| `CRYSTAL_LANGUAGE_SERVER_LOG`                | write log to this file instead of stderr                       |
| `CRYSTAL_LANGUAGE_SERVER_LOG_LEVEL`          | `trace`/`debug`/`info`/`warn`/`error`                          |
| `CRYSTAL_LANGUAGE_SERVER_CRYSTAL`            | alternate `crystal` binary path                                |
| `CRYSTAL_LANGUAGE_SERVER_MODE`               | `subprocess` (default) or `embedded`                           |
| `CRYSTAL_LANGUAGE_SERVER_DIAGNOSTICS`        | `on_save` (default), `on_change`, or `never`                   |
| `CRYSTAL_LANGUAGE_SERVER_DIAGNOSTICS_DEBOUNCE` | debounce before running build diagnostics (seconds, default 0.4) |
| `CRYSTAL_SOURCE_PATH`                        | build-time: path to Crystal compiler source for embedded mode  |

## Tests

```sh
crystal spec
```

Unit specs cover the transport, document/position math, scanner,
workspace index, and compiler adapters. Integration specs spawn the
real `crystal` CLI.

## License

MIT.

## Development

```sh
git clone https://github.com/grepsedawk/crystal-language-server
cd crystal-language-server
shards install
shards build
crystal spec
```

CI runs the matrix defined in `.github/workflows/ci.yml` against
Crystal 1.17.0, 1.18.1, and 1.19.1 on Ubuntu. Target any of those
locally when reproducing CI failures; 1.19.1 is the version used for
the `crystal tool format --check` gate.

Running against both modes locally:

```sh
# subprocess mode (the default)
CRYSTAL_LANGUAGE_SERVER_MODE=subprocess ./bin/crystal-language-server

# embedded mode (requires a build with the compiler linked in)
CRYSTAL_SOURCE_PATH=/path/to/crystal shards build --release --no-debug
CRYSTAL_LANGUAGE_SERVER_MODE=embedded ./bin/crystal-language-server
```

Formatting is enforced by the CI `format-check` job. Run it locally
before pushing:

```sh
crystal tool format src spec            # fix in place
crystal tool format --check src spec    # just verify
```
