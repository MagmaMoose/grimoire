# Release process

Releases are automated. You normally do not tag or build by hand.

> macOS only at runtime. The published binary is `transcribe-macos-arm64` (Apple Silicon).

## Automated flow

On every push to `main` that changes more than docs (`**/*.md`, `docs/**`, `mkdocs.yml`,
`LICENSE` and `.gitignore` are ignored):

1. **Diatreme** (`.github/workflows/release.yml`) computes the next version from git history,
   tags it and publishes the GitHub release. Caldrith provisions this file from
   `MagmaMoose/admin`, so edits made here are overwritten on the next sync.
2. **Publish binaries** (`.github/workflows/publish.yml`) runs on `release: published`:
   - **build**: PyInstaller builds `transcribe.spec` from the release tag on `macos-15` (the
     published asset) and `macos-14` (a compatibility build that is not published), and runs
     `--help` on each.
   - **upload**: attaches `transcribe-macos-arm64` and `SHA256SUMS` to the release.
   - **bump-homebrew**: opens `bump-transcribe-<version>` on
     [MagmaMoose/homebrew-tap](https://github.com/MagmaMoose/homebrew-tap) with the new url and
     sha256, closing any older open transcribe bump first. The tap auto-merges it once its CI
     (`brew audit`, `brew style`, `brew install` + `brew test`) passes.

Prereleases are never built or bumped.

To rebuild and re-publish an existing release, run the workflow by hand (Actions →
**Publish binaries** → Run workflow) with the release tag.

The bump needs the `HOMEBREW_TAP_TOKEN` org secret: a fine-grained PAT on
`MagmaMoose/homebrew-tap` with Contents and Pull requests: write. If it expires, the bump job
fails at **Check the tap token**.

## Checklist before merging to main

- [ ] Update `CHANGELOG.md` for the upcoming version.
- [ ] Tests pass: `uv run pytest` (or `pytest`).
- [ ] Lint clean: `uv run ruff check .` (line length 100).
- [ ] Commit messages follow Conventional Commits.

## Local development install

```bash
# With uv (preferred)
uv sync
uv run transcribe --help

# Or with pip (editable, including the Google Drive extra)
pip install -e ".[gdrive]"
transcribe --help
```

System dependencies for local runs:

```bash
brew install whisper.cpp ffmpeg
```

## Building a binary locally

The release workflow uses PyInstaller with `transcribe.spec`. To reproduce locally:

```bash
pip install pyinstaller
pip install -r requirements.txt
pyinstaller --clean transcribe.spec
./dist/transcribe --version
```

## Repos involved

- Source: <https://github.com/CalebSargeant/transcribe>
- Homebrew tap: `MagmaMoose/homebrew-tap` (`brew tap magmamoose/tap`), which consumes the
  released binary
