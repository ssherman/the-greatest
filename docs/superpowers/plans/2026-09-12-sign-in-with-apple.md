# Sign in with Apple Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn on the Apple button in the auth widget on every site, with the tests re-pinned to the new enabled set, the docs corrected, and the real Apple token measured on dev before it reaches production.

**Architecture:** The provider registry (`config/auth_providers.json`) already carries a complete Apple entry with `enabled: false`; the JS factory, `PROVIDER_MAP`, `TRUSTED_EMAIL_PROVIDERS`, the `User` enum, the icon partial and the server-side provider-record email lookup all exist. The production change is that one flag. The work is in the tests that pin the enabled set, the docs that describe Apple's quirks, and a manual measurement pass.

**Tech Stack:** Rails 8, Minitest + Mocha, ViewComponent, Playwright, Firebase Auth (`OAuthProvider('apple.com')`).

**Spec:** `docs/superpowers/specs/2026-09-12-sign-in-with-apple-design.md` — the plan argues from it; read both.

## Global Constraints

- Run every Rails/yarn command from `web-app/` inside the worktree
  `/home/shane/dev/the-greatest/.claude/worktrees/sign-in-with-apple/`. Never `cd` to the
  main checkout.
- Branch is `worktree-sign-in-with-apple`. Never commit to `main`. No push, no PR, without
  asking.
- Lint is `bundle exec standardrb` (NOT `bin/rubocop`). Run it before every commit that
  touches Ruby.
- Minitest 6: `assert_nil`, never `assert_equal nil, x`.
- `TRUSTED_EMAIL_PROVIDERS` and `PROVIDER_MAP` are NOT touched — Apple is already in both.
- The only production code change in this plan is `"enabled": false` → `true` for `apple` in
  `web-app/config/auth_providers.json`. If a task seems to need another, stop and say so.
- Apple's registry scopes stay exactly `["email", "name"]` (spec F3).
- E2E asserts the Firebase handler URL only, never Apple's page (spec D2).
- Before `yarn test:e2e`, confirm port 3000 belongs to THIS worktree (see Task 2). Never kill
  another checkout's server; never run on another port.
- Commit messages end with the attribution lines the session reminder specifies.

---

### Task 1: Enable Apple and re-pin the Ruby tests

**Files:**
- Modify: `web-app/config/auth_providers.json` (the `apple` entry)
- Modify: `web-app/test/lib/services/auth_provider_registry_test.rb:22-40`
- Modify: `web-app/test/components/authentication/widget_component_test.rb:29-66`

**Interfaces:**
- Consumes: `Services::AuthProviderRegistry.all` (Hash of id → entry, memoised; a Mocha
  stub bypasses the memo because `enabled`/`enabled_for_view` call `all` as a method),
  `Services::AuthProviderRegistry.enabled` (Hash), `.enabled_for_view` (Array of symbol-keyed
  hashes in file order).
- Produces: the enabled id order `%w[google twitter facebook apple]`, which Task 2's E2E
  `ENABLED` array must match.

- [ ] **Step 1: Rewrite the two registry unit tests that pin Apple off, and add the scope pin**

In `web-app/test/lib/services/auth_provider_registry_test.rb`, replace the test
`"enabled excludes providers that are turned off"` and the test
`"enabled_for_view exposes symbol keys in file order"` with the following three tests
(the third is new):

