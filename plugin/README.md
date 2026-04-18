# crystal-lsp

Crystal language server for Claude Code, providing code intelligence features
like go-to-definition, hover, references, semantic tokens, inlay hints, call
hierarchy, completion with auto-require, and more.

## Supported Extensions

`.cr`

## Installation

Build and install the language server binary from source. A Crystal toolchain
is required (`crystal --version` must work).

```bash
git clone https://github.com/grepsedawk/crystal-language-server
cd crystal-language-server
shards build --release
# then put bin/crystal-language-server on your $PATH — e.g.:
ln -s "$PWD/bin/crystal-language-server" /usr/local/bin/
```

Verify it's on your PATH:

```bash
crystal-language-server --version
```

Once the binary is available, Claude Code will spawn it automatically for
`.cr` files after you install the plugin.

## More Information

- [crystal-language-server on GitHub](https://github.com/grepsedawk/crystal-language-server)
- [Crystal language](https://crystal-lang.org)
