# Books Dummy UI + Domain Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the books domain resolve end-to-end — `dev-new.thegreatestbooks.org` locally and `new.thegreatestbooks.org` in production — serving a placeholder page in the books look, so the books admin UI (which lives inside the books routing constraint) is unblocked.

**Architecture:** Books is already half-wired (`config.domains[:books]` exists, `detect_current_domain` already falls back to `:books`, Rollup already builds `books.js`). This plan adds the four missing pieces — a per-domain CSS build, a layout, a route + `Books::DefaultController`, and the Caddy dev host — then ships the production path (Let's Encrypt cert, nginx server blocks, `BOOKS_DOMAIN` in SOPS, Cloudflare DNS) in a strict order that cannot take the other three sites down.

**Tech Stack:** Rails 8, Propshaft + cssbundling-rails (Tailwind CSS 4 CLI) + jsbundling-rails (Rollup), DaisyUI 5, Minitest, Playwright, Caddy (local TLS via Cloudflare DNS-01), nginx + certbot (production), SOPS + age.

**Spec:** `docs/superpowers/specs/2026-07-12-books-dummy-ui-design.md`
**Branch:** `books-dummy-ui` (already created, spec already committed on it)

## Global Constraints

- Run **all** Rails/yarn commands from `web-app/`. The `Caddyfile`, `deployment/`, `secrets/`, and `docs/` live at the **project root**.
- Lint with `bundle exec standardrb` (never `bin/rubocop`). `--fix` autocorrects.
- **No code comments** unless they state a constraint the code can't show.
- Use Rails generators for the controller — never hand-create it.
- Namespace all media code (`Books::`). Tests mirror the namespace (`class Books::DefaultControllerTest`).
- Controller tests assert **behavior** (status codes), not HTML/CSS/copy that a designer could freely change. The one exception below (`assert_select "title"`) matches the existing movies/games precedent.
- There is **no test CI** — `.github/workflows/` holds only the Docker image build and the deploy. Verification is local. The owner does **not** use brakeman; do not run it.
- Dev hostnames resolve from the **Windows hosts file**, not DNS. `172.18.93.203 dev-new.thegreatestbooks.org` is **already added** by the owner.
- Production origin IP is `45.33.28.21` (verified: music and games apexes both point there, proxied).
- Exact font stacks, verbatim: body `'Lora', Georgia, 'Times New Roman', serif`; headings `'Playfair Display', Georgia, serif`. DaisyUI theme: `cmyk`.

---

### Task 1: Books CSS build

Produces `app/assets/builds/books.css` with the `cmyk` DaisyUI theme and the book fonts. This must exist before the layout in Task 2, because `stylesheet_link_tag "books"` raises `Propshaft::MissingAssetError` if the build output is absent — which would make Task 2's test fail for the wrong reason.

**Files:**
- Create: `web-app/app/assets/stylesheets/books/application.css`
- Modify: `web-app/package.json` (scripts block)
- Modify: `web-app/Procfile.dev` (css line)

**Interfaces:**
- Consumes: nothing.
- Produces: the built asset `books.css`, referenced by Task 2's layout as `stylesheet_link_tag "books"`. The yarn script name is `build:css:books`.

- [ ] **Step 1: Create the books stylesheet**

Create `web-app/app/assets/stylesheets/books/application.css`. The `@import`/`@source` block mirrors `games/application.css` exactly (minus its `paging.css`, which books has no equivalent of). Note the root font-size is deliberately left at the browser default — DaisyUI's component sizing assumes 16px.

```css
@import "tailwindcss" source(none);
@source "../../../../public/*.html";
@source "../../../../app/helpers/**/*.rb";
@source "../../../../app/javascript/**/*.js";
@source "../../../../app/views/**/*";
@source "../../../../app/components/**/*";

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

- [ ] **Step 2: Add the build scripts**

In `web-app/package.json`, replace the `build:css` line and add `build:css:books` after `build:css:games`. The aggregate `build:css` is what cssbundling-rails runs from `assets:precompile` inside the Dockerfile, so books **must** be in it or production ships without the stylesheet.

```json
    "build:css": "yarn build:css:music && yarn build:css:movies && yarn build:css:games && yarn build:css:books",
    "build:css:music": "npx @tailwindcss/cli -i ./app/assets/stylesheets/music/application.css -o ./app/assets/builds/music.css --minify",
    "build:css:movies": "npx @tailwindcss/cli -i ./app/assets/stylesheets/movies/application.css -o ./app/assets/builds/movies.css --minify",
    "build:css:games": "npx @tailwindcss/cli -i ./app/assets/stylesheets/games/application.css -o ./app/assets/builds/games.css --minify",
    "build:css:books": "npx @tailwindcss/cli -i ./app/assets/stylesheets/books/application.css -o ./app/assets/builds/books.css --minify",
```

- [ ] **Step 3: Add the dev watcher**

In `web-app/Procfile.dev`, replace the `css:` line:

```
css: yarn build:css:music --watch & yarn build:css:movies --watch & yarn build:css:games --watch & yarn build:css:books --watch
```

- [ ] **Step 4: Build it and verify the output**

Run (from `web-app/`):

```bash
yarn build:css:books && ls -l app/assets/builds/books.css && grep -c "cmyk" app/assets/builds/books.css && grep -c "Playfair Display" app/assets/builds/books.css
```

Expected: the file exists and both `grep -c` calls print a count of at least `1`. If either prints `0`, the theme or font rule did not survive the build — fix before continuing.

- [ ] **Step 5: Verify the full build still works**

Run: `yarn build:all`
Expected: exits 0; `app/assets/builds/` contains `music.css`, `movies.css`, `games.css`, `books.css`.

- [ ] **Step 6: Commit**

```bash
git add web-app/app/assets/stylesheets/books/application.css web-app/package.json web-app/Procfile.dev
git commit -m "Add books CSS build (cmyk theme, Lora/Playfair fonts)"
```

---

### Task 2: Books domain config, route, controller, layout

The Rails half of the wiring, TDD'd from the controller test. At the end of this task `https://dev-new.thegreatestbooks.org` would serve the placeholder if Caddy knew about it (Task 3).

**Files:**
- Modify: `web-app/config/initializers/domain_config.rb` (books entries)
- Modify: `web-app/config/routes.rb` (new constraint block after the movies block, ~line 271)
- Create: `web-app/app/controllers/books/default_controller.rb` (via generator)
- Create: `web-app/app/views/books/default/index.html.erb` (via generator, contents replaced)
- Create: `web-app/app/views/layouts/books/application.html.erb`
- Create: `web-app/test/controllers/books/default_controller_test.rb` (via generator, contents replaced)
- Modify: `web-app/test/routing/domain_constraint_test.rb` (append one test)
- Modify: `web-app/app/controllers/my_lists_controller.rb` (stale comment on `resolve_layout`, ~line 70)

**Interfaces:**
- Consumes: `books.css` from Task 1 (`stylesheet_link_tag "books"`).
- Produces: route helper `books_root_path` / `books_root_url`; `Books::DefaultController#index`; layout `books/application`; `Rails.application.config.domains[:books] == "dev-new.thegreatestbooks.org"` in dev/test. Task 4's E2E spec asserts `<html data-theme="cmyk">` and the `📚` navbar brand from the layout.

- [ ] **Step 1: Write the failing controller test**

Create `web-app/test/controllers/books/default_controller_test.rb`. The host is hardcoded, matching the existing `Movies::DefaultControllerTest` precedent:

```ruby
require "test_helper"

class Books::DefaultControllerTest < ActionDispatch::IntegrationTest
  test "should get index for books domain" do
    host! "dev-new.thegreatestbooks.org"
    get books_root_url
    assert_response :success
  end

  test "should use books layout" do
    host! "dev-new.thegreatestbooks.org"
    get books_root_url
    assert_response :success
    assert_select "title", /The Greatest Books/
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

Run: `bin/rails test test/controllers/books/default_controller_test.rb`
Expected: FAIL — `NameError: undefined local variable or method 'books_root_url'` (the route doesn't exist yet).

- [ ] **Step 3: Point the books domain at the new host and layout**

In `web-app/config/initializers/domain_config.rb`, change two lines. The old `"localhost:3000"` default could never match `request.host` (which carries no port), and the old `"application"` layout is the legacy root layout no other domain uses.

```ruby
    books: ENV.fetch("BOOKS_DOMAIN", "dev-new.thegreatestbooks.org")
```

```ruby
    books: {
      name: "The Greatest Books",
      color_scheme: "purple",
      layout: "books/application",
      images_cdn: {
        production: "https://images.thegreatestbooks.org",
        default: "https://images-dev.thegreatestbooks.org"
      }
    }
```

- [ ] **Step 4: Generate the controller**

Run (from `web-app/`):

```bash
bin/rails generate controller books/default index --skip-routes --force
```

`--skip-routes` matters: without it the generator appends a stray `get "books/default/index"` route outside the domain constraint. `--force` matters too: the test file from Step 1 already exists, and without `--force` the generator stops on an interactive overwrite prompt. It will clobber that test with a scaffold — Step 8 restores it.

Then replace the body of `web-app/app/controllers/books/default_controller.rb` with (mirrors `Movies::DefaultController`):

```ruby
class Books::DefaultController < ApplicationController
  layout "books/application"

  def index
  end
end
```

- [ ] **Step 5: Add the route**

In `web-app/config/routes.rb`, add a books constraint block immediately after the movies block (the one ending `root to: "movies/default#index", as: :movies_root`) and before the games block:

```ruby
  constraints DomainConstraint.new(Rails.application.config.domains[:books]) do
    root to: "books/default#index", as: :books_root
  end
```

- [ ] **Step 6: Create the books layout**

Create `web-app/app/views/layouts/books/application.html.erb`. This is the games layout with the user-list plumbing removed (no `data-controller="user-list-state"`, no `navbar_my_lists` link, no `UserLists::ModalComponent`, no `Toast::RegionComponent`, no `user_list_icon_template`) — books' user-list surfaces are migrated as data but not safe to activate, because `MyListsController#csv_row` calls `listable.release_year` and `Books::Book` has `first_published_year`. There is no books search route yet, so the games search form is dropped too.

```erb
<!DOCTYPE html>
<html data-theme="cmyk">
  <head>
    <title><%= content_for?(:page_title) ? yield(:page_title) : "Greatest Books Ranked | The Greatest Books" %></title>
    <meta name="description" content="<%= content_for?(:meta_description) ? yield(:meta_description) : "Discover definitive rankings of the greatest books of all time. Aggregated from the best book lists ever published." %>">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <%= csrf_meta_tags %>
    <%= csp_meta_tag %>

    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Lora:ital,wght@0,400;0,500;0,600;0,700;1,400&family=Playfair+Display:wght@400;700&display=swap" rel="stylesheet">

    <%= stylesheet_link_tag "books", "data-turbo-track": "reload" %>
    <%= javascript_include_tag "application", "data-turbo-track": "reload" %>
  </head>

  <body>
    <div class="navbar bg-base-200">
      <div class="navbar-start">
        <div class="dropdown">
          <div tabindex="0" role="button" class="btn btn-ghost lg:hidden">
            <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h8m-8 6h16" />
            </svg>
          </div>
          <ul tabindex="0" class="menu menu-sm dropdown-content mt-3 z-[1] p-2 shadow bg-base-100 rounded-box w-52">
            <li><%= link_to "Books", "/" %></li>
            <li><%= link_to "Authors", "/" %></li>
            <li><%= link_to "Lists", "/" %></li>
          </ul>
        </div>
        <%= link_to "/", class: "btn btn-ghost text-xl" do %>
          <span class="text-2xl mr-2">📚</span>
          <%= domain_name %>
        <% end %>
      </div>
      <div class="navbar-center hidden lg:flex">
        <ul class="menu menu-horizontal px-1">
          <li><%= link_to "Books", "/" %></li>
          <li><%= link_to "Authors", "/" %></li>
          <li><%= link_to "Lists", "/" %></li>
        </ul>
      </div>
      <div class="navbar-end">
        <button class="btn btn-primary" onclick="login_modal.showModal()" id="navbar_login_button">Login</button>
      </div>
    </div>

    <main class="container mx-auto px-4 py-8">
      <%= yield %>
    </main>

    <footer class="footer footer-center p-10 bg-base-200 text-base-content">
      <aside>
        <p>Copyright © 2026 - All rights reserved by <%= domain_name %></p>
      </aside>
    </footer>

    <!-- Login Modal -->
    <dialog id="login_modal" class="modal">
      <div class="modal-box">
        <h3 class="font-bold text-lg mb-4">Sign In</h3>
        <%= render Authentication::WidgetComponent.new(reload_after_auth: true) %>
        <div class="modal-action">
          <form method="dialog">
            <button class="btn">Close</button>
          </form>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button>close</button>
      </form>
    </dialog>
  </body>
</html>
```

- [ ] **Step 7: Replace the generated index view**

Replace the contents of `web-app/app/views/books/default/index.html.erb` with the placeholder:

```erb
<div class="hero bg-base-200 rounded-box py-16">
  <div class="hero-content text-center">
    <div class="max-w-lg">
      <h1 class="mb-5 text-5xl font-bold">The Greatest Books</h1>
      <p class="mb-5 text-lg">A new home for the greatest books of all time is being built here. Rankings, lists, and authors are on their way.</p>
    </div>
  </div>
</div>
```

- [ ] **Step 8: Restore the controller test and run it**

The generator overwrote `web-app/test/controllers/books/default_controller_test.rb` with a scaffold test. Replace its contents with exactly the test from Step 1, then run:

Run: `bin/rails test test/controllers/books/default_controller_test.rb`
Expected: PASS — 2 runs, 0 failures, 0 errors.

If it fails with `Propshaft::MissingAssetError: The asset 'books.css' was not found`, Task 1 Step 4 was skipped — run `yarn build:css:books`.

- [ ] **Step 9: Add the routing test**

Append to `web-app/test/routing/domain_constraint_test.rb`, inside the class:

```ruby
  test "books domain constraint matches the books host only" do
    constraint = DomainConstraint.new(Rails.application.config.domains[:books])

    request = ActionDispatch::TestRequest.create
    request.host = "dev-new.thegreatestbooks.org"
    assert constraint.matches?(request)

    other = ActionDispatch::TestRequest.create
    other.host = "dev.thegreatestmusic.org"
    assert_not constraint.matches?(other)
  end
```

Run: `bin/rails test test/routing/domain_constraint_test.rb`
Expected: PASS — 4 runs, 0 failures.

- [ ] **Step 10: Fix the now-stale comment in MyListsController**

`web-app/app/controllers/my_lists_controller.rb` says books "has no layout yet" — true until this task. Behavior stays unchanged (books My Lists is still broken on `listable.release_year`), only the comment changes:

```ruby
  # Music shares the music layout. Books has a layout now, but My Lists is not
  # wired for books yet (csv_row calls listable.release_year, which
  # Books::Book does not have), so books still falls back to music.
  def resolve_layout
    case Current.domain
    when :games then "games/application"
    when :movies then "movies/application"
    else "music/application"
    end
  end
```

- [ ] **Step 11: Run the full suite and the linter**

Run: `bin/rails test`
Expected: 0 failures, 0 errors. (Baseline before this branch was 4500 runs / 0 failures.)

Run: `bundle exec standardrb`
Expected: no offenses. If offenses appear in files this task touched, run `bundle exec standardrb --fix` and re-run the suite.

- [ ] **Step 12: Commit**

```bash
git add web-app/config/initializers/domain_config.rb web-app/config/routes.rb \
        web-app/app/controllers/books/default_controller.rb \
        web-app/app/views/books/default/index.html.erb \
        web-app/app/views/layouts/books/application.html.erb \
        web-app/app/controllers/my_lists_controller.rb \
        web-app/test/controllers/books/default_controller_test.rb \
        web-app/test/routing/domain_constraint_test.rb
git add -A web-app/app/helpers  # only if the generator created a books helper
git commit -m "Wire books domain: route, default controller, layout, placeholder page"
```

---

### Task 3: Caddy dev host

Makes `https://dev-new.thegreatestbooks.org` serve the app locally. Caddy obtains a real Let's Encrypt cert via a DNS-01 challenge, which means writing a TXT record into the `thegreatestbooks.org` Cloudflare zone — this task is also the **early warning** for whether `CLOUDFLARE_API_TOKEN` has DNS-edit permission on that zone. Production certbot (Task 8) needs the exact same permission, so a failure here is much cheaper to discover than a failure on the server.

**Files:**
- Modify: `Caddyfile` (project root)

**Interfaces:**
- Consumes: `books_root` from Task 2 (Caddy just reverse-proxies to `localhost:3000`).
- Produces: a working `https://dev-new.thegreatestbooks.org`, which Task 4's Playwright project uses as its `baseURL`.

- [ ] **Step 1: Add the books dev host**

Append to the project-root `Caddyfile`:

```
dev-new.thegreatestbooks.org {
	import common
}
```

(Use a literal tab for the indent — the existing blocks are tab-indented.)

- [ ] **Step 2: Start the Rails dev server**

In a separate terminal, from `web-app/`: `bin/dev`
Expected: foreman starts web on port 3000, sidekiq, and the JS/CSS watchers (including the new books watcher).

- [ ] **Step 3: Restart Caddy and watch it issue the cert**

Restart Caddy from the project root (`./run_caddy.sh`, or reload it however it currently runs). Watch the log for the new host.

Expected: Caddy logs a successful certificate obtain for `dev-new.thegreatestbooks.org`.

**If it fails with a Cloudflare authorization/permission error**, the API token cannot write DNS for the books zone. This is an owner action: mint a Cloudflare token with `Zone:DNS:Edit` covering `thegreatestbooks.org` (in addition to the three existing zones) and replace `CLOUDFLARE_API_TOKEN` in the project-root `.env` and in `web-app/.env`. Then repeat this step. Do not proceed to production until this works — certbot needs the same permission.

- [ ] **Step 4: Verify the site resolves and serves books**

Run:

```bash
curl -sI https://dev-new.thegreatestbooks.org/ | head -1
curl -s https://dev-new.thegreatestbooks.org/ | grep -o 'data-theme="cmyk"'
curl -s https://dev-new.thegreatestbooks.org/ | grep -o '<title>[^<]*</title>'
```

Expected: `HTTP/2 200`; `data-theme="cmyk"`; a title containing `The Greatest Books`.

- [ ] **Step 5: Verify the other three dev sites still work**

Run:

```bash
curl -sI https://dev.thegreatestmusic.org/ | head -1
curl -sI https://dev.thegreatest.games/ | head -1
curl -sI https://dev.thegreatestmovies.org/ | head -1
```

Expected: `HTTP/2 200` for each.

- [ ] **Step 6: Commit**

```bash
git add Caddyfile
git commit -m "Add dev-new.thegreatestbooks.org to Caddy"
```

---

### Task 4: Playwright E2E for the books homepage

**Files:**
- Modify: `web-app/e2e/playwright.config.ts` (add a `books` project)
- Create: `web-app/e2e/tests/books/homepage.spec.ts`

**Interfaces:**
- Consumes: the running dev server + Caddy host from Task 3; the layout and view from Task 2.
- Produces: the `books` Playwright project — run it with `--project=books`.

- [ ] **Step 1: Add the books project to the Playwright config**

In `web-app/e2e/playwright.config.ts`, add to the `projects` array after the `games` project. Books has **no** `storageState` and **no** `dependencies` — there is no signed-in surface on the placeholder, so no auth setup is needed:

```typescript
    {
      name: 'books',
      use: {
        ...devices['Desktop Chrome'],
        baseURL: 'https://dev-new.thegreatestbooks.org',
      },
      testMatch: /books\/.*/,
    },
```

- [ ] **Step 2: Write the failing spec**

Create `web-app/e2e/tests/books/homepage.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';

test.describe('Books homepage', () => {
  test('homepage loads successfully', async ({ page }) => {
    const response = await page.goto('/');

    expect(response?.status()).toBe(200);
  });

  test('homepage has the books title', async ({ page }) => {
    await page.goto('/');

    await expect(page).toHaveTitle(/The Greatest Books/i);
  });

  test('homepage renders the placeholder hero', async ({ page }) => {
    await page.goto('/');

    await expect(page.getByRole('heading', { name: 'The Greatest Books', level: 1 })).toBeVisible();
  });

  test('homepage uses the cmyk theme', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('html')).toHaveAttribute('data-theme', 'cmyk');
  });

  test('navbar exposes the login button', async ({ page }) => {
    await page.goto('/');

    await expect(page.locator('#navbar_login_button')).toBeVisible();
  });
});
```

- [ ] **Step 3: Run the books project**

Run (from `web-app/`, with `bin/dev` and Caddy running):

```bash
npx playwright test --config=e2e/playwright.config.ts --project=books
```

Expected: 5 passed. If the run fails to connect, Caddy or `bin/dev` is not running (Task 3).

- [ ] **Step 4: Commit**

```bash
git add web-app/e2e/playwright.config.ts web-app/e2e/tests/books/homepage.spec.ts
git commit -m "Add Playwright E2E coverage for the books homepage"
```

---

### Task 5: Teach the cert script about no-www domains

Code-only change; nothing is executed against production here (that's Task 8). The current loop hardcodes `-d $domain -d www.$domain`, and `www.new.thegreatestbooks.org` is nonsense. Restructure `DOMAINS` so each entry declares its own cert name, SANs, and registration email.

**Files:**
- Modify: `deployment/scripts/generate-certs.sh` (lines 22–26 and 39–70)

**Interfaces:**
- Consumes: nothing.
- Produces: a cert lineage named `new.thegreatestbooks.org` at `/etc/letsencrypt/live/new.thegreatestbooks.org/`, which Task 6's nginx blocks reference by that exact path.

- [ ] **Step 1: Replace the DOMAINS array**

In `deployment/scripts/generate-certs.sh`, replace lines 22–26 with a `cert-name;comma-separated-SANs;email` format (empty SAN field means no additional names):

```bash
# Format: cert-name;comma-separated-SANs;registration-email
# An empty SAN field means the cert covers only the cert-name.
DOMAINS=(
    "thegreatestmusic.org;www.thegreatestmusic.org;admin@thegreatestmusic.org"
    "thegreatest.games;www.thegreatest.games;admin@thegreatest.games"
    "thegreatestmovies.org;www.thegreatestmovies.org;admin@thegreatestmovies.org"
    "new.thegreatestbooks.org;;admin@thegreatestbooks.org"
)
```

- [ ] **Step 2: Replace the issuance loop**

Replace the `for domain in "${DOMAINS[@]}"; do ... done` loop (lines 39–63) with one that parses the new format and builds the `-d` arguments:

```bash
for entry in "${DOMAINS[@]}"; do
    IFS=';' read -r cert_name sans email <<< "$entry"

    domain_args=(-d "$cert_name")
    if [ -n "$sans" ]; then
        IFS=',' read -ra san_list <<< "$sans"
        for san in "${san_list[@]}"; do
            domain_args+=(-d "$san")
        done
    fi

    echo "Generating certificate for $cert_name (${#domain_args[@]} names)..."

    docker run --rm \
        -v "$CERT_DIR:/etc/letsencrypt" \
        -v "$TEMP_CREDS:/cloudflare.ini:ro" \
        certbot/dns-cloudflare certonly \
        --dns-cloudflare \
        --dns-cloudflare-credentials /cloudflare.ini \
        --dns-cloudflare-propagation-seconds 60 \
        "${domain_args[@]}" \
        --non-interactive \
        --agree-tos \
        --email "$email" \
        --cert-name "$cert_name"

    if [ $? -eq 0 ]; then
        echo "✓ Certificate for $cert_name generated successfully"
    else
        echo "✗ Failed to generate certificate for $cert_name"
        exit 1
    fi
    echo ""
done
```

- [ ] **Step 3: Fix the summary loop**

Replace the trailing summary loop (lines 68–70) so it parses the same format:

```bash
for entry in "${DOMAINS[@]}"; do
    IFS=';' read -r cert_name _ _ <<< "$entry"
    echo "  $cert_name: $CERT_DIR/live/$cert_name/"
done
```

- [ ] **Step 4: Syntax-check the script**

Run (from the project root):

```bash
bash -n deployment/scripts/generate-certs.sh && echo "syntax OK"
```

Expected: `syntax OK`. (`renew-certs.sh` needs no change — bare `certbot renew` renews every stored lineage, including the new one.)

- [ ] **Step 5: Commit**

```bash
git add deployment/scripts/generate-certs.sh
git commit -m "Support no-www domains in generate-certs.sh; add new.thegreatestbooks.org"
```

---

### Task 6: nginx server blocks for new.thegreatestbooks.org

Code-only; deployed in Task 8 — **after** the cert exists on the server. An `ssl_certificate` pointing at a missing path makes nginx fail to start, and that one container fronts music, movies, and games too.

**Files:**
- Modify: `deployment/nginx/the-greatest.conf.template` (line 7–9 `server_name` list; append a new 443 block)

**Interfaces:**
- Consumes: the cert lineage `new.thegreatestbooks.org` from Task 5 / Task 8.
- Produces: origin TLS + proxying for `new.thegreatestbooks.org` → `rails_app`, which the Rails books domain constraint (Task 2) then routes, given `BOOKS_DOMAIN` from Task 7.

- [ ] **Step 1: Add the host to the port-80 server block**

In `deployment/nginx/the-greatest.conf.template`, extend the `server_name` list at lines 7–9:

```nginx
    server_name thegreatestmusic.org www.thegreatestmusic.org
                thegreatest.games www.thegreatest.games
                thegreatestmovies.org www.thegreatestmovies.org
                new.thegreatestbooks.org;
```

- [ ] **Step 2: Append the 443 server block**

Append to the end of the file. There is no `www.new.` redirect block — that hostname does not exist. This mirrors the `thegreatestmusic.org` 443 block exactly, with the books cert paths:

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name new.thegreatestbooks.org;

    ssl_certificate ${CERT_PATH}/new.thegreatestbooks.org/fullchain.pem;
    ssl_certificate_key ${KEY_PATH}/new.thegreatestbooks.org/privkey.pem;

    include /etc/nginx/snippets/ssl-params.conf;
    include /etc/nginx/bots.d/blockbots.conf;
    include /etc/nginx/bots.d/ddos.conf;

    root /var/www/html;
    index index.html;

    client_max_body_size 20M;

    location /__/auth {
        proxy_pass https://the-greatest-books.firebaseapp.com;
    }

    location / {
        proxy_pass http://rails_app;
        proxy_redirect off;
        include /etc/nginx/snippets/proxy-params.conf;
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add deployment/nginx/the-greatest.conf.template
git commit -m "Add nginx server blocks for new.thegreatestbooks.org"
```

---

### Task 7: BOOKS_DOMAIN in production secrets

Without this, production Rails keeps the dev default (`dev-new.thegreatestbooks.org`), the books constraint never matches `new.thegreatestbooks.org`, and the site 404s.

**Files:**
- Modify: `secrets/.env.production` (SOPS-encrypted)

**Interfaces:**
- Consumes: nothing.
- Produces: `BOOKS_DOMAIN=new.thegreatestbooks.org` in the container environment, read by `config/initializers/domain_config.rb` (Task 2).

- [ ] **Step 1: Edit the encrypted secrets file**

Run (from the project root):

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt sops secrets/.env.production
```

Add this line next to the existing `MUSIC_DOMAIN` / `MOVIES_DOMAIN` / `GAMES_DOMAIN` entries, then save and exit:

```
BOOKS_DOMAIN=new.thegreatestbooks.org
```

- [ ] **Step 2: Verify it round-trips**

Run:

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/production.txt sops -d secrets/.env.production | grep DOMAIN
```

Expected: four lines — `MUSIC_DOMAIN`, `MOVIES_DOMAIN`, `GAMES_DOMAIN`, and `BOOKS_DOMAIN=new.thegreatestbooks.org`.

- [ ] **Step 3: Confirm the file is still encrypted at rest**

Run: `head -2 secrets/.env.production`
Expected: JSON starting with `{ "data": "ENC[AES256_GCM,...` — **not** plaintext. If it is plaintext, do not commit; re-encrypt with `sops --encrypt`.

- [ ] **Step 4: Commit**

```bash
git add secrets/.env.production
git commit -m "Add BOOKS_DOMAIN to production secrets"
```

---

### Task 8: Production rollout (owner-executed, strict order)

Everything above is committed but inert in production. This task ships it. **The order is not negotiable** — the deploy workflow fires automatically on merge to main (image build → `repository_dispatch` → SSH, `git pull`, `docker compose build --no-cache nginx`, `up -d`), so the nginx config from Task 6 lands on the server the moment the branch merges. If the cert is not already on disk at that point, nginx will not start, and music, movies, and games go down with it.

**Files:** none — this is a runbook.

**Interfaces:**
- Consumes: Tasks 5, 6, 7 (committed, unmerged).
- Produces: a live `https://new.thegreatestbooks.org`.

- [ ] **Step 1: Audit the books zone's cache rules — BEFORE any DNS change**

The `thegreatestbooks.org` zone fronts the **live legacy site**. A "Cache Everything" page rule or cache ruleset matching `*thegreatestbooks.org/*` would apply to `new.` as well, serving stale HTML from Cloudflare's edge.

Run (from `web-app/`):

```bash
set -a && source .env && set +a
curl -s "https://api.cloudflare.com/client/v4/zones/$BOOKS_CLOUDFLARE_ZONE_ID/pagerules" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | python3 -m json.tool
curl -s "https://api.cloudflare.com/client/v4/zones/$BOOKS_CLOUDFLARE_ZONE_ID/rulesets" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | python3 -m json.tool
```

Report what you find to the owner. This zone may also carry zone-wide **redirect** rules (`http_request_dynamic_redirect`), not just cache rules — a redirect matching the whole zone would bounce `new.` to the old site exactly like a cache-everything rule would serve it stale HTML. Acceptance criterion: reject/adjust ANY rule that matches the whole zone rather than the apex/`www` hosts specifically, whatever its action (cache, redirect, transform). Stop and agree a bypass/exclusion for `new.thegreatestbooks.org` before continuing if one is found.

- [ ] **Step 2: Issue the production cert — BEFORE merging**

The cert must exist on disk before the nginx config deploys. Run the one-off issuance directly on the server (the updated script from Task 5 isn't on the server yet — it arrives with the merge, and is what keeps future re-runs correct):

```bash
ssh deploy@45.33.28.21
cd /home/deploy/apps/the-greatest

export CLOUDFLARE_API_TOKEN=$(grep '^CLOUDFLARE_API_TOKEN=' .env | cut -d '=' -f2-)
TEMP_CREDS=$(mktemp)
printf 'dns_cloudflare_api_token = %s\n' "$CLOUDFLARE_API_TOKEN" > "$TEMP_CREDS"
chmod 600 "$TEMP_CREDS"

docker run --rm \
    -v /etc/letsencrypt:/etc/letsencrypt \
    -v "$TEMP_CREDS:/cloudflare.ini:ro" \
    certbot/dns-cloudflare certonly \
    --dns-cloudflare \
    --dns-cloudflare-credentials /cloudflare.ini \
    --dns-cloudflare-propagation-seconds 60 \
    -d new.thegreatestbooks.org \
    --non-interactive \
    --agree-tos \
    --email admin@thegreatestbooks.org \
    --cert-name new.thegreatestbooks.org

rm -f "$TEMP_CREDS"
sudo ls -l /etc/letsencrypt/live/new.thegreatestbooks.org/
```

Expected: certbot reports success, and the `ls` shows `fullchain.pem` and `privkey.pem`. DNS-01 needs no A record, so this works before the hostname exists.

**Do not proceed until this succeeds.** If certbot fails on a Cloudflare permissions error, the API token lacks `Zone:DNS:Edit` on the books zone (see Task 3 Step 3).

- [ ] **Step 3: Merge the branch and let the deploy run**

Open a PR from `books-dummy-ui` to `main` and merge it (or merge locally and push). The image build fires, then the deploy: the server pulls the code, decrypts `BOOKS_DOMAIN` into `.env`, rebuilds nginx with the new server blocks, and restarts.

- [ ] **Step 4: Verify nginx came up and the other three sites are unharmed**

The deploy workflow runs `docker compose -f docker-compose.prod.yml up -d`, which starts containers but does not wait for them to stay healthy. If the cert path is wrong, nginx **exits after starting** — `set -e` in the deploy script does not trip (the `up -d` command itself still returns 0), so the GitHub Actions run goes **green**, and `restart: unless-stopped` sends the nginx container into a crash loop while music, movies, and games are down. A green Actions run is not evidence that nginx came up. The checks below are the ONLY detection mechanism — always run them after this deploy, regardless of Actions status:

```bash
ssh deploy@45.33.28.21
cd /home/deploy/apps/the-greatest
docker compose -f docker-compose.prod.yml ps
docker compose -f docker-compose.prod.yml logs --tail=30 nginx
```

Expected: the nginx container is `Up`, with no `cannot load certificate` errors in the log.

Then from your machine:

```bash
curl -sI https://thegreatestmusic.org/ | head -1
curl -sI https://thegreatest.games/ | head -1
curl -sI https://thegreatestmovies.org/ | head -1
```

Expected: `HTTP/2 200` for each.

**If nginx failed to start**, recover in seconds, on the server, with no CI round-trip. `deployment/nginx/the-greatest.conf.template` is not baked into the nginx image — `deployment/nginx/Dockerfile` never `COPY`s it, and `docker-compose.prod.yml` bind-mounts it read-only into `/etc/nginx/templates/the-greatest.conf.template`. So editing it on the server and recreating the container is enough; no image rebuild, no `git revert`, no waiting on CI:

```bash
cd /home/deploy/apps/the-greatest
# delete the new.thegreatestbooks.org 443 block from deployment/nginx/the-greatest.conf.template
docker compose -f docker-compose.prod.yml up -d --force-recreate nginx
# once the cert is in place: git checkout -- deployment/nginx/the-greatest.conf.template
```

Re-run the `ps` / `logs` / curl checks above to confirm recovery before diagnosing the cert path.

- [ ] **Step 5: Confirm the origin serves books before DNS points at it**

Bypass DNS and hit the origin directly with the right SNI/Host:

```bash
curl -sk --resolve new.thegreatestbooks.org:443:45.33.28.21 https://new.thegreatestbooks.org/ -o /dev/null -w '%{http_code}\n'
curl -sk --resolve new.thegreatestbooks.org:443:45.33.28.21 https://new.thegreatestbooks.org/ | grep -o 'data-theme="cmyk"'
```

Expected: `200` and `data-theme="cmyk"`. This proves the whole chain (nginx block → cert → `BOOKS_DOMAIN` → books route) works before a single visitor can reach the hostname.

- [ ] **Step 6: Confirm Firebase authorized domains (owner action)**

The books layout ships a working Login button (`#navbar_login_button` → `login_modal` → `Authentication::WidgetComponent` → `signInWithRedirect`). Firebase rejects sign-in from any hostname not on its *Authorized domains* allowlist (`auth/unauthorized-domain`). That allowlist lives in the Firebase console, not in this repo, so nothing in the branch proves it — and it is untested by CI: the books E2E spec (Task 4) asserts the login button is visible but never clicks it.

In Firebase Console → Authentication → Settings → Authorized domains, confirm both `new.thegreatestbooks.org` and `dev-new.thegreatestbooks.org` are present; add whichever is missing. Do this before or alongside Step 7 (DNS) — login will 400 with `auth/unauthorized-domain` on the new host until it's done, even though the rest of the page works.

- [ ] **Step 7: Create the Cloudflare DNS record**

Run (from `web-app/`):

```bash
set -a && source .env && set +a
curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$BOOKS_CLOUDFLARE_ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"type":"A","name":"new","content":"45.33.28.21","proxied":true,"ttl":1}' \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print('success:',d['success'],d.get('errors'))"
```

Expected: `success: True []`. Proxied matches the other three apexes.

- [ ] **Step 8: Verify the live site**

```bash
curl -sI https://new.thegreatestbooks.org/ | head -1
curl -s https://new.thegreatestbooks.org/ | grep -o '<title>[^<]*</title>'
curl -sI https://thegreatestbooks.org/ | head -1
```

Expected: `HTTP/2 200` and a title containing `The Greatest Books` for the new host — and the **legacy** site at the apex still returning `200`, untouched.

Open `https://new.thegreatestbooks.org/` in a browser and confirm the cmyk theme, Playfair heading, and Lora body text render.

**Rollback at any point after Step 7:** delete the DNS record and the hostname stops resolving; the nginx block and cert sit idle and harm nothing. This is the rollback for a bad rollout once DNS exists — for an nginx crash caused by a missing/bad cert (before or after DNS), use the fast nginx-only recovery in Step 4 instead; deleting DNS does nothing for that failure mode since the other three sites share the same nginx container.

```bash
set -a && source .env && set +a
REC=$(curl -s "https://api.cloudflare.com/client/v4/zones/$BOOKS_CLOUDFLARE_ZONE_ID/dns_records?name=new.thegreatestbooks.org" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" | python3 -c "import sys,json;print(json.load(sys.stdin)['result'][0]['id'])")
curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/$BOOKS_CLOUDFLARE_ZONE_ID/dns_records/$REC" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"
```

---

## Final verification gate

Everything below must pass before the work is called done:

- [ ] `bin/rails test` (from `web-app/`) — 0 failures, 0 errors
- [ ] `bundle exec standardrb` — no offenses
- [ ] `yarn build:all` — emits `app/assets/builds/books.css`
- [ ] `npx playwright test --config=e2e/playwright.config.ts --project=books` — 5 passed
- [ ] `https://dev-new.thegreatestbooks.org/` serves the placeholder with cmyk theme, Playfair headings, Lora body
- [ ] `https://dev.thegreatestmusic.org/`, `https://dev.thegreatest.games/`, `https://dev.thegreatestmovies.org/` still serve their own sites
- [ ] `https://new.thegreatestbooks.org/` serves the placeholder in production
- [ ] `https://thegreatestmusic.org/`, `https://thegreatest.games/`, `https://thegreatestmovies.org/`, and the legacy `https://thegreatestbooks.org/` all still return 200