```ruby
  test "enabled excludes providers that are turned off" do
    # Every real provider is enabled now, so the flag is proven on a stubbed
    # config rather than on whichever provider happens to be off this month.
    # Stubbing `all` is enough: `enabled` reaches the config through it.
    Services::AuthProviderRegistry.stubs(:all).returns({
      "on" => {"firebase_id" => "on.example", "label" => "On", "scopes" => [], "enabled" => true},
      "off" => {"firebase_id" => "off.example", "label" => "Off", "scopes" => [], "enabled" => false}
    })

    assert_equal ["on"], Services::AuthProviderRegistry.enabled.keys
  end

  test "enabled_for_view exposes symbol keys in file order" do
    entries = Services::AuthProviderRegistry.enabled_for_view

    assert_equal %w[google twitter facebook apple], entries.map { |e| e[:id] }
    google = entries.first
    assert_equal "google.com", google[:firebase_id]
    assert_equal "Google", google[:label]
    assert_equal ["profile", "email"], google[:scopes]
  end

  test "the Apple entry is enabled and requests the email and name scopes" do
    apple = Services::AuthProviderRegistry.all.fetch("apple")

    assert_equal "apple.com", apple["firebase_id"]
    assert apple["enabled"], "Sign in with Apple shipped enabled (spec 2026-09-12)"
    # Load-bearing, not cosmetic. Under this project's "multiple accounts per
    # email address" setting Firebase requests NO scopes for Apple unless the
    # client passes them. Drop "email" and every new Apple user gets a token
    # with no address on the provider record either -- an email-less row that
    # can never be linked to anything (spec F3).
    assert_equal %w[email name], apple["scopes"]
  end
```

- [ ] **Step 2: Rewrite the two widget tests that pin Apple off**

In `web-app/test/components/authentication/widget_component_test.rb`, replace the test
`"does not render a button for a disabled provider"` with:

```ruby
  test "does not render a button for a disabled provider" do
    # Every real provider is enabled now, so the widget's respect for the
    # flag is proven on a stubbed registry. Real ids are used because the
    # template resolves an icon partial per id.
    Services::AuthProviderRegistry.stubs(:all).returns({
      "google" => {"firebase_id" => "google.com", "label" => "Google", "scopes" => [], "enabled" => true},
      "apple" => {"firebase_id" => "apple.com", "label" => "Apple", "scopes" => [], "enabled" => false}
    })

    render_inline(Authentication::WidgetComponent.new)

    assert_selector "button[data-authentication-provider-param='google']", count: 1
    assert_no_selector "button[data-authentication-provider-param='apple']"
  end
```

and replace the test `"the enabled registry reaches the client as a Stimulus value"` with:

```ruby
  test "the enabled registry reaches the client as a Stimulus value" do
    render_inline(Authentication::WidgetComponent.new)

    raw = page.find("[data-controller='authentication']")["data-authentication-providers-value"]
    parsed = JSON.parse(raw)

    assert_equal %w[google twitter facebook apple], parsed.map { |p| p["id"] }

    # Indexed by id rather than position: `parsed.last` used to mean twitter,
    # and enabling Facebook silently moved these assertions onto a different
    # provider instead of failing.
    by_id = parsed.index_by { |p| p["id"] }

    assert_equal "twitter.com", by_id["twitter"]["firebase_id"]
    assert_equal [], by_id["twitter"]["scopes"], "the client needs the scope list to build the provider"
    # Facebook proves a non-empty scope list survives the trip to the client.
    assert_equal "facebook.com", by_id["facebook"]["firebase_id"]
    assert_equal %w[public_profile email], by_id["facebook"]["scopes"]
    # Apple's scopes are pinned on the client side too because they are
    # load-bearing: without "email" Firebase requests no address from Apple
    # under the multiple-accounts-per-email setting. The registry unit test
    # carries the full explanation.
    assert_equal "apple.com", by_id["apple"]["firebase_id"]
    assert_equal %w[email name], by_id["apple"]["scopes"]
  end
```

- [ ] **Step 3: Run both files and confirm the new pins fail against the current config**

Run (from `web-app/`):

```bash
bin/rails test test/lib/services/auth_provider_registry_test.rb test/components/authentication/widget_component_test.rb
```

Expected: 3 failures — `enabled_for_view exposes symbol keys in file order` (expects four
ids, gets three), `the Apple entry is enabled and requests the email and name scopes`
(`apple["enabled"]` is false), and `the enabled registry reaches the client as a Stimulus
value` (four ids expected, three rendered). The two stubbed tests pass already — that is
correct, they no longer depend on the live config.

