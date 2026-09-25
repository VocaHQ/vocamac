## Summary

<!-- What does this change and why? Link the issue it closes, e.g. "Closes #123". -->

## Testing

<!-- What did you run, and on which Mac and macOS version? Say what you could not test.
     Check the items for the areas this PR touches and delete the rest. -->

**App** (`Sources/`, `Tests/`, `Package.swift`, `scripts/`)
- [ ] `make test` passes
- [ ] New logic has tests in `Tests/VocaMacTests/`
- [ ] Tried the change in a built app (`make build` / `make install`) when it affects runtime behavior

**Website** (`web/`)
- [ ] In `web/`: `npm run check`, `npx html-validate 'public/**/*.html'`, and `npx stylelint static/style.css` pass (the same checks as CI; see `web/AGENTS.md`)
- [ ] New page behavior or product facts are covered in `web/tests/`

## Checklist

- [ ] The PR title follows [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `ui:`, `docs:`, `chore:`, `ci:`)
- [ ] UI changes include before/after screenshots
- [ ] No credentials, recordings, transcripts, or personal data in code, logs, or screenshots
- [ ] Docs updated if behavior or setup changed (`README.md`, `docs/`, `web/`)
