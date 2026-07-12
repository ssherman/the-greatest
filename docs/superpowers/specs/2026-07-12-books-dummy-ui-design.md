# Books Dummy UI + Domain Wiring — Design

**Status:** Design approved by owner 2026-07-12. Spec pending owner review.
**Goal:** Make the books domain resolve end-to-end — `dev-new.thegreatestbooks.org` locally, `new.thegreatestbooks.org` in production — serving a placeholder page in the books look (DaisyUI `cmyk` theme, Playfair Display headings, Lora body).
**Why now:** The books **admin** UI is the next real work, and admin routes live *inside* each domain's routing constraint. Nothing books-side can be built in the UI until the domain resolves. The public books UI (rankings, lists, books) is explicitly deferred.

## Scope

**In:** books domain config, route + `Books::DefaultController` + placeholder view, books layout, books CSS build, Caddy dev host, production cert + nginx + `BOOKS_DOMAIN` + Cloudflare DNS, controller/routing/E2E tests.

**Out (deferred):** any ranked or real books content; books admin (next project); wiring books into user lists / My Lists; the `images-dev.thegreatestbooks.org` CDN host (books zone has `images.` but no `images-dev.` CNAME — irrelevant until books renders images).

## Current state (verified 2026-07-12)

- `config.domains[:books]` and `config.domain_settings[:books]` already exist. `ApplicationController#detect_current_domain` already falls back to `:books` for any unmatched host.
- Rollup already builds `app/assets/builds/books.js`. No layout uses it — music, movies, and games layouts all include the shared `application` bundle. Leave it alone.
- There is **no** books layout, no books CSS, no books route, no books controller.
- Dev hostnames do **not** use Cloudflare DNS. `dev.thegreatestmusic.org`, `dev.thegreatestmovies.org`, and `dev.thegreatest.games` resolve from the **Windows hosts file** (`C:\Windows\System32\drivers\etc\hosts`), all pointing at the WSL IP `172.18.93.203`. The Cloudflare zones contain no `dev.*` records; the `CLOUDFLARE_API_TOKEN` is used by Caddy only for the DNS-01 TLS challenge. That hosts file already carries a stale `192.168.139.157 dev.thegreatestbooks.org` line belonging to the **legacy** books app — which is precisely why the new dev host is `dev-new.`, not `dev.`.
- Production domains come from `secrets/.env.production` (SOPS + age; key present at `~/.config/sops/age/production.txt`), which sets `MUSIC_DOMAIN` / `MOVIES_DOMAIN` / `GAMES_DOMAIN` and no `BOOKS_DOMAIN`.
- Production TLS: nginx terminates with Let's Encrypt certs issued by `deployment/scripts/generate-certs.sh` (certbot + DNS-01). Cloudflare proxies all three apexes to `45.33.28.21`.
- `wrangler` manages Workers, **not** DNS. No new CLI is needed: the existing `CLOUDFLARE_API_TOKEN` + `BOOKS_CLOUDFLARE_ZONE_ID` in `web-app/.env` already work against the Cloudflare REST API (verified read-only against both the music and books zones).
- There is no test CI. `.github/workflows/` holds only the Docker image build and the deploy. CLAUDE.md's claim that CI enforces brakeman/standardrb/tests is stale, and the owner does not use brakeman. Verification is local.

## Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Dev host is `dev-new.thegreatestbooks.org`; prod host is `new.thegreatestbooks.org` | The apex `thegreatestbooks.org` is the live legacy site, and `dev.thegreatestbooks.org` is already taken by the legacy app's local dev setup. |
| D2 | Ship the full production path in this change (cert, nginx, env, DNS), not dev only | Owner's call. The placeholder page is harmless to expose, and it proves the prod path before the admin UI depends on it. |
| D3 | Layout carries navbar + login modal, but **no** user-list plumbing | Books user-list data is migrated but the surfaces are not safe: `MyListsController#csv_row` calls `listable.release_year`, which `Books::Book` does not have (it has `first_published_year`). Including `user-list-state` would light up `/user_list_state` for `Current.domain == :books`. |
| D4 | Lora (body) + Playfair Display (headings) via a Google Fonts `<link>` with preconnect | Matches CityWizard's proven pairing (`src/layouts/BaseLayout.astro`, `src/styles/global.css`). Self-hosting is a later optimization, not a blocker for a placeholder. |
| D5 | Leave the root font-size at the browser default (do **not** copy CityWizard's `html { font-size: 18px }`) | DaisyUI's component sizing assumes 16px; rescaling everything is a design decision to make against real UI, not a placeholder. |
| D6 | Issue the production cert **before** shipping the nginx config | An nginx `ssl_certificate` pointing at a nonexistent path crashes the container — which serves music, movies, **and** games. This ordering is the single highest-risk part of the change. |
| D7 | Create the Cloudflare A record **last** | Between DNS and a working origin server block, the proxied hostname would return 526 (origin cert mismatch — it would fall through to the first 443 block, which presents the music cert). |
| D8 | Restructure `generate-certs.sh` `DOMAINS` into `cert-name:san,san` entries | The loop hardcodes `-d $domain -d www.$domain`; `www.new.thegreatestbooks.org` is nonsense. One loop with explicit SANs beats a second parallel no-www array to keep in sync. |

## Implementation

### 1. Rails domain wiring

**`web-app/config/initializers/domain_config.rb`**
- `books:` default → `ENV.fetch("BOOKS_DOMAIN", "dev-new.thegreatestbooks.org")` (was `"localhost:3000"`, which could never match `request.host` — the host carries no port).
- `domain_settings[:books][:layout]` → `"books/application"` (was `"application"`, the legacy root layout no other domain uses).

**`web-app/config/routes.rb`** — a books constraint block alongside the existing music/movies/games root blocks:

```ruby
constraints DomainConstraint.new(Rails.application.config.domains[:books]) do
  root to: "books/default#index", as: :books_root
end
```

This block is also where the books admin namespace will go next.

**`Books::DefaultController`** (via `bin/rails generate controller books/default index`; delete any generated helper/route cruft): `layout "books/application"`, empty `index`. Mirrors `Movies::DefaultController`.

**`app/views/books/default/index.html.erb`** — a placeholder hero stating the new books site is under construction. No data access.

**`app/views/layouts/books/application.html.erb`** — modeled on `layouts/games/application.html.erb`:
- `<html data-theme="cmyk">`
- Google Fonts preconnect + `<link>` for `Lora:ital,wght@0,400;0,500;0,600;0,700;1,400` and `Playfair+Display:wght@400;700` with `display=swap`
- `stylesheet_link_tag "books"`, `javascript_include_tag "application"`
- navbar: 📚 logo linking to `/`, placeholder nav links, login button (`login_modal.showModal()`, `id="navbar_login_button"`) + `Authentication::WidgetComponent` modal
- footer
- **Not** included: `data-controller="user-list-state"`, the `navbar_my_lists` link, `Toast::RegionComponent`, `UserLists::ModalComponent`, `shared/_user_list_icon_template` (per D3)

**`app/controllers/my_lists_controller.rb`** — update the stale comment on `resolve_layout` ("books has no layout yet"). Behavior is unchanged: books still falls back to the music layout, because books My Lists remains broken until the public-UI work.

### 2. Assets

**`web-app/app/assets/stylesheets/books/application.css`** (new) — same `@import "tailwindcss"` + `@source` block as `games/application.css`, then:

```css
@plugin "daisyui" {
  themes: cmyk --default;
}

html {
  font-family: 'Lora', Georgia, 'Times New Roman', serif;
}

h1, h2, h3, h4, h5, h6 {
  font-family: 'Playfair Display', Georgia, serif;
}
```

**`web-app/package.json`** — add `build:css:books` (Tailwind CLI, `-o ./app/assets/builds/books.css --minify`) and add it to the aggregate `build:css`. The aggregate is what cssbundling-rails runs from `assets:precompile` in the Dockerfile, so this is what makes `books.css` exist in production.

**`web-app/Procfile.dev`** — add the books CSS watcher to the `css:` line.

### 3. Local dev

**`Caddyfile`** — add:

```
dev-new.thegreatestbooks.org {
	import common
}
```

Caddy obtains a real cert via DNS-01 using `CLOUDFLARE_API_TOKEN`. Confirm the token can write TXT records in the books zone (it can already read it); if it is zone-scoped to the other three, mint a token with `Zone:DNS:Edit` covering `thegreatestbooks.org` and update `.env`.

**Windows hosts file** — **owner action, cannot be automated** (not writable from WSL; needs an Administrator editor). Add, using the same IP the other dev entries use:

```
172.18.93.203 dev-new.thegreatestbooks.org
```

Leave the stale `192.168.139.157 dev.thegreatestbooks.org` line alone — it belongs to the legacy app.

### 4. Production runbook (strict order)

1. **Cert.** Restructure `deployment/scripts/generate-certs.sh` per D8 and add `new.thegreatestbooks.org` with no SANs. Run it on the server. DNS-01 means no A record is required for issuance. `renew-certs.sh` needs no change — bare `certbot renew` picks up the new lineage automatically.
2. **nginx.** In `deployment/nginx/the-greatest.conf.template`, add `new.thegreatestbooks.org` to the port-80 `server_name` list and add a `443` block mirroring the music one: its own cert paths (`${CERT_PATH}/new.thegreatestbooks.org/`), the `/__/auth` Firebase proxy location, `proxy_pass http://rails_app`. Deploy and confirm nginx reloads clean.
3. **Rails env.** `SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt sops secrets/.env.production` → add `BOOKS_DOMAIN=new.thegreatestbooks.org`. Commit the re-encrypted file; deploy.
4. **Cloudflare zone audit.** Before touching DNS, list the books zone's page rules and cache rules. This zone fronts the **live legacy site**, so a "Cache Everything" rule matching `*thegreatestbooks.org/*` would blanket-cache `new.` too. Report findings; add a bypass rule for `new.thegreatestbooks.org` if one exists.
5. **DNS.** Create A `new` → `45.33.28.21`, proxied — matching the other apexes — via the Cloudflare REST API with the existing token and `BOOKS_CLOUDFLARE_ZONE_ID`.
6. **Verify.** `curl -sI https://new.thegreatestbooks.org/` → 200, and the page renders the books placeholder.

**Rollback:** delete the DNS record. The hostname stops resolving; the nginx block and cert sit idle and harm nothing.

## Tests

- `test/controllers/books/default_controller_test.rb` — `host! Rails.application.config.domains[:books]`, `get books_root_path`, assert `:success`. Behavior only, no markup assertions.
- `test/routing/domain_constraint_test.rb` — add a case asserting the books host matches its constraint and a foreign host does not.
- `e2e/tests/books/homepage.spec.ts` + a `books` project in `e2e/playwright.config.ts` (`baseURL: 'https://dev-new.thegreatestbooks.org'`, `testMatch: /books\/.*/`, no `storageState` / auth setup — there is no signed-in surface). Assert the placeholder page renders and `<html data-theme="cmyk">`.

## Verification gate

All must pass before the work is called done:

- `bin/rails test` (from `web-app/`)
- `bundle exec standardrb`
- `yarn build:all` — must emit `app/assets/builds/books.css`
- `npx playwright test --config=e2e/playwright.config.ts --project=books` green against the local dev server (requires the hosts-file entry)
- Manual: `https://dev-new.thegreatestbooks.org/` serves the placeholder with Playfair headings, Lora body, cmyk theme; the other three dev hosts still serve their own sites

## Risks

| Risk | Mitigation |
|---|---|
| nginx `443` block referencing a missing cert → container fails → **all four sites down** | D6: issue the cert on the server first, deploy the nginx change second, confirm reload before walking away. |
| Cloudflare token lacks DNS-edit on the books zone → Caddy can't get a dev cert | Verify early (step 3); mint a broader token if needed. |
| Legacy zone cache rules blanket-caching `new.` | Runbook step 4 audits before DNS is created. |
| `bin/rails generate controller` scaffolds unwanted files | Review the generated file list; keep the controller + test, drop helper/system-test cruft. |

## Non-goals restated

No ranked books, no books data on the page, no books admin, no user-list wiring, no changes to the legacy site or its apex DNS.