- [ ] **Step 4: Flip the flag**

In `web-app/config/auth_providers.json`, change the `apple` entry's `"enabled": false` to
`"enabled": true`. The file's entire diff is that one word:

```json
  "apple": {
    "firebase_id": "apple.com",
    "label": "Apple",
    "scopes": ["email", "name"],
    "enabled": true
  }
```

- [ ] **Step 5: Run the two files again, then everything that reads the registry**

```bash
bin/rails test test/lib/services/auth_provider_registry_test.rb test/components/authentication/widget_component_test.rb
bin/rails test test/lint/auth_provider_registry_test.rb test/lint/daisyui_v4_classes_test.rb test/controllers/auth_controller_test.rb test/lib/services/authentication_service_test.rb
```

Expected: all green, 0 failures, 0 errors, no new warning lines.

- [ ] **Step 6: Lint**

```bash
bundle exec standardrb test/lib/services/auth_provider_registry_test.rb test/components/authentication/widget_component_test.rb
```

Expected: no offenses.

- [ ] **Step 7: Commit**

```bash
git add config/auth_providers.json test/lib/services/auth_provider_registry_test.rb test/components/authentication/widget_component_test.rb
git commit -m "feat(auth): enable Sign in with Apple

One word in config/auth_providers.json. Every other layer -- factory,
PROVIDER_MAP, TRUSTED_EMAIL_PROVIDERS, enum, icon, and the provider-record
email lookup Apple tokens need (they carry no email claim, 0/36 measured)
-- already existed. The tests that pinned Apple off now pin the four-provider
set, and pin Apple's scopes, which are load-bearing under the
multiple-accounts-per-email setting: without \"email\" Firebase requests no
address at all.

The disabled-provider guards move onto a stubbed registry, since no real
provider is disabled any more."
```

(Append the attribution lines from the session reminder.)

---

### Task 2: Apple in the Playwright provider spec

**Files:**
- Modify: `web-app/e2e/tests/books/oauth-providers.spec.ts:15-22`

**Interfaces:**
- Consumes: Task 1's enabled order `%w[google twitter facebook apple]`; the button markup
  `button[data-authentication-provider-param="<id>"]` with text `Sign in with <label>`; the
  Firebase handler redirect `/__/auth/handler?…providerId=<firebase_id>` on the same host.
- Produces: nothing downstream.

- [ ] **Step 1: Move Apple from `DISABLED` to `ENABLED`**

Replace the two constants at the top of `web-app/e2e/tests/books/oauth-providers.spec.ts`
with:

```ts
// Mirrors the enabled entries in web-app/config/auth_providers.json.
// test/components/.../widget_component_test.rb pins the rendered markup to that
// file; this pins what a real browser gets.
const ENABLED = [
  { id: 'google', label: 'Google', firebaseId: 'google.com' },
  { id: 'twitter', label: 'X', firebaseId: 'twitter.com' },
  { id: 'facebook', label: 'Facebook', firebaseId: 'facebook.com' },
  { id: 'apple', label: 'Apple', firebaseId: 'apple.com' },
];

// Empty since Apple shipped (2026-09-12). Kept so the next disabled provider
// has somewhere to go; the loop over it below is a no-op until then.
const DISABLED: string[] = [];
```

Nothing else in the file changes. The redirect test stops at
`/__/auth/handler?…providerId=apple.com` on the same host, exactly like the other three
(spec D2) — do not extend it to `appleid.apple.com`.

- [ ] **Step 2: Build assets and confirm port 3000 is this worktree's**

```bash
yarn build:all
pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1)
[ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"
```

Expected: either `port 3000 is free`, or a path under
`/home/shane/dev/the-greatest/.claude/worktrees/sign-in-with-apple`. If it prints any other
checkout, STOP and tell the user — do not kill it, do not use another port.

- [ ] **Step 3: Start the server (only if the port was free)**

```bash
setsid bin/rails server -p 3000 </dev/null >log/e2e-server.log 2>&1 &
sleep 5; curl -s -o /dev/null -w "%{http_code}\n" -H "Host: dev-new.thegreatestbooks.org" http://localhost:3000/
```

