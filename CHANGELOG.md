# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Opt-in embedded compiler mode: the Crystal compiler can be linked
  in-process instead of shelled out to, eliminating fork/exec overhead
  on hover, goto, format, and diagnostics.
- `CRYSTAL_LANGUAGE_SERVER_MODE` environment variable (`subprocess` |
  `embedded`) to select which backend to use at runtime. Defaults to
  `subprocess`.
- GitHub Actions CI matrix covering Crystal 1.17.0, 1.18.1, and 1.19.1
  on Ubuntu, plus a `crystal tool format --check` gate.
- Issue template for bug reports.

## [0.1.0]

Initial release. Subprocess-backed LSP covering diagnostics, hover,
goto-definition, formatting, document symbols, completion, semantic
tokens, folding ranges, and workspace symbols. See `README.md` for the
supported-methods table.

[Unreleased]: https://github.com/grepsedawk/crystal-language-server/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/grepsedawk/crystal-language-server/releases/tag/v0.1.0
