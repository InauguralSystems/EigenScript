# Changelog fragments

A PR that changes `src/` or `lib/` adds one file here and never edits `CHANGELOG.md` (#1268).

    changes/<category>/<issue>-<slug>.md

- `<issue>` is the issue or PR number, `<slug>` is lowercase words joined by `-`, so two PRs do not pick the same name.
- The file holds the entry exactly as it will appear in `CHANGELOG.md`: it starts with `- `, may continue over
  indented lines and further paragraphs, and ends in a newline.
- The category is the directory:

  | directory | `###` heading |
  | --- | --- |
  | `breaking` | Breaking changes |
  | `added` | Added |
  | `changed` | Changed |
  | `deprecated` | Deprecated |
  | `removed` | Removed |
  | `fixed` | Fixed |
  | `security` | Security |
  | `documentation` | Documentation |
  | `internal` | (none: the change needs no entry) |

- A `src/` or `lib/` change with nothing to say to users adds `changes/internal/<issue>-<slug>.md` holding
  `- <why no entry>`. It lives in the tree, so it works the same on `pull_request` and `merge_group`, and the cut
  deletes it without assembling it.

The gate is `tools/changelog_fragments.sh check`, a row in `tools/precheck.sh` (`make precheck`).

## Release cut

    bash tools/changelog_fragments.sh cut <version> <YYYY-MM-DD>

It adds a `## [<version>] - <date>` section below `## [Unreleased]`, moves everything that was under `[Unreleased]`
into it unchanged, appends each category's fragments under its `###` heading, bumps `VERSION` and deletes the
fragments. Within a heading the order is the issue number (numeric), then the slug, so the same fragments always give
the same file. The gate recognises a cut by reproducing it: `CHANGELOG.md` and `VERSION` changed, and the assembler
run on the base tree gives exactly the new `CHANGELOG.md`.