Expected: `200`. (Caddy proxies the `dev*` hostnames to :3000; the Host header is what
routes the request.)

- [ ] **Step 4: Run the provider spec**

```bash
yarn test:e2e books/oauth-providers
```

Expected: 18 passed, 0 failed — per domain (books, music, games): one render test, four
redirect tests, one unknown-provider test. The Apple redirect test on each host proves the
click reached the Firebase handler with `providerId=apple.com`.

- [ ] **Step 5: Commit**

```bash
git add e2e/tests/books/oauth-providers.spec.ts
git commit -m "test(e2e): Apple joins the enabled provider set

Handler-URL assertion only, matching the other providers (spec D2). The
per-host Apple console check is manual and recorded in the spec."
```

(Append the attribution lines from the session reminder.)

---

### Task 3: Docs — the Apple section, the stale provider table, and the F3 correction

**Files:**
- Modify: `docs/features/oauth-providers.md` (append a section after "Email-less accounts")
- Modify: `docs/features/authentication.md:4`, `:95-103`, `:246-266`
- Modify: `docs/superpowers/specs/2026-09-07-firebase-account-lookup-design.md:73-86`

All paths are relative to the worktree root, NOT `web-app/`.

**Interfaces:** none — prose only.

- [ ] **Step 1: Append the Apple section to `docs/features/oauth-providers.md`**

Add this after the "Email-less accounts" section (end of file):

```markdown
## Apple

Enabled 2026-09-12; see `docs/superpowers/specs/2026-09-12-sign-in-with-apple-design.md`.
Apple was already live on the legacy site through this same Firebase project, so the
Firebase console needed nothing — 1,521 users had signed in with it before this app
rendered a button.

**Apple tokens carry no `email` claim, ever.** Measured 2026-09-12 on 36 Apple Firebase
accounts: the account record had no email on 0/36; the provider record had it on 36/36.
It is the Facebook shape, and the same server-side lookup resolves it on a uid miss. The
`users.email` values the legacy app stored came from the client's `providerData`, not from
a token — do not read them as evidence about the claim.

**Hide My Email is the majority case.** 966 of 1,509 Apple users with an address (64%) use
a `@privaterelay.appleid.com` alias. An alias is unique per Apple user per developer team,
so it can never match a Google or password row: an Apple user who also holds another
account here keeps two rows. There is no key to combine on, so this is accepted, not
deferred.

Mail to an alias only arrives if the sending domain is registered under Certificates,
Identifiers & Profiles → Services → *Sign in with Apple for Email Communication* with SPF
passing. Every site sends from `MAIL_FROM_ADDRESS` at `thegreatestbooks.org`
(`MailBranding#from`), and that domain is registered and green. Other rows on that page
are inert; only a change of sending domain would need a new entry.

**The scope list is load-bearing.** Under this project's "multiple accounts with the same
email address" setting, Firebase requests no scopes for Apple unless the client passes
them. `["email", "name"]` in the registry is what makes the provider record carry an
address at all. `test/lib/services/auth_provider_registry_test.rb` pins it.

**The name arrives once.** Apple sends the user's name only on the first authorization.
Firebase keeps it on the account record (35/36 in the same measurement), so the token's
`name` claim is present on later sign-ins and `update_existing` fills a blank
`display_name` from it.

