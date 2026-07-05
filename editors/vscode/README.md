# EigenScript for VS Code

Syntax highlighting, bracket matching, comment toggling, and indentation
rules for `.eigs` files — **plus** a bundled language-server client that
auto-launches `eigenlsp` (diagnostics, symbols, hover, go-to-definition,
find-references, rename, semantic tokens).

## Requirements

The extension launches `eigenlsp` from your `PATH`. `./install.sh` installs it
to `~/.local/bin/eigenlsp` alongside the interpreter (or run `./build.sh lsp`
and put `src/eigenlsp` on your `PATH`).

## Install (from this repo)

```bash
# Symlink (or copy) into your VS Code extensions directory:
ln -s "$(pwd)/editors/vscode" ~/.vscode/extensions/inauguralsystems.eigenscript-0.14.0
# install the client dependency and reload VS Code:
cd editors/vscode && npm install
```

Or package a `.vsix` with [vsce](https://github.com/microsoft/vscode-vsce):

```bash
cd editors/vscode
npm install
npx @vscode/vsce package
code --install-extension eigenscript-0.14.0.vsix
```

Opening any `.eigs` file activates the extension (`onLanguage:eigenscript`),
which starts `eigenlsp` over stdio. No configuration needed if `eigenlsp` is on
`PATH`.

## Using the server elsewhere

`eigenlsp` speaks LSP over stdio, so any LSP client works. For a generic
LSP-bridge extension:

```jsonc
{ "command": ["eigenlsp"], "languageId": "eigenscript" }
```

## What gets highlighted

- Keywords (`define`, `is`, `of`, control flow), interrogatives
  (`what`/`who`/`when`/`prev`/...), observer predicates
  (`converged`, `stable`, ...), f-strings with `{interpolation}`,
  numbers, comments, function definitions and call sites, operators
  (including `|>` and `=>`).
