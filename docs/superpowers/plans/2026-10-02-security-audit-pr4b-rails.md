# Security Audit PR 4b — Real Visitor IP and Host Allowlist Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rails keys every IP rate limit on the visitor address nginx already resolved, admits only the hosts in `config.domains` in production, and nginx stops forwarding a client-supplied `:port` in `Host`.

**Architecture:** Origin lockdown (#338) made nginx's `$remote_addr` the visitor: nginx admits only Cloudflare's ranges and takes `CF-Connecting-IP` only from them. nginx appends `$remote_addr` to `X-Forwarded-For`, and Rails' `RemoteIp` middleware walks that header from the right past trusted private proxies, so `request.remote_ip` is now the visitor. `VisitorIp#visitor_ip` therefore stops reading `CF-Connecting-IP` (which Rails cannot authenticate) and returns `request.remote_ip`. `config.hosts` comes from `config.domains` in an initializer, because `production.rb` runs before `domain_config.rb`.

**Tech Stack:** Rails 8.1 (`ActionDispatch::RemoteIp`, `ActionDispatch::HostAuthorization`, `rate_limit`), Minitest 6, nginx 1.30, bash harness.

**Spec:** `docs/superpowers/specs/2026-10-01-security-audit-fixes-design.md`, section "PR 4b — Rails: real visitor IP and host allowlist".

## Global Constraints

- Run every Rails command from `web-app/`. Lint is `bundle exec standardrb`, never `bin/rubocop`. Never run brakeman.
- Minitest 6: `assert_nil`, never `assert_equal nil, x`.
- Integration tests choose the client address with `env: {"REMOTE_ADDR" => "<ip>"}` on the request (`post path, params: ..., env: {...}`). Without it every request is `127.0.0.1`.
- A rate-limit keying test has the two-IP shape: fill IP A past the cap and **assert A got 429**, then assert IP B still succeeds. Without the 429 assertion the test also passes when the limit never trips.
- Cloudflare configuration is out of scope. Do not plan or suggest changes there.
- Do not mention any site other than books, music and games in code comments, docs or commit messages.
- Commit on branch `security-audit-pr4b-rails`. Never push, never commit to `main`.
- End every commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Match the surrounding comment density. No new documentation files.

## Review Focus

1. **A client rotating `CF-Connecting-IP` on every request (the M1 attack).** Expected: every request lands in the bucket for its real address. Pinned by Task 1 (the `VisitorIp` test "ignores a CF-Connecting-IP header" and the auth test "rotating CF-Connecting-IP does not buy a fresh check_provider bucket").
2. **A client forging `X-Forwarded-For` entries or sending its own `Forwarded` header.** Expected: Rails takes the rightmost untrusted entry, which is the one nginx appended. Pinned by Task 1 (the `VisitorIp` test "ignores entries a client forged to the left of the visitor") and Task 3 (harness probe B10, which checks that nginx really puts the visitor last). The `Forwarded` case was found in the final review: Rack prefers `Forwarded` over `X-Forwarded-For`, so the branch adds `config/initializers/forwarded_headers.rb` and strips the header in nginx (harness B11).
3. **An IPv6 visitor.** Cloudflare passes IPv6 visitors through as-is. Expected: their address is resolved like an IPv4 one. Pinned by Task 1 (the `VisitorIp` test "handles an IPv6 visitor").
4. **The container healthcheck**, which curls `localhost:3000/up` with `Host: localhost:3000`. Expected: 200, or Docker marks web unhealthy. Pinned by Task 2 ("the health check is admitted from any host").
5. **`config.domains` resolving to no hosts in production.** An empty `config.hosts` turns host checking OFF; it does not block everything. Expected: boot fails loudly. Pinned by Task 2 ("refuses a config.domains that yields no hosts"). A forged `X-Forwarded-Host` behind a valid `Host` is pinned beside it ("a forged X-Forwarded-Host is refused even behind a configured Host").

## Before merging (Shane, read-only on production)

These need production and are not plan tasks. Both are reads.

1. **Rails already sees the visitor.** Run `docker compose -f docker-compose.prod.yml logs --no-log-prefix --since 10m web | grep 'Started' | tail -5`. The address after `for` should be a public visitor IP that matches the first column of the nginx log. It must not be a `172.x` Docker address or a Cloudflare address. If it is either, stop: this PR would put visitors into shared buckets.
2. **`config.domains` covers every host nginx proxies to Rails.** Run `docker compose -f docker-compose.prod.yml exec web bin/rails runner 'puts Rails.application.config.domains.values'`. The output must include `thegreatestmusic.org`, `thegreatest.games` and `new.thegreatestbooks.org`. nginx redirects the `www.` names itself, so they never reach Rails. A proxied host missing from the output gets 403 after this deploys.

## After deploy

- Run `deployment/scripts/verify-origin-lockdown.sh`.
- All three sites load. `https://new.thegreatestbooks.org/api/v1/openapi.json` returns 200.
- `docker compose -f docker-compose.prod.yml ps web` shows healthy.
- `docker compose -f docker-compose.prod.yml logs --no-log-prefix --since 10m web | grep -c 'Blocked hosts'` prints 0.
- Rollback: revert the PR on GitHub and let the deploy run.

---

### Task 1: `visitor_ip` is `request.remote_ip`

**Files:**
- Modify: `web-app/app/controllers/concerns/visitor_ip.rb` (whole file)
- Modify (comments only): `web-app/app/controllers/list_submissions_controller.rb:36-38`, `web-app/app/controllers/auth_controller.rb:29-31`, `web-app/app/controllers/corrections_controller.rb:41-43`, `web-app/app/controllers/contact_messages_controller.rb:24-25`, `web-app/app/controllers/membership_controller.rb:195-196`, `web-app/app/controllers/my/ranking_configurations_controller.rb:22-25`, `web-app/app/models/correction.rb:41-44`
- Modify: `docs/features/list-submissions.md:101-106` and `:242`
- Test: `web-app/test/controllers/concerns/visitor_ip_test.rb` (whole file), `web-app/test/controllers/auth_controller_test.rb:276-307`, `web-app/test/controllers/membership_controller_test.rb:361-371`, `web-app/test/controllers/corrections_controller_test.rb:212-218, 287-316`, `web-app/test/controllers/list_submissions_controller_test.rb:150-215`, `web-app/test/controllers/api/v1/books/books_controller_test.rb:389-401`, `web-app/test/controllers/api/v1/openapi_controller_test.rb:70-93`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `VisitorIp#visitor_ip` (private) → `String`, equal to `request.remote_ip`. Every call site is unchanged.

- [ ] **Step 1: Replace the `VisitorIp` test with one that runs Rails' real `RemoteIp` middleware**

Overwrite `web-app/test/controllers/concerns/visitor_ip_test.rb`:

```ruby
require "test_helper"

# visitor_ip is request.remote_ip, so what these pin is how Rails' RemoteIp
# middleware, with this app's own ip_spoofing_check and trusted_proxies,
# resolves the headers production actually delivers. REMOTE_ADDR is nginx's
# container on the Docker bridge. X-Forwarded-For is whatever arrived at nginx
# (anything the client sent, then the visitor Cloudflare appends) with nginx's
# $remote_addr -- the real_ip visitor -- appended last.
class VisitorIpTest < ActiveSupport::TestCase
  class Host
    include VisitorIp

    attr_reader :request

    def initialize(request) = @request = request

    public :visitor_ip
  end

  NGINX = "172.18.0.5"

  def visitor_ip_for(env)
    config = Rails.application.config.action_dispatch
    resolved = nil
    app = ->(rack_env) {
      resolved = Host.new(ActionDispatch::Request.new(rack_env)).visitor_ip
      [200, {}, []]
    }
    ActionDispatch::RemoteIp.new(app, config.ip_spoofing_check, config.trusted_proxies)
      .call(Rack::MockRequest.env_for("/", env))
    resolved
  end

  test "is the visitor nginx appended to X-Forwarded-For" do
    assert_equal "203.0.113.5",
      visitor_ip_for("REMOTE_ADDR" => NGINX, "HTTP_X_FORWARDED_FOR" => "203.0.113.5, 203.0.113.5")
  end

  test "ignores entries a client forged to the left of the visitor" do
    assert_equal "203.0.113.5",
      visitor_ip_for("REMOTE_ADDR" => NGINX, "HTTP_X_FORWARDED_FOR" => "198.51.100.66, 203.0.113.5, 203.0.113.5")
  end

  test "ignores a CF-Connecting-IP header" do
    assert_equal "203.0.113.5",
      visitor_ip_for("REMOTE_ADDR" => NGINX, "HTTP_X_FORWARDED_FOR" => "203.0.113.5, 203.0.113.5",
        "HTTP_CF_CONNECTING_IP" => "198.51.100.77")
  end

  test "handles an IPv6 visitor" do
    assert_equal "2001:db8::5",
      visitor_ip_for("REMOTE_ADDR" => NGINX, "HTTP_X_FORWARDED_FOR" => "2001:db8::5, 2001:db8::5")
  end

  test "is the peer itself when nothing forwarded the request" do
    assert_equal "127.0.0.1", visitor_ip_for("REMOTE_ADDR" => "127.0.0.1")
  end
end
```

- [ ] **Step 2: Run it and confirm the header test fails**

Run (from `web-app/`): `bin/rails test test/controllers/concerns/visitor_ip_test.rb`
Expected: 1 failure, in "ignores a CF-Connecting-IP header": `Expected: "203.0.113.5"  Actual: "198.51.100.77"`. The other four pass, because the current code falls back to `remote_ip` when the header is absent.

- [ ] **Step 3: Rewrite the concern**

Overwrite `web-app/app/controllers/concerns/visitor_ip.rb`:

```ruby
# frozen_string_literal: true

# The visitor's IP, for keying rate limits and recording who submitted what.
#
# It is request.remote_ip, which is the visitor only because of how the origin
# is wired (deployment/README.md, origin lockdown):
#   - nginx accepts connections only from Cloudflare's ranges, and its real_ip
#     module takes CF-Connecting-IP only from those ranges, so nginx's
#     $remote_addr is the visitor.
#   - nginx appends $remote_addr to X-Forwarded-For. Rails' RemoteIp walks that
#     header from the right, skipping trusted proxies (nginx's container has a
#     private Docker bridge address, which Rails trusts by default), so the
#     first untrusted entry is the visitor. Entries a client added further left
#     are never reached.
#   - The web container publishes no port, so nothing reaches Rails without
#     going through nginx. A request that did would be believed on its own
#     X-Forwarded-For.
#
# Never read CF-Connecting-IP here: Rails cannot tell whether Cloudflare or the
# client set it. nginx can, and has already folded it into $remote_addr.
#
# Every IP-keyed rate limit in this app goes through here.
module VisitorIp
  extend ActiveSupport::Concern

  private

  def visitor_ip
    request.remote_ip
  end
end
```

- [ ] **Step 4: Run the concern test**

Run: `bin/rails test test/controllers/concerns/visitor_ip_test.rb`
Expected: 5 runs, 0 failures.

- [ ] **Step 5: Run the controller suites to see which tests the change breaks**

Run: `bin/rails test test/controllers/auth_controller_test.rb test/controllers/membership_controller_test.rb test/controllers/corrections_controller_test.rb test/controllers/list_submissions_controller_test.rb test/controllers/api/v1/books/books_controller_test.rb test/controllers/api/v1/openapi_controller_test.rb`
Expected: failures in the tests that relied on `CF-Connecting-IP` choosing the bucket. These include the auth "keyed on CF-Connecting-IP" pair, membership "the donate rate limit keys on CF-Connecting-IP", corrections "records the Cloudflare connecting ip", list submissions "keyed on visitor ip", the API books 429 test and the openapi per-IP window test. Every one of them now sends all requests from `127.0.0.1`. Note which failed, then go on.

- [ ] **Step 6: Convert `auth_controller_test.rb`**

Replace lines 276–307 (the comment block and the two "keyed on CF-Connecting-IP" tests) with:

```ruby
  # A loop from a single integration-test session proves the limit trips, but
  # not that it is keyed correctly -- every request in this process comes from
  # 127.0.0.1 unless REMOTE_ADDR says otherwise, so a test like the two above
  # would pass identically against `by: -> { "constant" }`. Only two DIFFERENT
  # visitor ips can tell visitor_ip and a shared bucket apart: with by:
  # visitor_ip each gets its own bucket and the second visitor is unaffected;
  # with a shared key the second visitor's request would land in the first's
  # already-exhausted bucket.
  test "check_provider rate limit is keyed per visitor, not shared" do
    (AuthController::CHECK_PROVIDER_RATE + 1).times do
      post auth_check_provider_path, params: {email: "someone@example.com"},
        env: {"REMOTE_ADDR" => "203.0.113.5"}, as: :json
    end
    assert_response :too_many_requests

    post auth_check_provider_path, params: {email: "someone@example.com"},
      env: {"REMOTE_ADDR" => "203.0.113.9"}, as: :json

    assert_response :success
  end

  test "sign_in rate limit is keyed per visitor, not shared" do
    bad = FirebaseTokenHelper.token({"aud" => "other-project"})

    (AuthController::SIGN_IN_RATE + 1).times do
      post auth_sign_in_path, params: {jwt: bad}, env: {"REMOTE_ADDR" => "203.0.113.5"}, as: :json
    end
    assert_response :too_many_requests

    post auth_sign_in_path, params: {jwt: bad}, env: {"REMOTE_ADDR" => "203.0.113.9"}, as: :json

    assert_response :unauthorized
  end

  # The M1 audit finding: when visitor_ip trusted CF-Connecting-IP, a client
  # talking to the origin could send a new value with every request and never
  # fill a bucket. The header must now make no difference.
  test "rotating CF-Connecting-IP does not buy a fresh check_provider bucket" do
    AuthController::CHECK_PROVIDER_RATE.times do |i|
      post auth_check_provider_path, params: {email: "someone@example.com"},
        headers: {"CF-Connecting-IP" => "198.51.100.#{i + 1}"},
        env: {"REMOTE_ADDR" => "203.0.113.5"}, as: :json
    end

    post auth_check_provider_path, params: {email: "someone@example.com"},
      headers: {"CF-Connecting-IP" => "198.51.100.250"},
      env: {"REMOTE_ADDR" => "203.0.113.5"}, as: :json

    assert_response :too_many_requests
  end
```

- [ ] **Step 7: Convert `membership_controller_test.rb`**

Replace the test at lines 361–371 with:

```ruby
  test "the donate rate limit is keyed per visitor, not shared" do
    Stripe::Checkout::Session.stubs(:create).returns(stub(url: "https://checkout.stripe.com/c/pay/cs_donate"))

    11.times { post membership_donate_url, env: {"REMOTE_ADDR" => "203.0.113.5"} }
    assert_redirected_to membership_path
    # A different visitor must not inherit the first visitor's count.
    post membership_donate_url, env: {"REMOTE_ADDR" => "203.0.113.9"}

    assert_redirected_to "https://checkout.stripe.com/c/pay/cs_donate"
  end
```

`assert_redirected_to membership_path` proves the 11th request from the first visitor was throttled. The limit's `with:` redirects there.

- [ ] **Step 8: Convert `corrections_controller_test.rb` and port the two-IP shape**

Replace the test at lines 212–218 with:

```ruby
  test "records the visitor ip" do
    post corrections_path,
      params: {correctable_type: "Books::Book", correctable_id: @book.id, correction: {notes: "wrong"}},
      env: {"REMOTE_ADDR" => "198.51.100.4"}

    assert_equal "198.51.100.4", Correction.last.submitter_ip
  end
```

In "rate limits an anonymous submitter by ip and re-renders the form…" (around line 287) and "a signed-in submitter is not held to the anonymous cap" (around line 307), replace `headers: {"CF-Connecting-IP" => "198.51.100.9"}` with `env: {"REMOTE_ADDR" => "198.51.100.9"}`. Leave both tests otherwise unchanged.

Directly after the "rate limits an anonymous submitter by ip…" test, add:

```ruby
  # The test above loops from one address, so it passes whatever by: reads --
  # even a constant. Only a second address can show the bucket is per visitor.
  test "the anonymous rate limit is keyed per visitor, not shared" do
    Rails.application.config.x.rate_limit_store.clear

    (CorrectionsController::ANONYMOUS_RATE + 1).times do
      post corrections_path,
        params: {correctable_type: "Books::Book", correctable_id: @book.id, correction: {notes: "wrong"}},
        env: {"REMOTE_ADDR" => "198.51.100.9"}
    end
    assert_response :too_many_requests

    post corrections_path,
      params: {correctable_type: "Books::Book", correctable_id: @book.id, correction: {notes: "wrong"}},
      env: {"REMOTE_ADDR" => "203.0.113.5"}

    assert_redirected_to books_book_correction_thanks_path(slug: @book.slug)
  end
```

- [ ] **Step 9: Convert `list_submissions_controller_test.rb`**

Replace every `headers: {"CF-Connecting-IP" => "<ip>"}` in the file with `env: {"REMOTE_ADDR" => "<ip>"}`, keeping each IP. There are six, at about lines 153, 167, 171, 192, 198 and 211.

Replace the comment block and test name at about lines 177–189 with:

```ruby
  # Every request in this test process comes from 127.0.0.1 unless REMOTE_ADDR
  # says otherwise, so a single-submitter loop trips at the same iteration
  # count whatever by: reads -- even a constant. The only shape that can tell
  # a per-visitor bucket from a shared one is two DIFFERENT visitor ips: per
  # visitor, each gets its own bucket and both loops below succeed in full;
  # shared, the second visitor's requests land in the first's exhausted bucket
  # and the second loop's last request comes back rate limited instead of
  # redirecting.
  test "an anonymous rate limit is keyed per visitor, not shared" do
```

Keep the test body as it is apart from the `env:` conversion.

- [ ] **Step 10: Convert the two API tests**

In `test/controllers/api/v1/books/books_controller_test.rb` ("too many unauthenticated requests from one address is a 429 before any lookup"), replace the body inside `freeze_time do ... end` from `headers = bearer(...)` to the end with:

```ruby
            headers = bearer("tg_#{"z" * 40}")
            visitor = {"REMOTE_ADDR" => "203.0.113.7"}
            limit.times { get "/api/v1/books", headers: headers, env: visitor }

            assert_no_queries do
              get "/api/v1/books", headers: headers, env: visitor
            end
            assert_api_conform(status: 429)

            assert_response :too_many_requests
            assert_equal "rate_limited", json[:code]
            assert response.headers["Retry-After"].present?

            get "/api/v1/books", headers: headers, env: {"REMOTE_ADDR" => "203.0.113.8"}
            assert_response :unauthorized
```

Keep the comment above `headers =` (the one that begins "A well-formed but unknown token").

In `test/controllers/api/v1/openapi_controller_test.rb` ("the document is behind the per-IP unauthenticated window"), replace the three `headers: {"CF-Connecting-IP" => "<ip>"}` arguments with `env: {"REMOTE_ADDR" => "<ip>"}`, keeping `203.0.113.42` twice and `203.0.113.43` once.

- [ ] **Step 11: Confirm no test or app code still sets the client IP through the header**

Run (from the repo root): `grep -rn "CF-Connecting-IP" web-app/app web-app/test`
Expected: exactly these matches and no others:
- `web-app/app/controllers/concerns/visitor_ip.rb` (the comment)
- `web-app/test/controllers/concerns/visitor_ip_test.rb`
- `web-app/test/controllers/auth_controller_test.rb` (the comment, the rotating test name and its two header lines)

- [ ] **Step 12: Run the converted suites**

Run (from `web-app/`): `bin/rails test test/controllers/concerns/visitor_ip_test.rb test/controllers/auth_controller_test.rb test/controllers/membership_controller_test.rb test/controllers/corrections_controller_test.rb test/controllers/list_submissions_controller_test.rb test/controllers/contact_messages_controller_test.rb test/controllers/api/v1/books/books_controller_test.rb test/controllers/api/v1/openapi_controller_test.rb`
Expected: 0 failures, 0 errors.

- [ ] **Step 13: Mutation checks (record the results in the task report)**

Make each change below, run Step 12's command, record which tests fail, then restore with `git checkout -- app/controllers/concerns/visitor_ip.rb`.
1. Body becomes `request.headers["CF-Connecting-IP"].presence || request.remote_ip` (the old code). Expected failures: "ignores a CF-Connecting-IP header" and "rotating CF-Connecting-IP does not buy a fresh check_provider bucket".
2. Body becomes `"constant"`. Expected failures include at least: every "keyed per visitor, not shared" test (auth ×2, membership, corrections, list submissions), the API books 429 test, the openapi window test, and all five `VisitorIp` tests.

If any expected failure does not happen, that test is vacuous. Stop and report it. Do not weaken the expectation.

- [ ] **Step 14: Rewrite the stale comments**

`app/controllers/list_submissions_controller.rb`, replace:
```ruby
  # by: goes through visitor_ip, NEVER request.remote_ip -- in production that is
  # the Cloudflare edge IP, so keying on it puts every visitor in one bucket and
  # throttles the whole site.
```
with:
```ruby
  # by: goes through visitor_ip (the VisitorIp concern), like every IP-keyed
  # limit, so they all agree on who the visitor is.
```

`app/controllers/auth_controller.rb`, replace:
```ruby
  # by: goes through visitor_ip, never request.remote_ip -- in production
  # remote_ip is the Cloudflare edge IP, so keying on it would put every visitor
  # in one bucket and lock out the whole site.
```
with:
```ruby
  # by: goes through visitor_ip (the VisitorIp concern), like every IP-keyed
  # limit, so they all agree on who the visitor is.
```

`app/controllers/corrections_controller.rb`, replace:
```ruby
  # by: goes through visitor_ip, NOT request.remote_ip -- see the VisitorIp
  # concern. remote_ip in production is the Cloudflare edge IP, so keying on it
  # would put every visitor into one bucket and lock out the whole site.
```
with:
```ruby
  # by: goes through visitor_ip (the VisitorIp concern), like every IP-keyed
  # limit, so they all agree on who the visitor is.
```

`app/controllers/contact_messages_controller.rb`, replace:
```ruby
  # by: goes through visitor_ip, NEVER request.remote_ip, which in production is
  # the Cloudflare edge IP and would put every visitor in one bucket.
```
with:
```ruby
  # by: goes through visitor_ip (the VisitorIp concern), like every IP-keyed
  # limit, so they all agree on who the visitor is.
```

`app/controllers/membership_controller.rb`, replace:
```ruby
  # visitor_ip comes from the VisitorIp concern -- see it for why remote_ip alone
  # is wrong behind Cloudflare.
```
with:
```ruby
  # visitor_ip comes from the VisitorIp concern.
```

`app/controllers/my/ranking_configurations_controller.rb`, replace:
```ruby
  # filters above so a click during a run is rejected before it counts, and
  # keyed by user id, never request.remote_ip (the Cloudflare edge IP). with:
  # is required: Rails' default raises and renders an HTML error body.
```
with:
```ruby
  # filters above so a click during a run is rejected before it counts, and
  # keyed by user id, since the action requires sign-in. with: is required:
  # Rails' default raises and renders an HTML error body.
```

`app/models/correction.rb`, replace:
```ruby
  # /suggest-correction is an anonymous POST anyone can make, its rate limit keys
  # on visitor_ip which the origin will believe from a spoofed CF-Connecting-IP
  # if a request ever reaches it off-edge, and this repo ships no Rack or nginx
  # body limit. Without these, one request stores an arbitrarily large blob per
  # field and an arbitrarily long array.
```
with:
```ruby
  # /suggest-correction is an anonymous POST anyone can make, its rate limit is
  # per visitor IP (so anyone with many addresses has many budgets), and this
  # repo ships no Rack or nginx body limit. Without these, one request stores an
  # arbitrarily large blob per field and an arbitrarily long array.
```

`docs/features/list-submissions.md`, replace the paragraph text from "`` `by: visitor_ip`, never `request.remote_ip` `` — in production" through "(local dev, direct health\nchecks). " with:

```markdown
`by: visitor_ip` (`app/controllers/concerns/visitor_ip.rb`), which is `request.remote_ip`. That
is the visitor only because nginx sets its `$remote_addr` from `CF-Connecting-IP` for
connections from Cloudflare's ranges and refuses every other connection (origin lockdown,
`deployment/README.md`). Rails never reads `CF-Connecting-IP` itself.
```

Keep the sentence that follows ("Both `rate_limit` calls are declared with `store:` …") as it is, starting on the next line.

In the same file's file table, replace the `visitor_ip.rb` row's description `` `CF-Connecting-IP`-first IP resolution, shared by every IP-keyed rate limit `` with `the visitor's IP (request.remote_ip behind nginx's real_ip), shared by every IP-keyed rate limit`.

- [ ] **Step 15: Lint and run the full suite**

Run (from `web-app/`): `bundle exec standardrb` then `bin/rails test`
Expected: standardrb clean; the suite has 0 failures, 0 errors, and no new warning lines.

- [ ] **Step 16: Commit**

```bash
git add web-app/app/controllers web-app/app/models/correction.rb web-app/test/controllers docs/features/list-submissions.md
git commit -m "Key IP rate limits on request.remote_ip, not CF-Connecting-IP

Origin lockdown made nginx's \$remote_addr the visitor, and Rails' RemoteIp
resolves it from the X-Forwarded-For nginx appends to. CF-Connecting-IP
could be set by anyone who reached the origin, so a client could rotate it
to escape every IP-keyed limit (audit M1). Rate-limit tests now pick the
client with REMOTE_ADDR and use the two-address shape; corrections gains
the per-visitor test it lacked.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Production admits only the hosts in `config.domains`

**Files:**
- Create: `web-app/config/host_allowlist.rb`
- Create: `web-app/config/initializers/host_authorization.rb`
- Modify: `web-app/config/environments/production.rb:84-91`
- Modify (comments only): `web-app/app/controllers/concerns/current_domain.rb:8-10`, `web-app/app/lib/api/host.rb:3-6`
- Test: `web-app/test/config/host_allowlist_test.rb`

**Interfaces:**
- Consumes: `Rails.application.config.domains`, a `Hash` of `Symbol => String`. Each value may be a comma-separated list of hosts (set in `config/initializers/domain_config.rb`).
- Produces: `HostAllowlist.hosts(domains) → Array<String>`, which raises `ArgumentError` when the result is empty. `HostAllowlist.authorization → Hash`, the `config.host_authorization` options.

Background the implementer needs:
- An empty `config.hosts` does not block everything. It leaves `ActionDispatch::HostAuthorization` out of the middleware stack entirely (verified: in `test` it is absent from `Rails.application.middleware`). That is why an empty allowlist must fail at boot.
- `HostAuthorization` checks `Host` and, when present, `X-Forwarded-Host`; both must be allowed. A request with no `Host` header at all gets 403. nginx always sends one.
- `config/initializers` cannot autoload reloadable constants from `app/` or `lib/`. So the helper is a plain file under `config/`, required by path, like `config/test_database_name.rb`.
- Initializers load in alphabetical order, so `host_authorization.rb` runs after `domain_config.rb`. `production.rb` runs before every initializer, which is why the code cannot live there.

- [ ] **Step 1: Write the failing test**

Create `web-app/test/config/host_allowlist_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require Rails.root.join("config/host_allowlist").to_s

# config.hosts is set only in production (config/initializers/host_authorization.rb),
# so no integration test ever runs behind it. These run the real
# ActionDispatch::HostAuthorization middleware with exactly what that
# initializer hands it.
class HostAllowlistTest < ActiveSupport::TestCase
  DOMAINS = {
    music: "music.example",
    games: "games.example,www.games.example",
    books: "books.example"
  }.freeze

  def status_for(host, path = "/", headers = {}, domains: DOMAINS)
    app = ->(_env) { [200, {}, ["ok"]] }
    middleware = ActionDispatch::HostAuthorization.new(app, HostAllowlist.hosts(domains), **HostAllowlist.authorization)
    middleware.call(Rack::MockRequest.env_for(path, {"HTTP_HOST" => host}.merge(headers))).first
  end

  test "admits every configured host, including each entry of a comma-separated value" do
    %w[music.example games.example www.games.example books.example].each do |host|
      assert_equal 200, status_for(host), host
    end
  end

  test "admits the hosts this environment's routes serve" do
    %w[dev.thegreatestmusic.org dev.thegreatest.games dev-new.thegreatestbooks.org].each do |host|
      assert_equal 200, status_for(host, domains: Rails.application.config.domains), host
    end
  end

  test "refuses an unknown host" do
    assert_equal 403, status_for("evil.example")
  end

  test "a forged X-Forwarded-Host is refused even behind a configured Host" do
    assert_equal 403, status_for("music.example", "/", {"HTTP_X_FORWARDED_HOST" => "evil.example"})
  end

  # docker-compose.prod.yml's healthcheck curls http://localhost:3000/up.
  test "the health check is admitted from any host" do
    assert_equal 200, status_for("localhost:3000", "/up")
  end

  test "only /up itself is exempt" do
    assert_equal 403, status_for("evil.example", "/upload")
    assert_equal 403, status_for("evil.example", "/up/anything")
  end

  test "refuses a config.domains that yields no hosts" do
    assert_raises(ArgumentError) { HostAllowlist.hosts({music: "", books: ""}) }
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run (from `web-app/`): `bin/rails test test/config/host_allowlist_test.rb`
Expected: an error loading the file, `cannot load such file -- .../config/host_allowlist`.

- [ ] **Step 3: Write the helper**

Create `web-app/config/host_allowlist.rb`:

```ruby
# frozen_string_literal: true

# The hosts production admits (config.hosts) and the requests exempt from that
# check. Kept out of the initializer so test/config/host_allowlist_test.rb can
# run the real middleware with them: config.hosts is set only in production,
# so no integration test ever passes through it.
#
# Plain file, required by path: config/initializers cannot autoload reloadable
# constants from app/ or lib/.
module HostAllowlist
  # config.domains is the same source config/routes.rb constrains on, and each
  # value may be a comma-separated list (see DomainConstraint), so every host
  # the routes serve is admitted and nothing has to be kept in sync by hand.
  def self.hosts(domains)
    hosts = domains.values.flat_map { |value| value.split(",") }.uniq
    # An empty config.hosts switches the check off rather than refusing
    # everything, so fail at boot instead.
    raise ArgumentError, "config.domains yields no hosts" if hosts.empty?
    hosts
  end

  # /up is the container healthcheck (docker-compose.prod.yml), which curls
  # localhost:3000 directly rather than through nginx.
  def self.authorization
    {exclude: ->(request) { request.path == "/up" }}
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bin/rails test test/config/host_allowlist_test.rb`
Expected: 7 runs, 0 failures.

- [ ] **Step 5: Wire it into production**

Create `web-app/config/initializers/host_authorization.rb`:

```ruby
# frozen_string_literal: true

require Rails.root.join("config/host_allowlist").to_s

# Production only. Not in production.rb: environment files run before
# config/initializers, and config.domains is set by domain_config.rb, which
# sorts before this file. development.rb keeps its own list; test sets none.
if Rails.env.production?
  Rails.application.configure do
    config.hosts.concat(HostAllowlist.hosts(config.domains))
    config.host_authorization = HostAllowlist.authorization
  end
end
```

In `web-app/config/environments/production.rb`, replace:

```ruby
  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
```

with:

```ruby
  # config.hosts is set in config/initializers/host_authorization.rb: it is
  # built from config.domains, which does not exist yet when this file runs.
```

- [ ] **Step 6: Prove production boots with the check switched on**

Run (from `web-app/`). The `STORAGE_*` values are dummies that only let the production storage config load:

```bash
STORAGE_BUCKET=x STORAGE_ENDPOINT=https://example.invalid STORAGE_ACCESS_KEY_ID=x STORAGE_SECRET_ACCESS_KEY=x SECRET_KEY_BASE_DUMMY=1 RAILS_ENV=production bin/rails middleware | grep HostAuthorization
```

Expected: `use ActionDispatch::HostAuthorization`. On `main` this prints nothing.

```bash
STORAGE_BUCKET=x STORAGE_ENDPOINT=https://example.invalid STORAGE_ACCESS_KEY_ID=x STORAGE_SECRET_ACCESS_KEY=x SECRET_KEY_BASE_DUMMY=1 RAILS_ENV=production bin/rails runner 'p Rails.application.config.hosts'
```

Expected: a non-empty array of the `config.domains` hosts in your shell's environment (the `dev.` defaults unless `*_DOMAIN` is set). On `main` it prints `[]`.

Two warnings about SendGrid and Stripe not being set are expected; ignore them.

Mutation check: temporarily change `if Rails.env.production?` to `if false`, rerun the first command and confirm it prints nothing, then restore. Record both outputs in the task report.

- [ ] **Step 7: Update the two comments that say `config.hosts` is unset**

`app/controllers/concerns/current_domain.rb`, replace:

```ruby
# Unrecognised hosts fall back to :books. In production config.hosts is unset,
# so request.host is client-supplied -- nothing here should ever be used to
# build a URL (see Api::Host and the routes file for the canonical source).
```

with:

```ruby
# Unrecognised hosts fall back to :books. Production's config.hosts admits only
# config.domains, but request.host is still the client's choice among them --
# nothing here should ever be used to build a URL (see Api::Host and the
# routes file for the canonical source).
```

`app/lib/api/host.rb`, replace:

```ruby
# The canonical absolute origin for the current site. Every URL the API emits
# is built from here, never from request.host: in production config.hosts is
# unset and nginx forwards the raw Host header, so request.host is whatever the
# client sent. config.domains is the same source config/routes.rb constrains on.
```

with:

```ruby
# The canonical absolute origin for the current site. Every URL the API emits
# is built from here, never from request.host, which is only as trustworthy as
# nginx and config.hosts make it. config.domains is the same source
# config/routes.rb constrains on.
```

- [ ] **Step 8: Lint, full suite, eager-load check**

Run (from `web-app/`): `bundle exec standardrb`, then `bin/rails test`, then `CI=1 bin/rails zeitwerk:check`
Expected: standardrb clean. The suite has 0 failures and no new warnings. zeitwerk prints `All is good!`, because `config/` is not autoloaded and `HostAllowlist` must not show up as an unexpected constant.

- [ ] **Step 9: Commit**

```bash
git add web-app/config/host_allowlist.rb web-app/config/initializers/host_authorization.rb web-app/config/environments/production.rb web-app/test/config/host_allowlist_test.rb web-app/app/controllers/concerns/current_domain.rb web-app/app/lib/api/host.rb
git commit -m "Admit only config.domains hosts in production

config.hosts was unset, so Rails accepted any Host. Build it from
config.domains, the source the routes already constrain on, in an
initializer that runs after domain_config.rb. /up stays exempt for the
container healthcheck, and an empty list fails at boot because an empty
config.hosts disables the check (audit L2).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: nginx forwards `Host $host`

**Files:**
- Modify: `deployment/nginx/snippets/proxy-params.conf:1`
- Modify: `deployment/nginx/test/local-lockdown-test.sh` (the stub upstream, and new probes B9/B10 placed after B7 and before B8)
- Modify: `docs/features/membership-billing.md:467-472`, `docs/guides/stripe-account-setup.md:589-599`

**Interfaces:**
- Consumes: Task 1's premise that the rightmost `X-Forwarded-For` entry Rails receives is the real_ip visitor. B10 checks that premise. Task 2's `config/initializers/host_authorization.rb`, which the docs now cite.
- Produces: nothing code depends on.

Background: the harness's stub upstream is stock `nginx:alpine`, which cannot show what nginx forwarded. It becomes an echo server. Every existing probe checks only status codes, and the echo answers 200 just as the stock page did. The harness talks to nginx on port 18443, so curl sends `Host: thegreatestmusic.org:18443`. With `$http_host` that port reaches the upstream; with `$host` it does not.

- [ ] **Step 1: Make the stub upstream echo what it received**

In `deployment/nginx/test/local-lockdown-test.sh`, replace:

```bash
docker run -d --name "$upstream" --network "$net" --network-alias web nginx:alpine >/dev/null
```

with:

```bash
# The stub upstream echoes the headers nginx forwards, so B9/B10 can check them.
cat > "$work/upstream.conf" <<'EOF'
server {
    listen 80 default_server;
    default_type text/plain;
    return 200 "host=$http_host xfh=$http_x_forwarded_host xff=$http_x_forwarded_for\n";
}
EOF
docker run -d --name "$upstream" --network "$net" --network-alias web \
  -v "$work/upstream.conf:/etc/nginx/conf.d/default.conf:ro" nginx:alpine >/dev/null
```

- [ ] **Step 2: Add the failing probes**

Insert directly after the `B7` line and before the `# B8:` comment:

```bash
# B9/B10: what Rails receives. curl talks to port $https_port, so its Host header carries
# ":$https_port"; Rails must see the bare server name. X-Forwarded-For must end with the
# real_ip visitor -- the entry Rails' RemoteIp settles on (web-app VisitorIp) -- even when
# the client forged one in front of it.
echo_body=$(curl -sk --max-time 10 --cert "$work/client.pem" --key "$work/client.key" \
  --resolve "$music:$https_port:127.0.0.1" -H "CF-Connecting-IP: 203.0.113.9" \
  -H "X-Forwarded-For: 198.51.100.66" "https://$music:$https_port/")
if [[ "$echo_body" == "host=$music xfh=$music "* ]]; then pass "B9 upstream Host and X-Forwarded-Host are the bare server name"
else fail "B9 upstream Host and X-Forwarded-Host are the bare server name" "got [$echo_body]"; fi
if [[ "$echo_body" == *" xff=198.51.100.66, 203.0.113.9" ]]; then pass "B10 X-Forwarded-For ends with the real_ip visitor"
else fail "B10 X-Forwarded-For ends with the real_ip visitor" "got [$echo_body]"; fi
```

Run (from the repo root): `deployment/nginx/test/local-lockdown-test.sh`
Expected: B9 FAILS with `got [host=thegreatestmusic.org:18443 xfh=thegreatestmusic.org xff=198.51.100.66, 203.0.113.9]`. B10 and every other probe pass. The script ends `1 lockdown probe(s) failed`.

- [ ] **Step 3: Change the proxy header**

In `deployment/nginx/snippets/proxy-params.conf`, replace the first line:

```nginx
proxy_set_header Host $http_host;
```

with:

```nginx
# $host is the matched server name without any client-supplied :port (Rails also
# admits only config.domains; see web-app/config/initializers/host_authorization.rb).
proxy_set_header Host $host;
```

- [ ] **Step 4: Run the harness**

Run: `deployment/nginx/test/local-lockdown-test.sh`
Expected: every probe A1–A8 and B1–B10 passes (B8 is B8a/B8b), ending `all lockdown probes passed`.

- [ ] **Step 5: Mutation check on B10 (record in the task report)**

Temporarily change `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;` in `proxy-params.conf` to `proxy_set_header X-Forwarded-For $http_x_forwarded_for;`. Rerun the harness and confirm B10 fails (the visitor is no longer appended). Restore the line, rerun, and confirm everything passes.

- [ ] **Step 6: Update the two docs that say `Host` is forwarded raw and `config.hosts` is unset**

`docs/features/membership-billing.md`, replace:

```markdown
`MembershipController` reads `Rails.application.config.domains[Current.domain]` instead, because
nginx forwards the client's raw `Host` header verbatim and `config.hosts` is unset in production —
see `docs/guides/stripe-account-setup.md`'s "Ops follow-ups" for why that's still worth fixing
separately. A forged `Host` header cannot make this app mint a real Stripe-branded checkout link
pointing anywhere but a real site.
```

with:

```markdown
`MembershipController` reads `Rails.application.config.domains[Current.domain]` instead. nginx
now forwards `Host $host` and production's `config.hosts` admits only `config.domains`
(`config/initializers/host_authorization.rb`), but this path does not depend on either: a forged
`Host` header cannot make this app mint a real Stripe-branded checkout link pointing anywhere but
a real site.
```

`docs/guides/stripe-account-setup.md`, replace the whole bullet that begins `- **Set `config.hosts` in `web-app/config/environments/production.rb`.**` and ends `there's just no code path in this branch that strictly requires it.` with:

```markdown
- **Set `config.hosts` in production.** Done. `web-app/config/initializers/host_authorization.rb`
  admits exactly the hosts in `config.domains`, with `/up` exempt for the container healthcheck,
  and nginx forwards `proxy_set_header Host $host;`, so a client-supplied port no longer reaches
  Rails. `MembershipController#canonical_host` still builds Stripe URLs from `config.domains`.
```

Leave the section's intro sentence ("Two gaps surfaced…") as it is. With both bullets marked Done, it reads as history.

- [ ] **Step 7: Run the Rails suite once more**

Run (from `web-app/`): `bin/rails test`
Expected: 0 failures. Nothing in Rails changed in this task; this confirms the branch as a whole.

- [ ] **Step 8: Commit**

```bash
git add deployment/nginx/snippets/proxy-params.conf deployment/nginx/test/local-lockdown-test.sh docs/features/membership-billing.md docs/guides/stripe-account-setup.md
git commit -m "nginx: forward Host \$host so a client :port never reaches Rails

\$http_host passed the client's Host through verbatim, port included.
\$host is the matched server name. The lockdown harness's stub upstream
now echoes what it receives: B9 checks Host, and B10 checks that
X-Forwarded-For ends with the real_ip visitor, the entry Rails keys rate
limits on.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