**Return URLs are per host, no wildcards.** Firebase's return URL is
`https://<authDomain>/__/auth/handler`, and `authDomain` here is the page's own hostname,
so every host that renders the widget needs its own entry on the Services ID (Identifiers
→ Services IDs → Sign in with Apple → Configure → Website URLs, then Continue → Save on
the outer page or the dialog is discarded). Registered: `thegreatestbooks.org`,
`dev.thegreatestbooks.org`, `new.thegreatestbooks.org`, `dev-new.thegreatestbooks.org`,
`thegreatestmusic.org`, `dev.thegreatestmusic.org`, `thegreatest.games`,
`dev.thegreatest.games`. Apple documents a cap of 10 website URLs for an individual
enrollment; eight domains plus eight return URLs saved on this individual account, so the
cap is not a joint count. A host missing from the list fails only at Apple's page, with
"invalid_request — Invalid web redirect url" — the E2E stops at the Firebase handler and
cannot see it, so a new host needs one manual click.
```

- [ ] **Step 2: Correct `docs/features/authentication.md`**

Line 4, change the parenthetical:

```markdown
The Greatest uses **Firebase Authentication** on the client side with a **Rails session-based backend**. Users authenticate via Firebase (Google, Apple, Facebook, X, or email/password), the frontend sends a JWT to Rails, Rails validates it and creates a session. All subsequent requests use standard Rails cookie sessions.
```

Replace the "Supported Providers" table (lines 97–103) with:

```markdown
| Provider | Status | Firebase Provider ID | User enum value |
|----------|--------|---------------------|-----------------|
| Google | Implemented | `google.com` | `google` (2) |
| Email/Password | Implemented | `password` | `password` (4) |
| Apple | Implemented | `apple.com` | `apple` (3) |
| Facebook | Implemented | `facebook.com` | `facebook` (0) |
| X (Twitter) | Implemented | `twitter.com` | `twitter` (1) |

The four OAuth providers are declared in `config/auth_providers.json`; [OAuth providers](oauth-providers.md) is the guide to adding one and to what each does differently.
```

Replace the block that starts at the `## Adding a New Auth Provider` heading line (line
246) and ends with the line `10. **Add tests** for the new provider in
\`auth_controller_test.rb\` and \`authentication_service_test.rb\`.` (line 266) — heading
included, the intro line, "### Frontend" 1–4, "### Backend" 5–7, "### Firebase Console" 8,
"### Tests" 9–10 — with the text below. The `### Gotchas` subsection that follows line 266
stays exactly as it is:

```markdown
## Adding a New Auth Provider

OAuth providers are declared in `config/auth_providers.json` and reach every layer from
there — the button, the Stimulus action param, the Firebase factory map, `PROVIDER_MAP`,
`check_provider`. The numbered per-file steps that used to live here described the
pre-registry code (`google_provider.js`, a per-provider Stimulus action) and no longer
match the app. Follow [OAuth providers](oauth-providers.md) instead; it lists the six
places a provider touches and the lint tests that fail when they disagree.

Still true regardless of the registry: enable the provider in the Firebase Console under
Authentication > Sign-in method, and — for any provider that validates redirect URLs per
host (Apple and X both do) — register `https://<host>/__/auth/handler` for every host that
renders the widget.
```

- [ ] **Step 3: Add the dated correction to the account-lookup spec's F3**

In `docs/superpowers/specs/2026-09-07-firebase-account-lookup-design.md`, directly after
the paragraph ending "…collides every time." (line 86), insert:

```markdown
> **Corrected 2026-09-12.** The Apple row is not token evidence. Those 1,509 addresses
> were posted by the legacy client from `providerData`, and `accounts:lookup` on 36 Apple
> accounts found an account-record email on 0/36 and a provider-record email on 36/36.
> For Apple, suppression is unconditional — the Facebook shape — so the collision-scoped
> reading above does not hold for it. Google and X remain uninspected at the account
> level. See `2026-09-12-sign-in-with-apple-design.md` F2.
```

- [ ] **Step 4: Replace the Key Files row that names the deleted `google_provider.js`**

`docs/features/authentication.md:145` (the "Frontend (JavaScript)" table) still lists
`app/javascript/services/auth_providers/google_provider.js`, which the registry work
deleted. Replace that whole table row with:

```markdown
| `app/javascript/services/auth_providers/oauth_provider.js` | One class for every OAuth provider (singleton). Builds the Firebase provider from a registry entry — `PROVIDER_FACTORIES` maps `firebase_id` to constructor, scopes are added from config — and initiates `signInWithRedirect()` |
```

- [ ] **Step 5: Check the edits landed and nothing stale remains**

```bash
grep -n "| Apple | Implemented" docs/features/authentication.md
grep -n "^## Apple" docs/features/oauth-providers.md
grep -n "Corrected 2026-09-12" docs/superpowers/specs/2026-09-07-firebase-account-lookup-design.md
grep -c "google_provider.js" docs/features/authentication.md
```

Expected: one hit each for the first three; the last prints `0` (both the table row from
Step 4 and the numbered step removed in Step 2 are gone).

- [ ] **Step 6: Commit**

```bash
git add docs/features/oauth-providers.md docs/features/authentication.md docs/superpowers/specs/2026-09-07-firebase-account-lookup-design.md
git commit -m "docs(auth): Apple section, refreshed provider table, F3 correction

