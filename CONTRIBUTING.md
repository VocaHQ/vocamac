# Contributing

Thanks for helping with VocaMac. Keep dictation on-device after the model is downloaded. Do not add a Voca cloud speech path.

VocaMac is Beta, Apple Silicon only, macOS 14+. Intel Macs are not supported.

Coding agents should also read [AGENTS.md](AGENTS.md).

## Ways to help

- Bugs and ideas: [GitHub issues](https://github.com/VocaHQ/vocamac/issues)
- Docs: `README.md`, `docs/`, and the Hugo site in `web/`
- App or test fixes against `main`
- Review PRs for privacy, insertion, and Apple Silicon regressions

Look for `good first issue` when that label is in use.


## Development setup

You need an Apple Silicon Mac on macOS 14+, plus Xcode 15+ or Swift 5.9+.

```bash
git clone https://github.com/VocaHQ/vocamac.git
cd vocamac
make test
make build
make run
```

`make install` builds and copies the app to `/Applications`. `make help` lists the rest.


## Pull requests

Open against main. Keep the diff focused.

- Add or update tests for the behavior you change.
- Update README or docs/ when install, privacy, engines, or architecture change.
- Do not weaken on-device transcription, clipboard restore, or permissions without saying so in the PR.
- App CI runs on macos-15 with Xcode 26. Website CI runs when web/ changes.

Maintainers can comment /build on a PR for a signed, notarized DMG.

## Community

Discord (https://discord.gg/t6muquAJbm) is the fastest place to talk with maintainers. Follow @vocahq on X.

## License

Contributions are licensed under the GNU Affero General Public License v3.0 (AGPL-3.0). Opening a pull request means your contribution may be distributed under that license.
