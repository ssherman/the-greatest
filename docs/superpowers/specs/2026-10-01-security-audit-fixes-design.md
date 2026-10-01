# Security audit fixes — design

**Status:** approved in conversation 2026-10-01, awaiting written-spec review.
**Source:** external audit `Security audit: ssherman/the-greatest`, taken at `f717feb` on
2026-09-30 (44 findings: 3 High, 7 Medium, 18 Low, 16 Info). Not committed; the report lives on
Shane's machine. Finding IDs below (H1, M3, L11, I5 …) are the audit's.

## Goal

Fix the audit findings that are real, in the order their risk warrants, as small PRs that can
each be reviewed and reverted on their own. Record why every other finding is deferred or
rejected so nobody re-raises it.

Every finding was re-verified against the code at `f717feb` before this design. Where the audit
was wrong, the verified fact wins and is stated here.

## Summary of verdicts

| Bucket | Findings |
|---|---|
| Real — fixed here | H1, H2, H3, M2 (latent), M3, M4, M5 (docs part), M6, L2, L3, L6, L9, L11, L14, L16, L17, I1, I4, I5, I6, I7, I13, I14 |
| Real — fixed by origin-lockdown (existing branch) | M1 (nginx half), L2 (nginx half) |
| Deferred, each to its own decision | L1, L4, L5, L7, L10, L12, L13, L15, M5 (key-per-person), M7, I8, I10, I11, I12, I15, I16, L18 |
| Not real / rejected | L8, I2, L15's OCSP advice, M7's Brakeman gate and CODEOWNERS, every Linode-firewall and close-port-22 recommendation |

## Corrections to the audit

- **H1 is live now, not only after the books migration.** The audit assumed Firebase's
  one-account-per-email default. This project runs "multiple accounts per identity provider"
  (`firebase_account_lookup.rb:9-12`, verified 2026-09-07), so a password account can be created
  for any address that has no password account yet — i.e. almost every user, on live music and
  games. Email enumeration protection (D10 of the OAuth provider registry design, ON) does not
  block this route: it stops `accounts:update` email changes, not `createUserWithEmailAndPassword`
  followed by linking an email-less X or Facebook identity.
- **M2 is latent.** Shane confirmed 2026-10-01 that he logs in to `/sidekiq-admin` in production,
  so both variables are set. The fail-open code path is still fixed.
- **L3 is worse than stated.** `sign_in` is also CSRF-exempt, so a cross-site form can log a
  visitor into the attacker's account (login CSRF), not only log them out.
- **L8 is not real.** `api/v1/base_controller.rb:57` skips the offset query when
  `page > total_pages`; the OFFSET is bounded by the row count.
- **I5 citation:** `base/search.rb:23` logs only index name and count. The user's query text is
  logged at info by 11 `logger.info ... query_definition.inspect` lines under `app/lib/search/`.
- **L15:** Let's Encrypt ended OCSP in 2025, so do not add stapling. `Referrer-Policy` is already
  sent by Rails (`load_defaults 8.0`).
- **H3:** the bot blocker **is** active (the compose-mounted template includes `blockbots.conf`
  and `ddos.conf` in all four 443 server blocks — an outside review that read only the Dockerfile
  concluded otherwise). `setup-ngxblocker -x -e conf` is a no-op in this image. Behind Cloudflare
  only its user-agent and referrer matching works: its IP list whitelists Cloudflare's ranges and
  every peer is a Cloudflare IP, and its rate zones count per Cloudflare edge.
- **L18:** `.ruby-version` and the Dockerfile agree on 4.0.6; the audit's point is that 4.0.7
  ships `resolv` 0.7.2. Nothing in the app uses `Resolv`. Currency only.

## Shape and order