authentication.md still listed X and Facebook as unimplemented and walked
through the pre-registry per-file steps; both replaced with pointers to the
registry guide. oauth-providers.md gains Apple: no token email (0/36),
64% Hide My Email, load-bearing scopes, name-once, per-host return URLs.
The account-lookup spec's F3 gets a dated note that its Apple row was
client-posted data, not a token measurement."
```

(Append the attribution lines from the session reminder.)

---

### Task 4: Measure the real token and verify every host (spec D3, D4)

This task needs the user at a browser; it cannot be delegated to a subagent. Do it in the
main session.

**Files:**
- Modify: `docs/superpowers/specs/2026-09-12-sign-in-with-apple-design.md` (the `## Measured`
  section)

**Interfaces:**
- Consumes: the running dev server from Task 2 Step 3 (restart it the same way if it has
  stopped); `log/development.log`, where `POST /auth/sign_in` logs its `jwt` param
  (`jwt` is not in `filter_parameters`); the `jwt` gem.

- [ ] **Step 1: Ask the user to click through the three dev hosts**

Ask the user to open each of these, click **Login**, then **Sign in with Apple**, and report
what Apple shows:

- `https://dev-new.thegreatestbooks.org/`
- `https://dev.thegreatestmusic.org/`
- `https://dev.thegreatest.games/`

Pass: Apple's sign-in form (an Apple Account / password prompt). Fail: an Apple error page
reading "invalid_request" / "Invalid web redirect url" — that host's return URL is missing
from the Services ID; the fix is in the Apple Developer portal, not in code.

- [ ] **Step 2: Ask the user to complete one sign-in on `dev-new.thegreatestbooks.org`**

Ask for: the outcome on the site (signed in, or an error message), and roughly when they
clicked, so the log line can be found.

- [ ] **Step 3: Decode the token's claim keys from the dev log**

```bash
# Ruby 3.4+ inspects hashes as {"jwt" => "…"}; older logs used {"jwt"=>"…"}. Both match.
token=$(grep -oP '"jwt" ?=> ?"\K[^"]+' log/development.log | tail -1)
[ -n "$token" ] && echo "token found (${#token} chars)" || echo "NO TOKEN in log -- did the sign-in reach POST /auth/sign_in?"
bin/rails runner "
payload, header = JWT.decode(ENV['TOKEN'], nil, false)
puts 'alg: ' + header['alg']
puts 'claims: ' + payload.keys.sort.join(', ')
puts 'sign_in_provider: ' + payload.dig('firebase', 'sign_in_provider').to_s
puts 'email claim present: ' + payload.key?('email').to_s
puts 'name claim present: ' + payload.key?('name').to_s
puts 'identities keys: ' + payload.dig('firebase', 'identities').keys.sort.join(', ')
" 2>&1 | grep -v '^W, \|warning'
```

Run it as `TOKEN="$token" bin/rails runner …` — that is, export the variable into the
runner's environment; do not paste the token into the command line or the transcript.
Print keys only, never values: the token is a live credential for an hour and the claims
carry PII.

