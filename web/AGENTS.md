# Website — agent notes

Scope: `web/` only. Root `AGENTS.md` still applies (worktrees, conventional commits, no merge, never commit to `main`).

## Stack

| Piece | Role |
|-------|------|
| Hugo **0.165.0 extended** | Site generator (pin matches CI) |
| `content/` | Markdown pages (`_index.md`, `features/`, `screenshots.md`) |
| `layouts/` | Templates and partials |
| `static/` | Hand-written `style.css` / `script.js`, brand assets, CNAME |
| `data/product.toml` | Version, requirements, language list, model table |

**No** React/Vue/Svelte, **no** Tailwind/Bootstrap, **no** bundler, **no** runtime npm packages. CSS and JS stay hand-written in `static/`.

`package.json` is **check-only**: `npm run check` = `hugo --minify` + `node --test tests/site.test.mjs`. Do not add production JS dependencies.

## Commands

```bash
cd web
hugo server          # live preview (install Hugo 0.165.0 extended)
npm run check        # build + tests — this is what CI runs
```

CI also runs `npx html-validate 'public/**/*.html'` and `npx stylelint static/style.css` (`.github/workflows/ci.yml`, `deploy-website.yml`).

Deploy: push to `main` under `web/**`, publish a GitHub Release, or `workflow_dispatch`. Output is `web/public` → GitHub Pages (`vocamac.com` via `static/CNAME`).

## Rules

- Treat **`data/product.toml` as source of truth** for version, DMG size, OS floor, and selectable languages. Re-verify it before shipping site copy. Do **not** claim “99+ languages” — only the Settings picker list belongs on the site.
- Keep `hugo.toml` minify **`keepQuotes = true`** so crawlers still see `name="description"` / `name="twitter:*"`.
- Do not remove `static/CNAME`.
- After HTML/CSS/image edits, hard-refresh (`Cmd+Shift+R`); browsers cache SVG/PNG aggressively.
- Feature pages live in `content/features/`. New marketing claims need a matching feature page or an explicit decision not to.