| # | PR | Findings | Depends on |
|---|---|---|---|
| 1 | Auth hotfix | H1, M3, M2, M4 | nothing — ship first |
| 2 | Deploy workflow and image hygiene (no nginx) | H2, M6, L9, L11, L17, L14, L16, M5/I14 docs | Shane adds `SERVER_SSH_HOST_FINGERPRINT` before merge |
| 3 | Minor hardening | L3, L6, I1, I4, I5, I6, I7, I13 | nothing |
| — | origin-lockdown | M1, L2 (nginx half) | its own plan and checkpoints; not redone here |
| 4a | nginx: remove the bot blocker, pin the base image | H3 | origin-lockdown merged and past Checkpoint A |
| 4b | Rails: `visitor_ip` and `config.hosts` | M1 (Rails half), L2 (Rails half) | origin-lockdown merged and past Checkpoint A |

PRs 1–3 are independent. 4a and 4b are independent of each other and split so a `config.hosts`
mistake can be reverted without touching nginx. Every PR merges to `main`, which deploys.

## PR 1 — auth hotfix

### H1: unverified token email must not inherit provider trust

`AuthenticationService.call` passes the token's `email` claim to `ProviderEmailResolver` as the
fallback **only when `payload["email_verified"] == true`**:

```ruby
fallback_email: (payload["email"] if payload["email_verified"] == true)
```

Why this is safe for real users (verified, not assumed):

- **Google and password** sign-ins resolve from the Firebase provider record (`accounts:lookup`),
  which carries the address. The fallback is never reached.
- **Facebook and Apple** tokens carry no `email` claim at all (Facebook: measured 2026-09-07;
  Apple: its spec's F2), so the fallback already returns nil for them.
- **X with no email** on the provider record has no account-record email either; it matches by
  `auth_uid` or creates a row, exactly as today.

No legitimate sign-in was found where the fallback yields a non-nil address for a trusted
provider with an unverified claim. After the change, an unverified account-record email under a
trusted provider resolves to nil and cannot select another user's row.

Not done, deliberately: the audit's optional extras (deferring the `auth_uid` rewrite until a
second confirmation, a `Resolved` struct with a source tag). The one-line gate closes the route.

Tests:

- Four existing tests reach an unverified password email only through the fallback, because the
  default `stub_account_lookup_empty` returns `users: []`. They get a realistic
  `{"providerId" => "password", "email" => ...}` provider entry instead:
  `authentication_service_test.rb` "surfaces the unverified-email conflict…", "password is never
  email-trusted on a false claim", "builds a resolver…", and `auth_controller_test.rb`
  "returns email_verification_required…".
- New regression tests, one for `twitter.com` and one for `facebook.com`: `email_verified: false`,
  provider entry with no email, claim equal to an existing user's email → that user's row is not
  linked and its `auth_uid` is unchanged.
- New test: `email_verified: true` still passes the claim through as fallback.