Expected (spec D3): `sign_in_provider: apple.com`, `email claim present: false`,
`name claim present: true`, `identities keys: apple.com`. If `email claim present` is
`true`, that is a finding — record it, it does not block anything.

- [ ] **Step 4: Find the row and which branch `find_user` took**

```bash
bin/rails runner "
u = User.where(external_provider: 'apple').order(updated_at: :desc).first
puts 'user id: ' + u.id.to_s
puts 'created_at: ' + u.created_at.to_s + '  updated_at: ' + u.updated_at.to_s
puts 'auth_uid present: ' + u.auth_uid.present?.to_s
puts 'email present: ' + u.email.present?.to_s + '  relay: ' + u.email.to_s.end_with?('@privaterelay.appleid.com').to_s
puts 'display_name present: ' + u.display_name.present?.to_s
puts 'sign_in_count: ' + u.sign_in_count.to_s
" 2>&1 | grep -v '^W, \|warning'
```

Branch taken: `created_at` well before today and `sign_in_count` > 1 means the uid-hit
branch (expected — the user's Apple ID already had a Firebase account from the legacy
site); `created_at` today means the uid-miss → resolver → create branch. Either is a valid
measurement; say which.

- [ ] **Step 5: Record the results in the spec**

Replace the `## Measured` section's placeholder line in
`docs/superpowers/specs/2026-09-12-sign-in-with-apple-design.md` with the actual results,
in this shape (fill each field from Steps 1–4; write the real values, not these examples):

```markdown
## Measured

**Dev hosts (D4), 2026-09-12.**

| host | Apple rendered |
|---|---|
| `dev-new.thegreatestbooks.org` | sign-in form |
| `dev.thegreatestmusic.org` | sign-in form |
| `dev.thegreatest.games` | sign-in form |

**Token (D3), one real sign-in on `dev-new.thegreatestbooks.org`, 2026-09-12.**
Claims: `aud, auth_time, exp, firebase, iat, iss, name, sub, user_id` —
`sign_in_provider: apple.com`, no `email`, `name` present, `identities: {apple.com}`.
Branch: uid hit on `users#<id>` (Firebase account from the legacy site; `sign_in_count`
<n> → <n+1>). Row after: email present (relay: <yes/no>), `display_name` <filled from
the token / already set>.

**Production hosts (D4): pending deploy.** `new.thegreatestbooks.org`,
`thegreatestmusic.org`, `thegreatest.games` — one click each after the merge deploys;
record the result here in the same table shape.
```

- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-09-12-sign-in-with-apple-design.md
git commit -m "docs(auth): record the Apple dev measurements

Three dev hosts click through to Apple's sign-in form; one real token
decoded from the dev log for its claim set and find_user branch."
```

(Append the attribution lines from the session reminder.)

---

### Task 5: Full verification before handoff

**Files:** none modified.

- [ ] **Step 1: Full Minitest suite**

```bash
bin/rails test
```

Expected: 0 failures, 0 errors; no warning lines beyond the two known upstream sources
(`weighted_list_rank`'s position `puts`, and npm/yarn during `test:prepare`).

- [ ] **Step 2: Lint the whole tree**

```bash
bundle exec standardrb
```

Expected: no offenses.

- [ ] **Step 3: Zeitwerk (no new `app/lib` dir, but cheap)**

```bash
CI=1 bin/rails zeitwerk:check
```

Expected: `All is good!`

- [ ] **Step 4: Confirm the production diff is one word**

```bash
git diff main -- app/ config/ lib/ | grep '^[-+]' | grep -v '^[-+][-+]'
```

Expected: exactly two lines — `-    "enabled": false` and `+    "enabled": true` — and
nothing else under `app/`, `config/`, or `lib/`.

- [ ] **Step 5: Stop the dev server started in Task 2**

```bash
pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1)
[ -n "$pid" ] && readlink /proc/$pid/cwd
```

Only if the printed path is this worktree: `kill $pid`. If it is any other checkout, leave
it alone.

Then hand off with `superpowers:finishing-a-development-branch`. Do not push or open a PR
without asking.