Docs corrected in the same PR: the header comment of `provider_email_resolver.rb`,
D8 of `docs/superpowers/specs/2026-09-07-firebase-account-lookup-design.md`, and
`docs/features/oauth-providers.md` (the paragraph saying enumeration protection is "the only thing
blocking that takeover" — it does not block this route).

### M3: Firebase ID tokens in logs

Add `:jwt` to `config.filter_parameters`. The ID token is posted as `{jwt: idToken}` from one
place (`firebase_auth_service.js`), and `jwt` matches none of the existing partial patterns.
Test: `ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)` redacts a
`jwt` key, top-level and nested (JSON params are also wrapped under the controller key).

### M2: Sidekiq Web fails closed

Keep the mount and the SHA-256 + `secure_compare` comparison, but the Basic-auth block returns
false when either `SIDEKIQ_ADMIN_USERNAME` or `SIDEKIQ_ADMIN_PASSWORD` is blank, before any
comparison. Fail at request time, never at boot: a boot-time raise would turn a missing variable
into an outage on all four sites. Integration test: with both variables blank,
`Authorization: Basic Og==` gets 401; with them set, the right credentials get through and wrong
ones get 401. Add both variables to `deployment/ENV.md` and `.env.example`.

### M4: admin viewer role can write and delete

`ListItemsActions` and `BaseListWizardController` (shared by the music albums, music songs and
games includers) gain fail-closed filters, using the existing `DomainScopedAuth` helpers:

- `before_action :require_domain_write!, except: <read actions>`
  - wizard reads: `show`, `show_step`, `step_status`
  - list-item reads: `modal` and the three `*_search` lookups
- `before_action :require_domain_delete!, only:` `destroy`, `bulk_delete` (list items) and
  `restart`, `reparse` (wizard — both delete rows)

The read actions are enumerated rather than the writes, so a future action is gated by default.
The plan confirms the exact action names per controller.

Tests (in the style of the existing `viewer_permission_test.rb`): a `viewer` domain role reaches
the reads and is redirected from a representative write (`advance_step`, `queue_import`) and
delete (`destroy`, `bulk_delete`); an `editor` domain role can write but is redirected from
delete.

## PR 2 — deploy workflow and image hygiene

### H2: the deploy action

`.github/workflows/deploy-production.yml`:

- `appleboy/ssh-action@c4f70287fc37c43b14b30b407224bbbc8e8c6327` with a comment naming the ref.
  This is `master` as of 2026-09-30, which verifies the drone-ssh binary checksum; the `v1.2.5`
  tag (`0ff4204d…`) predates that check, so it is the worse pin.
- `fingerprint: ${{ secrets.SERVER_SSH_HOST_FINGERPRINT }}`.
- `permissions: {}` — the job never uses `GITHUB_TOKEN`.
- Replace the `mkdir ~/.config/sops/age` / `printf ... > keys.txt` / `rm` sequence with
  `SOPS_AGE_KEY="$AGE_PRIVATE_KEY" sops -d secrets/.env.production > .env.new`. The server's sops
  is 3.11.0 (cloud-init), which reads `SOPS_AGE_KEY`. This also removes a latent leak: under
  `set -e` a failing `sops -d` exited before the `rm`, leaving the key on disk.

`.github/workflows/build-web-image.yml`: pin `peter-evans/repository-dispatch` and both
`actions/delete-package-versions` steps to commit SHAs — they are the steps holding
`REPO_DISPATCH_PAT`. The remaining actions stay on major tags until Dependabot exists (deferred);
a SHA pin nothing updates goes stale.

Kept as is, by decision: the age key still reaches the server through the SSH session. Decrypting
on the runner and `scp`-ing the `.env` was considered and declined — `DEPLOY_SSH_KEY` already
lands in the `docker` group, which is root-equivalent, so moving the key buys little.

**The fingerprint secret (Shane, before merge).** It is a GitHub Actions secret only, not SOPS:
the runner needs it before it connects, and it is a hash of a public key, so it is not sensitive.
Read it from the server over an already-trusted SSH session:

```bash
ssh deploy@<server> 'for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$f"; done'
gh secret set SERVER_SSH_HOST_FINGERPRINT --body 'SHA256:...'
```

The plan determines which key type drone-ssh negotiates (likely ED25519) and therefore which
line to use. Failure modes are safe: an absent secret skips verification (today's behaviour); a
wrong one fails the connect and deploys nothing. A rebuilt server has a new host key, so
`SERVER-UPGRADE-GUIDE.md` gains an "update the fingerprint secret" step.

### M6: enforce `yarn.lock`

- `web-app/Dockerfile`: `yarn install --immutable` → `yarn install --frozen-lockfile`. Yarn
  Classic 1.22 silently ignores `--immutable` (reproduced 2026-08-25 and again by the audit).
- `.github/workflows/ci.yml`: an explicit `yarn install --frozen-lockfile` step before the Rails
  tests. Without it, `test:prepare` runs jsbundling's plain `yarn install`, which repairs drift
  instead of failing on it.

If `package.json` and `yarn.lock` have already drifted, the first build fails. That failure is the
point. A static check found all 15 direct ranges present in `yarn.lock`.

### L9: node-build

Replace `curl .../node-build/archive/master.tar.gz | tar xz` with the `v5.4.56` tag tarball and a
`sha256sum -c` check before extracting. `NODE_VERSION` and `.node-version` stay at 22.20.0 (a
Node bump is deferred; Node is build-stage only and absent from the runtime image).

### L11: production image contents

- `BUNDLE_WITHOUT="development:test"`. `bcrypt` (dev+test group on purpose) is needed only by
  `firebase:canary` and `firebase:canary_for_user`, which create a new hash and are run locally.
  The production migration tasks (`firebase:export_v1_passwords`, `firebase:backfill_v1_uids`)
  copy existing hashes as text and do not load `bcrypt`.
- `web-app/.dockerignore` adds `/test`, `/e2e`, `/docs`, `/current_spec_output.txt`,
  `/results.json`.
- `git rm web-app/current_spec_output.txt web-app/results.json` (a 157 KB Claude transcript and an
  Amazon API sample; neither holds a secret).

The plan verifies nothing loaded at production boot or by a production rake task lives in the
test group.

### L17: stale npm lockfile

`git rm web-app/package-lock.json` and add it to `web-app/.gitignore`. Nothing installs from it
(jsbundling picks yarn because `yarn.lock` exists); every npm "Critical" advisory is against it.

### L14: development compose ports

Root `docker-compose.yml`: prefix the Postgres (`6543`), OpenSearch (`9200`, `9600`) and Redis
(`6379`) mappings with `127.0.0.1:`, matching `data-sources/docker-compose.yml`. Clients on the
same machine are unaffected.

### L16: Open Library API runs as root

`data-sources/Dockerfile` creates a uid-10001 user (as `fetcher.Dockerfile` does) and switches to
it before `CMD`. The plan checks that DuckDB's temp directory and anything else written at
runtime are writable by that user.

### M5 / I14: secrets docs and ignores

- Root `.gitignore` adds `temp.env`, `*.decrypted`, `.env.*.plain`.
- `deployment/SECRETS.md`: the deploy section describes the real flow (server-side
  `SOPS_AGE_KEY` decrypt), not the runner-decrypt-and-rsync flow that never existed.
- `deployment/SERVER-UPGRADE-GUIDE.md`: drop `echo "AGE-SECRET-KEY…" > keys.txt` (it lands in
  shell history and leaves a persistent key) in favour of the same env-var form; add the
  fingerprint-secret step.

### Verification

CI green including the new frozen-lockfile step; a local `docker build` of `web-app/`; inspect
the image for absent `test/` and test-group gems; after merge, the deploy log shows the fingerprint
check and a clean `sops -d`.

## PR 3 — minor hardening

- **L3:** `AuthController` rejects `sign_in`, `sign_out` and `check_provider` with 415 unless
  `request.media_type == "application/json"`. They stay exempt from the Rails CSRF token because
  edge-cached pages cannot carry a per-session token. A cross-site HTML form cannot send
  `application/json` without a CORS preflight the app never answers. The plan confirms all JS
  callers send JSON (`firebase_auth_service.js` sign-in and sign-out,
  `authentication_controller.js` sign-out and `check_provider`). Tests: form-encoded → 415, JSON →
  unchanged.
- **L6:** `authentication_controller.js` (the signed-in user's `photoURL`/`displayName`) and
  `wizard_step_controller.js` (an admin-only job error message) build DOM with
  `createElement`/`textContent`/`setAttribute`, as `form_token_controller.js` does.
- **I1:** `UserListPolicy#update?` and `#destroy?` return owner-only. Today they inherit
  `ApplicationPolicy`, which passes any global editor or admin.
- **I4:** `Admin::UsersController` and `Admin::RankingConfigurationsController` wrap `params[:q]`
  in `sanitize_sql_like`.
- **I5:** the 11 `logger.info ... query_definition.inspect` lines under `app/lib/search/` drop to
  `debug`.
- **I6:** `Music::CoverArtDownloadJob` and `Games::CoverArtDownloadJob` pass
  `max_size: 10 * 1024 * 1024` to `Down.download`, as `amazon/base_product_service.rb` does.
- **I7:** `NewsPost` validates `share_image` and `body_images` content types against the same
  allowlist `Image` uses.
- **I13:** `app/views/layouts/application.html.erb` cannot render (text on the `<% when %>` lines
  emits output between `case` and `when`). The plan confirms whether anything renders it; delete
  it if not, otherwise put each `when` on its own line.

## PR 4a — nginx: remove the bot blocker, pin the base image

Decided 2026-10-01: remove `nginx-ultimate-bad-bot-blocker` rather than pin or vendor it. Every
deploy ran `install-ngxblocker` and the `include_filelist.txt` it sources, both from upstream
`master`, as root inside the container that terminates TLS and mounts the certificate keys. Of
what it does behind Cloudflare, only user-agent/referrer matching works.

- `deployment/nginx/Dockerfile`: remove the `wget` install, the installer download and run, and
  the `setup-ngxblocker` line. `FROM nginx:latest` → the current **stable** line's minor tag
  (the plan resolves it, e.g. `nginx:1.30`).
- `.github/workflows/deploy-production.yml`: `build --no-cache nginx` → `build --pull --no-cache
  nginx`, so patch releases within the stable line arrive on each deploy. `--no-cache` stays:
  origin-lockdown's build step fetches Cloudflare's IP ranges and relies on it to refresh them.
  A tag is chosen over a digest because nothing would update a digest until Dependabot exists.
- `deployment/nginx/the-greatest.conf.template`: remove the eight `bots.d/blockbots.conf` and
  `bots.d/ddos.conf` includes.
- `deployment/nginx/nginx.conf`: correct the comment on `include /etc/nginx/conf.d/*.conf;`. Keep
  the glob if origin-lockdown's files rely on it (the plan checks).
- Update origin-lockdown's docs where they describe the blocker's rate zones becoming
  per-visitor.

**Edge consequence (note for Shane, not a task — Cloudflare is out of scope):** SEO-tool
crawlers the blocker refused (AhrefsBot, SemrushBot, MJ12bot, DotBot, rogerbot) will reach music
and games, which have no Cloudflare rule for them; books' zone already blocks Ahrefs/Semrush/
BLEXBot. AI crawlers stay blocked by `ai_bots_protection: block` on all three zones. Googlebot,
bingbot and AdSense were allowed by the blocker and remain allowed.

Verification: the image build runs `nginx -t` (added by origin-lockdown);
`deployment/nginx/test/local-lockdown-test.sh` passes; after deploy,
`deployment/scripts/verify-origin-lockdown.sh` and a browser check of the three sites.

## PR 4b — Rails: real visitor IP and host allowlist

Only after origin-lockdown is deployed: before it, `request.remote_ip` is the Cloudflare edge IP
and this change would put every visitor behind a PoP into one rate-limit bucket.

- **`VisitorIp#visitor_ip`** returns `request.remote_ip`. With nginx's `real_ip_header
  CF-Connecting-IP` trusted only from Cloudflare's ranges, and the nginx container's bridge
  address trusted by Rails' default private ranges, `remote_ip` is the visitor. The method stays,
  so no call site changes. Rewrite its comment and the "remote_ip is the Cloudflare edge"
  comments in the rate-limited controllers (auth, corrections, membership, list submissions,
  contact messages, my/ranking configurations).
- **Rate-limit tests** set `REMOTE_ADDR` instead of the `CF-Connecting-IP` header and keep the
  two-IP shape (fill IP A to the cap, assert IP B still succeeds). A one-IP test cannot tell
  correct keying from wrong keying. Port that shape to `corrections_controller_test.rb`, whose
  current "by ip" test cannot see the difference.
- **`config.hosts`** in production, set in an initializer that runs after `domain_config.rb`
  (`production.rb` runs before `config.domains` exists): every value of `config.domains` split on
  `,`, so www variants and every configured host are allowed without a hand-kept list. Exclude
  `/up` via `config.host_authorization`. Test: every configured host passes; an unknown host gets
  403.
- **nginx** `proxy-params.conf`: `proxy_set_header Host $host` instead of `$http_host`, so a
  client-supplied `:port` no longer reaches Rails. (nginx-side, but it belongs with the Rails host
  change it completes.)

Risk: a host the app serves but `config.domains` omits would get 403. Deriving from the same
config the routes constrain on makes that unlikely. Post-deploy check: all three sites and
`/api/v1` on books.

## Shane's actions outside the PRs

1. Before merging PR 2: add the `SERVER_SSH_HOST_FINGERPRINT` Actions secret.
2. origin-lockdown: Checkpoints A, B, C per its plan.
3. Optional, any time: confirm HTTP-referrer and API restrictions on the Firebase web API key (I10).

## Deferred

Each is real or plausible, but needs its own decision and is not exploitable today.

- **L1 Content-Security-Policy.** Worth doing before the books launch adds user content; needs
  nonces on inline scripts and a report-only period.
- **L4 `check_provider` email oracle.** Rate-limited; a product trade-off with the "use Sign in
  with Google" hint. Revisit after origin-lockdown makes its rate limit per visitor.
- **L5 server-side session expiry.** `expire_after` alone sets only the cookie's Expires; a real
  bound needs a signed issued-at in the session checked by `current_user`.
- **L7 page fetcher DNS rebinding / no auth.** Fix as part of wiring `PageFetcher::Client` to a
  caller.
- **L10 immutable image tags.** Deploy `main-<sha>` instead of `:latest`; also fixes ROLLBACK.md's
  wrong tag format and the ignored `image_tag` dispatch payload.
- **L12 `REPO_DISPATCH_PAT`.** Replacing it means making deploy a `needs:` job of the build
  workflow; `GITHUB_TOKEN` events do not trigger other workflows.
- **L13 deploy-user sudo.** The deploy script needs no sudo, but `docker` group membership is
  root-equivalent anyway, and cloud-init only applies on a rebuild.
- **L15 cipher list.** Remove the non-existent `*-SHA512` suites, add ECDSA suites and X25519.
  Low value behind Cloudflare. No OCSP stapling (see corrections).
- **M5 one age key per holder.** Needs rotating every secret value too, since old ciphertexts are
  public; plan as one maintenance window.
- **M7 Dependabot and SECURITY.md.** Dependabot version PRs deploy when merged; decide cadence
  and which ecosystems first. Then SHA-pin the remaining actions.
- **I8** FastAPI `/docs` unauthenticated (loopback-bound); **I10** Firebase key restrictions
  (console); **I11** pytest 9; **I12** Rails 8.1.4 and gem bumps; **I15** `sslmode: verify-full`
  (needs the DB host's CA); **I16** backups in Terraform; **L18** Ruby 4.0.7; Node 22.23.x.

## Rejected

- **Linode Cloud Firewall, Cloudflare Tunnel for the site, custom AOP certificate, closing port
  22** (M1, L13, I16) — rejected by Shane during origin-lockdown; infra stays provider-agnostic
  and keyless.
- **Brakeman in CI** (M7) — the owner does not use Brakeman.
- **CODEOWNERS** (M7) — one maintainer.
- **L8, I2** — not real (see corrections).
- **Cloudflare rule changes of any kind** — out of scope for this repo's plans; Shane manages
  Cloudflare with his own tool.

Out of this repo but still open: the legacy books app's client-supplied-email takeover
(`the-greatest-books/admin/app/controllers/users_controller.rb:144`).
