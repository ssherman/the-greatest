# Public API Increment 3: Developer Pages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the two member-facing pages of the public API: `/developers` (public documentation, edge-cached, rendered from the OpenAPI contract) and `/developers/tokens` (members mint and revoke tokens, secret shown once), plus the links in (a `/members` card and a footer entry), a second Playwright account that is a member, and the E2E coverage.

**Architecture:** Two controllers in the shape of `PagesController` (docs) and `MembersController` (tokens): global routes constrained to the three real hosts, per-domain layout via `DomainLayout`. The docs page reads `Api::OpenapiDocument.for_host` so the endpoint reference cannot drift from the contract and never reads `current_user`, because it is served from the Cloudflare cache. The tokens page is behind `MembershipGate[:api]` (already registered), never cached, and its writes answer with Turbo Streams in both outcomes so the secret exists in exactly one response body. Nothing in the API stack (`app/lib/api`, `app/lib/services/api`, `Api::V1::*`) changes.

**Tech Stack:** Rails 8.1, Turbo Streams, daisyUI 5 on Tailwind 4, existing `clipboard-copy` Stimulus controller, Minitest + fixtures + Mocha, Playwright.

**Spec:** `docs/superpowers/specs/2026-09-12-public-api-framework-design.md`, section 8 (the pages), D14, Testing (UI and E2E bullets). Increment 1 shipped as PR #309/#310, increment 2 as PR #311; `docs/features/public-api.md` describes what exists.

## Global Constraints

- Run every Rails command from `web-app/`. Docs live in `docs/` at the project root.
- **Use Rails generators** for the two controllers (`bin/rails generate controller`), then replace the generated test bodies with the ones in this plan. Never hand-create a controller file.
- **No header nav item** for the API (spec D14, Shane's call). The links in are the `/members` card and the footer only.
- `/developers` renders **identical HTML for every visitor**: it must not read `current_user`, and a test compares the page body signed out and signed in.
- `/developers/tokens` is `require_membership!(:api)` and `prevent_caching`. The feature key `:api` is already in `MembershipGate::FEATURES`; do not add a second entry.
- The secret appears in **one Turbo Stream response body** and nowhere else: never in a URL, the flash, the list, or a re-render.
- Public layouts render **no flash**. Every message lives in the page (`/membership` renders its own flash region, which is where the gate redirects land).
- Every input has a real `<label>` or `aria-label`. A `fieldset-legend` does not label an input; when a label is styled as the legend, use `form.label ... class: "fieldset-legend"` with an explicit `for:` (the contact form's pattern).
- daisyUI 5: no `form-control`, `label-text`, `input-bordered`, `select-bordered`, `table-hover`, `tabs-boxed`. `test/lint/daisyui_v4_classes_test.rb` fails on any of them.
- Any `data-controller` referenced from `app/views/developers/**` must be registered in `app/javascript/manifests/web_shared.js` (non-domain views). `clipboard-copy` already is; this plan adds no new controller.
- Feedback never leans on colour alone (Shane is red-green colour blind): the once-only warning carries words and an icon; alerts carry a "Problem:" word.
- Public copy follows `.claude/skills/avoid-ai-writing/SKILL.md`: **zero em dashes** (`—`, `&mdash;`, and the `--` substitute) in prose, at most one bolded phrase per section, no "it's not X, it's Y", no rule-of-three padding. Prose spans only; never rewrite ERB tags or markup under that skill.
- Controller tests assert behaviour (status, headers, records, structural ids, `href`s), never copy, CSS classes or layout.
- Minitest 6: `assert_nil`, never `assert_equal nil, x`. Auth in integration tests is `sign_in_as(user, stub_auth: true)`.
- The development database is shared with other worktrees and is not disposable. Nothing in this increment migrates; `bin/rails db:migrate` is not needed.
- Before claiming done: `bin/rails test`, `bundle exec standardrb`, `CI=1 bin/rails zeitwerk:check`; a clean run adds no warning line beyond the two known yarn `package-lock.json` lines.
- Commit after every task on the worktree branch (`worktree-public-api-developers`). Never commit to `main`, never push or open a PR without Shane saying so.

## File structure

| File | Responsibility |
|---|---|
| `web-app/config/routes.rb` | `/developers` and `/developers/tokens` inside a three-host `DomainConstraint` block |
| `web-app/app/controllers/developers_controller.rb` | `GET /developers`: cacheable, indexable, builds the operation list from the host's OpenAPI document |
| `web-app/app/views/developers/show.html.erb` | The documentation page |
| `web-app/app/controllers/developers/tokens_controller.rb` | `GET/POST /developers/tokens`, `DELETE /developers/tokens/:id`; membership-gated; Turbo Streams |
| `web-app/app/views/developers/tokens/index.html.erb` | Page shell: intro, list, new-token region, form |
| `web-app/app/views/developers/tokens/_list.html.erb` | `#developers_tokens`: the member's tokens with a revoke button per row |
| `web-app/app/views/developers/tokens/_form.html.erb` | `#developers_token_form`: create form, or the cap notice |
| `web-app/app/views/developers/tokens/_secret.html.erb` | The once-only secret panel |
| `web-app/app/views/developers/tokens/create.turbo_stream.erb` | Success: fill `#developers_new_token`, refresh list and form. Failure: form with errors |
| `web-app/app/views/developers/tokens/destroy.turbo_stream.erb` | Refresh list and form |
| `web-app/app/views/members/show.html.erb` | The API card |
| `web-app/app/components/footer_component.rb` | The "API" site link |
| `web-app/lib/tasks/e2e.rake` | `e2e:member` grants the Playwright member account a comp |
| `web-app/e2e/.env.example`, `e2e/auth/books-member-auth.setup.ts`, `e2e/playwright.config.ts` | The second (member) E2E account |
| `web-app/e2e/tests/books/developers.spec.ts`, `books/account/developers.spec.ts`, `books/member/developers-tokens.spec.ts` | Anonymous, signed-in non-member, and member coverage |
| `docs/features/public-api.md`, `docs/features/e2e-testing.md` | Feature docs |

Tests mirror `app/`: `test/controllers/developers_controller_test.rb`, `test/controllers/developers/tokens_controller_test.rb`, additions to `test/components/footer_component_test.rb` and `test/controllers/members_controller_test.rb`.

## Fixtures you will lean on (already present; check `test/fixtures/*.yml` before adding any)

- `users(:regular_user)`: member (Stripe, `regular_user_monthly`), owns three `api_tokens` (`regular_user_token`, `regular_user_music_only_token`, `regular_user_expired_token`).
- `users(:editor_user)`: comped member (`editor_user_comped`, never expires), owns **no** tokens. Use it for create/cap tests.
- `users(:books_viewer_user)`: **non-member**, owns `api_tokens(:non_member_token)`.
- `users(:user_with_expired_comp)`: comp expired.
- `users(:admin_user)`: `MembersControllerTest` destroys its memberships to make a signed-in non-member.
- `Rails.application.config.x.api.max_tokens_per_user` is 10.
- Hosts: `Rails.application.config.domains[:books]` etc. may be comma-separated; `PagesControllerTest#host_for` takes the first. Themes stamped on `<html data-theme>`: books `books`, music `light`, games `abyss`.

---

### Task 1: Routes and the `/developers` documentation page

**Files:**
- Modify: `web-app/config/routes.rb` (after the `api/v1/openapi` block, around line 477)
- Create: `web-app/app/controllers/developers_controller.rb` (generator)
- Create: `web-app/app/views/developers/show.html.erb`
- Test: `web-app/test/controllers/developers_controller_test.rb`

**Interfaces:**
- Consumes: `Api::OpenapiDocument.for_host(base_url, domain:)` → Hash with `"paths"`; `Api::OpenapiDocument::DOMAIN_KEY` (`"x-domain"`); `Api::Host.base_url(domain = Current.domain)`; `Api::Problem::DEFINITIONS` (`code => [status, title]`) and `Api::Problem::CODES`; `Rails.application.config.x.api.rate_limits` (`{member: {per_minute:, per_day:}, system: {...}}`) and `.unauthenticated_per_minute`; `Cacheable#cache_for_show_page`; `DomainLayout#resolve_layout`; `DomainHelper#domain_name`.
- Produces: route helpers `developers_path` (`/developers`), `developers_tokens_path` (`/developers/tokens`), `developers_token_path(token)` (`/developers/tokens/:id`). Page anchors `#quick-start`, `#authentication`, `#rate-limits`, `#endpoints`, `#pagination`, `#errors`, `#versioning`; one `id="endpoint-<operationId>"` per operation; one `id="errors-<code>"` per `Api::Problem` code (these are the targets of `Api::Problem#to_h[:type]`). `DevelopersController::Operation` struct (`method, path, operation_id, summary, description, parameters, statuses, public`).

- [ ] **Step 1: Add the routes**

In `web-app/config/routes.rb`, directly after the block that ends with `get "api/v1/openapi", ...` and its closing `end` (around line 476), add:

```ruby
  # The public API's two pages. /developers is documentation: identical for
  # every visitor, edge-cached like the policy pages, and it lists only the
  # endpoints THIS host serves (Api::OpenapiDocument.for_host). /developers/tokens
  # is where a member mints and revokes tokens: members only, never cached, and
  # its writes answer in Turbo Streams (Developers::TokensController). Global
  # routes with a per-domain layout, domain-constrained like /news for the same
  # reason. No header nav item (spec D14): the links in are the footer and the
  # /members card.
  constraints DomainConstraint.new(
    [:books, :music, :games].map { |domain| Rails.application.config.domains[domain] }.join(",")
  ) do
    get "developers", to: "developers#show", as: :developers, constraints: {format: /html/}
    namespace :developers do
      resources :tokens, only: [:index, :create, :destroy]
    end
  end
```

- [ ] **Step 2: Generate the controller**

```bash
cd web-app
bin/rails generate controller Developers show --skip-routes --no-helper --no-assets
```

Expected: creates `app/controllers/developers_controller.rb`, `app/views/developers/show.html.erb`, `test/controllers/developers_controller_test.rb`. If it also creates `app/helpers/developers_helper.rb`, delete it (`rm app/helpers/developers_helper.rb`).

- [ ] **Step 3: Write the failing tests**

Replace the whole of `web-app/test/controllers/developers_controller_test.rb` with:

```ruby
require "test_helper"

class DevelopersControllerTest < ActionDispatch::IntegrationTest
  # Each site's layout, keyed by the theme it stamps on <html> -- the same
  # signal pages_controller_test uses to prove DomainLayout resolved.
  SITES = {
    books: "books",
    music: "light",
    games: "abyss"
  }.freeze

  def host_for(domain)
    Rails.application.config.domains[domain].to_s.split(",").first
  end

  SITES.each do |domain, theme|
    test "renders in the #{domain} layout on the #{domain} host" do
      host! host_for(domain)

      get developers_path

      assert_response :success
      assert_select "html[data-theme=#{theme}]"
    end
  end

  test "is edge-cacheable for a day" do
    host! host_for(:books)

    get developers_path

    assert_includes response.headers["Cache-Control"], "public"
    assert_includes response.headers["Cache-Control"], "max-age=86400"
  end

  # The page is served from the Cloudflare cache, so one per-visitor byte in it
  # is served to everyone. Compare the content this controller owns rather than
  # the whole body: the layout's csrf meta tag legitimately differs per session.
  test "renders identical content signed out and signed in" do
    host! host_for(:books)

    get developers_path
    signed_out = css_select("article#developers").to_s

    sign_in_as(users(:regular_user), stub_auth: true)
    get developers_path
    signed_in = css_select("article#developers").to_s

    assert_equal signed_out, signed_in
    refute_includes signed_in, users(:regular_user).email
  end

  test "documents the endpoints this host serves and only those" do
    host! host_for(:books)
    get developers_path
    assert_select "[id=?]", "endpoint-listBooks"
    assert_select "[id=?]", "endpoint-getBook"
    assert_select "[id=?]", "endpoint-listAuthors"
    assert_select "[id=?]", "endpoint-getAuthor"
    assert_select "[id=?]", "endpoint-getOpenapi"

    host! host_for(:music)
    get developers_path
    assert_select "[id=?]", "endpoint-getOpenapi"
    assert_select "[id=?]", "endpoint-listBooks", count: 0
    assert_select "[id=?]", "endpoint-listAuthors", count: 0
  end

  # Api::Problem#to_h points `type` at <host>/developers#errors-<code>. A code
  # without an anchor here is a dangling type URI on every error the API sends.
  test "has an anchor for every problem code" do
    host! host_for(:books)

    get developers_path

    Api::Problem::CODES.each do |code|
      assert_select "[id=?]", "errors-#{code}", 1
    end
  end

  test "links to the contract, the membership page and the token page" do
    host! host_for(:books)

    get developers_path

    assert_select "article#developers a[href=?]", "/api/v1/openapi.json"
    assert_select "article#developers a[href=?]", membership_path
    assert_select "article#developers a[href=?]", developers_tokens_path
  end

  test "the rate-limit table reads the configured limits" do
    host! host_for(:books)

    get developers_path

    limits = Rails.application.config.x.api.rate_limits
    assert_select "table#rate-limits-table td", text: limits.dig(:member, :per_minute).to_s
    assert_select "table#rate-limits-table td", text: limits.dig(:member, :per_day).to_s
    assert_select "table#rate-limits-table td", text: limits.dig(:system, :per_day).to_s
  end

  test "an unrepresentable format is a 404, not a 406" do
    host! host_for(:books)

    get "/developers.json"

    assert_response :not_found
  end
end
```

`dom_id` is available in `ActionDispatch::IntegrationTest`, and `assert_select` reaches inside a `<turbo-stream><template>` under the HTML5 parser this suite uses (both verified 2026-09-16 with a probe test in this worktree).

- [ ] **Step 4: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/developers_controller_test.rb`
Expected: failures/errors (the controller has no `Operation`, the view is the generator's placeholder, so `endpoint-*` and `errors-*` selectors fail).

- [ ] **Step 5: Write the controller**

Replace `web-app/app/controllers/developers_controller.rb` with:

```ruby
# frozen_string_literal: true

# GET /developers -- the public API's documentation.
#
# Global route with a per-domain layout (PagesController's shape). Edge-cached
# for a day: the page renders the same bytes for every visitor. Nothing here
# reads current_user, and DevelopersControllerTest proves the content is
# identical signed in and out, because one per-visitor byte on a cached page
# is served to everyone.
#
# The endpoint reference is built from the OpenAPI document for THIS host, so
# it cannot drift from the contract and the music host never documents
# /api/v1/books. Api::Problem#to_h points its `type` URI at this page's
# #errors-<code> anchors; the test pins every code to one.
class DevelopersController < ApplicationController
  include Cacheable
  include DomainLayout

  layout :resolve_layout

  before_action :cache_for_show_page
  before_action :mark_indexable

  Operation = Struct.new(:method, :path, :operation_id, :summary, :description, :parameters, :statuses, :public, keyword_init: true)

  def show
    @base_url = Api::Host.base_url
    @document = Api::OpenapiDocument.for_host(@base_url, domain: Current.domain)
    @operations = operations_for(@document)
    @rate_limits = Rails.application.config.x.api.rate_limits
    @unauthenticated_per_minute = Rails.application.config.x.api.unauthenticated_per_minute
    @example_url = example_url
  end

  private

  # See PagesController#mark_indexable: the three sites' robots helpers have
  # opposite defaults, so a public page must say so explicitly.
  def mark_indexable
    @indexable = true
  end

  # One row per (method, path). `$ref` parameters are named by the last path
  # segment of the reference (#/components/parameters/page -> "page").
  def operations_for(document)
    document.fetch("paths").flat_map do |path, item|
      item.except(Api::OpenapiDocument::DOMAIN_KEY).map do |method, operation|
        Operation.new(
          method: method.upcase,
          path: path,
          operation_id: operation.fetch("operationId"),
          summary: operation["summary"],
          description: operation["description"],
          parameters: Array(operation["parameters"]).map { |parameter| parameter["$ref"]&.split("/")&.last || parameter["name"] },
          statuses: operation.fetch("responses").keys,
          public: operation["security"] == []
        )
      end
    end
  end

  # The quick-start example calls the first authenticated endpoint on this
  # host. A site with none yet (music and games until their resources ship)
  # shows the books call, which the same token works on.
  def example_url
    first = @operations.find { |operation| !operation.public }
    return "#{@base_url}#{first.path}" if first

    "#{Api::Host.base_url(:books)}/api/v1/books"
  end
end
```

- [ ] **Step 6: Write the view**

Replace `web-app/app/views/developers/show.html.erb` with:

```erb
<%
  content_for :page_title, "API | #{domain_name}"
  content_for :meta_description, "Read The Greatest's rankings from your own scripts and apps. Documentation for the #{domain_name} API: tokens, rate limits, endpoints and errors."
%>

<%# Identical HTML for every visitor: this page is served from the Cloudflare
    edge cache. Never read current_user here. The endpoint list comes from the
    OpenAPI document for this host, so it cannot say something the contract
    does not. Anchors: the section ids below, endpoint-<operationId> per row,
    and errors-<code> per problem code (Api::Problem#to_h links to those). %>
<article id="developers" class="max-w-3xl mx-auto px-4 py-10">
  <div class="prose max-w-none">
    <h1>The <%= domain_name %> API</h1>

    <p>
      Read the rankings on this site from your own scripts and apps. Every request
      is JSON, every list comes back in rank order, and the same token works on
      The Greatest Books, The Greatest Music and The Greatest Games.
    </p>
    <p>
      Tokens are a benefit of <%= link_to "membership", membership_path %>. Members
      create and revoke them at <%= link_to "/developers/tokens", developers_tokens_path %>.
      Reading this page needs nothing.
    </p>

    <h2 id="quick-start">Quick start</h2>
    <p>Put your token in an environment variable and send it as a bearer token:</p>
<pre><code>export THE_GREATEST_TOKEN=tg_your_token_here
curl -H "Authorization: Bearer $THE_GREATEST_TOKEN" \
  "<%= @example_url %>?per_page=5"</code></pre>
    <p>The same call in Python:</p>
<pre><code>import os
import requests

token = os.environ["THE_GREATEST_TOKEN"]
response = requests.get(
    "<%= @example_url %>",
    headers={"Authorization": f"Bearer {token}"},
    params={"per_page": 5},
)
response.raise_for_status()
for item in response.json()["data"]:
    print(item["rank"], item["url"])</code></pre>

    <h2 id="authentication">Authentication</h2>
    <p>
      A token looks like <code>tg_</code> followed by 40 letters and digits. It is
      shown once, when you create it. We store only a hash, so nobody can read it
      back later, including us. If you lose one, revoke it and create another.
    </p>
    <ul>
      <li>Send it on every request as <code>Authorization: Bearer &lt;token&gt;</code>.</li>
      <li>Keep it out of code and out of version control. An environment variable is the usual place.</li>
      <li>A token works on all three sites. Its scopes decide which: <code>books:read</code>, <code>music:read</code>, <code>games:read</code>.</li>
      <li>If a token leaks, revoke it at <%= link_to "/developers/tokens", developers_tokens_path %>. Anything using it gets a 401 from that moment.</li>
      <li>A token cannot sign in to the site and cannot write anything.</li>
    </ul>

    <h2 id="rate-limits">Rate limits</h2>
    <p>
      Limits apply to your account, not to each token, so creating more tokens
      does not create more quota. Two windows run at once: a minute and a UTC day.
    </p>
    <div class="not-prose overflow-x-auto">
      <table id="rate-limits-table" class="table">
        <thead>
          <tr><th>Account</th><th>Per minute</th><th>Per day (UTC)</th></tr>
        </thead>
        <tbody>
          <tr>
            <td>Member</td>
            <td><%= @rate_limits.dig(:member, :per_minute) %></td>
            <td><%= @rate_limits.dig(:member, :per_day) %></td>
          </tr>
          <tr>
            <td>Service account</td>
            <td><%= @rate_limits.dig(:system, :per_minute) %></td>
            <td><%= @rate_limits.dig(:system, :per_day) %></td>
          </tr>
        </tbody>
      </table>
    </div>
    <p>
      Every authenticated response carries six headers. The first three describe
      the minute window, the last three the day:
    </p>
    <ul>
      <li><code>X-RateLimit-Limit</code>, <code>X-RateLimit-Remaining</code>, <code>X-RateLimit-Reset</code> (Unix time the minute window resets)</li>
      <li><code>X-RateLimit-Daily-Limit</code>, <code>X-RateLimit-Daily-Remaining</code>, <code>X-RateLimit-Daily-Reset</code></li>
    </ul>
    <p>
      When either window is exhausted the response is <code>429</code> with a
      <code>Retry-After</code> header in seconds. Requests without a valid token are
      limited separately, <%= @unauthenticated_per_minute %> per minute per IP address.
    </p>

    <h2 id="endpoints">Endpoints on this site</h2>
    <p>
      The contract is an OpenAPI 3.1 document at
      <%= link_to "/api/v1/openapi.json", "/api/v1/openapi.json" %>, with
      <code>servers</code> set to this host and only the paths this host serves.
      Generate a client from it, or read the summary below.
    </p>
    <% if @operations.none? { |operation| !operation.public } %>
      <p>
        No ranked catalogue is on the API for this site yet. The Greatest Books
        went first; the same token works there, and this list grows as each
        site's resources ship.
      </p>
    <% end %>
    <div class="not-prose">
      <dl class="space-y-6">
        <% @operations.each do |operation| %>
          <div id="endpoint-<%= operation.operation_id %>">
            <dt class="font-mono">
              <span class="badge badge-neutral"><%= operation.method %></span>
              <code><%= operation.path %></code>
              <% if operation.public %>
                <span class="badge badge-ghost">no token needed</span>
              <% end %>
            </dt>
            <dd class="mt-1">
              <p class="font-semibold"><%= operation.summary %></p>
              <% if operation.description.present? %>
                <p><%= operation.description %></p>
              <% end %>
              <p class="text-sm text-base-content/70">
                <% if operation.parameters.any? %>
                  Query parameters:
                  <% operation.parameters.each_with_index do |name, index| %><%= ", " if index.positive? %><code><%= name %></code><% end %>.
                <% end %>
                Responses: <%= operation.statuses.join(", ") %>.
              </p>
            </dd>
          </div>
        <% end %>
      </dl>
    </div>

    <h2 id="pagination">Pagination</h2>
    <p>
      Collections take <code>page</code> (from 1) and <code>per_page</code> (1 to
      100, default 50). The response wraps the rows in <code>data</code> and adds
      <code>meta</code> (<code>page</code>, <code>per_page</code>,
      <code>total_count</code>, <code>total_pages</code>) and <code>links</code>
      (<code>self</code>, <code>next</code>, <code>prev</code>; absent ones are
      <code>null</code>). A page past the end is an empty <code>200</code>.
    </p>

    <h2 id="errors">Errors</h2>
    <p>
      Errors are <a href="https://www.rfc-editor.org/rfc/rfc9457">RFC 9457</a>
      problem documents (<code>application/problem+json</code>) with a stable
      <code>code</code> to switch on. <code>401</code> and <code>403</code> responses
      also carry a <code>WWW-Authenticate: Bearer</code> challenge.
    </p>
    <div class="not-prose overflow-x-auto">
      <table id="errors-table" class="table">
        <thead>
          <tr><th>Status</th><th><code>code</code></th><th>When</th></tr>
        </thead>
        <tbody>
          <%
            # One line per Api::Problem code. The table is driven by the
            # registry so a new code without a row here fails the anchor test
            # rather than shipping a dangling type URI.
            reasons = {
              unauthenticated: "No Authorization header was sent.",
              invalid_token: "The token is malformed, unknown, revoked or expired.",
              membership_required: "The token's owner has no active membership.",
              insufficient_scope: "The token lacks the scope this endpoint needs; the WWW-Authenticate header names it.",
              not_found: "Nothing on this site has that slug.",
              invalid_parameter: "A query parameter is out of range; detail says which.",
              rate_limited: "A rate-limit window is exhausted; Retry-After says how long to wait."
            }
          %>
          <% Api::Problem::DEFINITIONS.each do |code, (status, _title)| %>
            <tr id="errors-<%= code %>">
              <td><%= status %></td>
              <td><code><%= code %></code></td>
              <td><%= reasons.fetch(code) %></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>

    <h2 id="versioning">Versioning</h2>
    <p>
      This is version 1 and it only grows. Fields are added; none is renamed,
      removed or retyped. If a change ever needs to break that promise it will be
      a new version at a new path, and <code>/api/v1/</code> will keep working.
    </p>
  </div>
</article>
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/developers_controller_test.rb test/lint`
Expected: all pass, including the daisyUI and Stimulus manifest lints.

- [ ] **Step 8: Copy pass**

Read `.claude/skills/avoid-ai-writing/SKILL.md` and check every prose span in `show.html.erb` against it: no em dash in any form (`grep -nE '—|&mdash;| -- ' app/views/developers/show.html.erb` must print nothing), at most one bolded phrase per section, no "it's not X, it's Y". Edit prose spans only; ids, ERB tags and markup stay as written. Re-run the controller test afterwards.

- [ ] **Step 9: Lint and commit**

```bash
bundle exec standardrb app/controllers/developers_controller.rb test/controllers/developers_controller_test.rb
git add config/routes.rb app/controllers/developers_controller.rb app/views/developers/show.html.erb test/controllers/developers_controller_test.rb
git commit -m "feat(developers): /developers documents the API from this host's OpenAPI contract"
```

If the generator created `app/helpers/developers_helper.rb`, confirm it is deleted before committing (`git status`).

---

### Task 2: `/developers/tokens` index behind the membership gate

**Files:**
- Create: `web-app/app/controllers/developers/tokens_controller.rb` (generator)
- Create: `web-app/app/views/developers/tokens/index.html.erb`, `_list.html.erb`, `_form.html.erb`
- Test: `web-app/test/controllers/developers/tokens_controller_test.rb`

**Interfaces:**
- Consumes: routes from Task 1 (`developers_tokens_path`, `developers_token_path(token)`, `developers_path`); `MembershipGated#require_membership!(:api)`; `Cacheable#prevent_caching`; `DomainLayout`; `ApiToken` (`name`, `token_prefix`, `scopes`, `created_at`, `last_used_at`, `expires_at`); `User#api_tokens`; `Api::Scopes.mintable_by(user)`, `Api::Scopes.description(scope)`; `Rails.application.config.x.api.max_tokens_per_user`.
- Produces: `Developers::TokensController` with `EXPIRY_DAYS = [30, 90, 365].freeze`; partials `developers/tokens/list` (local `tokens:`; root `id="developers_tokens"`), `developers/tokens/form` (locals `tokens:`, optional `errors:`, `name_value:`, `scopes_value:`, `expires_in_value:`; root `id="developers_token_form"`); an empty `<div id="developers_new_token">` on the index page for Task 3 to fill; form params `api_token[name]`, `api_token[scopes][]`, `api_token[expires_in]`; `data-testid`s `token-cap-reached`, `token-form-error`, revoke buttons labelled `Revoke <name>`.

- [ ] **Step 1: Generate the controller**

```bash
bin/rails generate controller Developers::Tokens index create destroy --skip-routes --no-helper --no-assets
rm app/views/developers/tokens/create.html.erb app/views/developers/tokens/destroy.html.erb
```

Expected: `app/controllers/developers/tokens_controller.rb`, `app/views/developers/tokens/index.html.erb`, `test/controllers/developers/tokens_controller_test.rb`. Delete a generated `app/helpers/developers/tokens_helper.rb` if one appears. The two HTML views for create/destroy are removed because those actions answer only in Turbo Streams (Task 3).

- [ ] **Step 2: Write the failing tests for index and the gate**

Replace `web-app/test/controllers/developers/tokens_controller_test.rb` with:

```ruby
require "test_helper"

module Developers
  class TokensControllerTest < ActionDispatch::IntegrationTest
    TURBO = {"Accept" => "text/vnd.turbo-stream.html, text/html"}.freeze

    setup { host! Rails.application.config.domains[:books].to_s.split(",").first }

    def cap = Rails.application.config.x.api.max_tokens_per_user

    # --- index and the gate -------------------------------------------------

    test "a member sees the page" do
      sign_in_as(users(:regular_user), stub_auth: true)

      get developers_tokens_path

      assert_response :success
    end

    test "a comped member sees the page" do
      sign_in_as(users(:editor_user), stub_auth: true)

      get developers_tokens_path

      assert_response :success
    end

    test "a signed-in non-member is redirected to the membership page" do
      sign_in_as(users(:books_viewer_user), stub_auth: true)

      get developers_tokens_path

      assert_redirected_to membership_path
      assert_equal "That page is for members. Membership covers every site.", flash[:alert]
    end

    test "a signed-out visitor is redirected to the membership page" do
      get developers_tokens_path

      assert_redirected_to membership_path
      assert_equal "Sign in to your membership to open that page.", flash[:alert]
    end

    test "a member whose comp has expired is redirected" do
      sign_in_as(users(:user_with_expired_comp), stub_auth: true)

      get developers_tokens_path

      assert_redirected_to membership_path
    end

    test "the page is never cached" do
      sign_in_as(users(:regular_user), stub_auth: true)

      get developers_tokens_path

      assert_includes response.headers["Cache-Control"], "no-store"
    end

    test "lists only the signed-in member's tokens" do
      sign_in_as(users(:regular_user), stub_auth: true)

      get developers_tokens_path

      users(:regular_user).api_tokens.each do |token|
        assert_select "[id=?]", dom_id(token), 1
      end
      assert_select "[id=?]", dom_id(api_tokens(:non_member_token)), count: 0
    end

    test "each listed token has a revoke form and no secret" do
      sign_in_as(users(:regular_user), stub_auth: true)

      get developers_tokens_path

      users(:regular_user).api_tokens.each do |token|
        assert_select "form[action=?][method=post] input[name=_method][value=delete]", developers_token_path(token)
      end
      assert_no_match(/tg_[A-Za-z0-9]{40}/, response.body)
    end

    test "the create form offers exactly the member-mintable scopes and the four expiries" do
      sign_in_as(users(:editor_user), stub_auth: true)

      get developers_tokens_path

      assert_select "form[action=?]", developers_tokens_path do
        assert_select "input[name='api_token[name]']", 1
        Api::Scopes.mintable_by(users(:editor_user)).each do |scope|
          assert_select "input[type=checkbox][name='api_token[scopes][]'][value=?][checked]", scope, 1
        end
        assert_select "input[type=checkbox][name='api_token[scopes][]']", Api::Scopes.mintable_by(users(:editor_user)).size
        assert_select "select[name='api_token[expires_in]'] option", 4
        assert_select "select[name='api_token[expires_in]'] option[value='']", 1
        TokensController::EXPIRY_DAYS.each do |days|
          assert_select "select[name='api_token[expires_in]'] option[value=?]", days.to_s, 1
        end
      end
    end

    test "every form control has a label" do
      sign_in_as(users(:editor_user), stub_auth: true)

      get developers_tokens_path

      css_select("form[action='#{developers_tokens_path}'] input:not([type=hidden]):not([type=submit]), form[action='#{developers_tokens_path}'] select").each do |control|
        id = control["id"]
        assert id.present?, "control #{control["name"]} has no id"
        labelled = css_select("label[for='#{id}']").any? || control["aria-label"].present?
        assert labelled, "control ##{id} has neither a <label for> nor an aria-label"
      end
    end

    test "at the cap the form is replaced by a notice" do
      user = users(:editor_user)
      cap.times { |i| Services::Api::Tokens.generate(user: user, name: "t#{i}", scopes: ["books:read"]) }
      sign_in_as(user, stub_auth: true)

      get developers_tokens_path

      assert_response :success
      assert_select "form[action=?]", developers_tokens_path, count: 0
      assert_select "[data-testid=token-cap-reached]", 1
    end
  end
end
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/developers/tokens_controller_test.rb`
Expected: failures (generator placeholder view; no gate, so anonymous gets 200 instead of a redirect).

- [ ] **Step 4: Write the controller (index only for now; create/destroy bodies come in Task 3)**

Replace `web-app/app/controllers/developers/tokens_controller.rb` with:

```ruby
# frozen_string_literal: true

module Developers
  # /developers/tokens -- where a member mints and revokes API tokens.
  #
  # Members only (MembershipGate :api) and never cached: it is per-user by
  # definition. Global route with a per-domain layout, the MembersController
  # shape. The write actions answer with a Turbo Stream in BOTH outcomes:
  # Turbo Drive rejects a 200 HTML page as a form response, a redirect would
  # put the secret in a URL or the flash, and the public layouts render no
  # flash, so every message lives in the page. The secret exists in exactly one
  # response body (create's) and is never re-rendered.
  class TokensController < ApplicationController
    include Cacheable
    include DomainLayout
    include MembershipGated

    layout :resolve_layout

    before_action :prevent_caching
    before_action -> { require_membership!(:api) }

    # Days a token may live, as the form offers them; blank is "never". Any
    # other value is a tampered request and is refused rather than silently
    # made permanent, which would be the less safe reading.
    EXPIRY_DAYS = [30, 90, 365].freeze

    def index
      @tokens = tokens
    end

    def create
      head :not_implemented
    end

    def destroy
      head :not_implemented
    end

    private

    def tokens = current_user.api_tokens.order(:created_at, :id)
  end
end
```

- [ ] **Step 5: Write the index page and the two partials**

`web-app/app/views/developers/tokens/index.html.erb`:

```erb
<% content_for :page_title, "API tokens | #{domain_name}" %>

<div class="container mx-auto max-w-3xl px-4 py-10">
  <h1 class="text-3xl font-bold mb-2">API tokens</h1>
  <p class="text-base-content/70 mb-8">
    A token lets a script or an app read the rankings through the
    <%= link_to "API", developers_path, class: "link" %>. One token works on every
    site. Each is shown once, when you create it. If one leaks, revoke it here and
    create another.
  </p>

  <%= render "developers/tokens/list", tokens: @tokens %>

  <%# Filled by create.turbo_stream.erb with the once-only secret panel. Its own
      region, separate from the form, so a later revoke (which refreshes the
      form) can never wipe a secret the member has not copied yet. %>
  <div id="developers_new_token"></div>

  <%= render "developers/tokens/form", tokens: @tokens %>
</div>
```

`web-app/app/views/developers/tokens/_list.html.erb`:

```erb
<%# The member's tokens. Root id is the Turbo Stream target both write actions
    replace, so the empty state and the row set always agree with the database. %>
<section id="developers_tokens" class="mb-10">
  <h2 class="text-xl font-semibold mb-3">Your tokens</h2>
  <% if tokens.empty? %>
    <p class="text-base-content/70">You have no tokens yet.</p>
  <% else %>
    <div class="overflow-x-auto">
      <table class="table">
        <thead>
          <tr>
            <th>Name</th>
            <th>Token</th>
            <th>Scopes</th>
            <th>Created</th>
            <th>Last used</th>
            <th>Expires</th>
            <th><span class="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody>
          <% tokens.each do |token| %>
            <tr id="<%= dom_id(token) %>">
              <td><%= token.name %></td>
              <%# The stored display prefix. The secret itself is not in the
                  database and cannot appear here. %>
              <td><code><%= token.token_prefix %>…</code></td>
              <td><%= token.scopes.join(", ") %></td>
              <td><%= token.created_at.to_date.to_fs(:long) %></td>
              <td><%= token.last_used_at ? "#{time_ago_in_words(token.last_used_at)} ago" : "Never" %></td>
              <td><%= token.expires_at ? token.expires_at.to_date.to_fs(:long) : "Never" %></td>
              <td>
                <%= button_to "Revoke", developers_token_path(token),
                      method: :delete,
                      class: "btn btn-sm btn-outline",
                      "aria-label": "Revoke #{token.name}",
                      form: {data: {turbo_confirm: "Revoke #{token.name}? Anything using it stops working immediately."}} %>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
  <% end %>
</section>
```

`web-app/app/views/developers/tokens/_form.html.erb`:

```erb
<%# The create form, or the cap notice when the member cannot create another.
    Root id is the Turbo Stream target both write actions replace. The value
    locals are only ever passed by create.turbo_stream.erb after a failed
    submission, so what the member typed survives the error. %>
<section id="developers_token_form">
  <h2 class="text-xl font-semibold mb-3">Create a token</h2>
  <% cap = Rails.application.config.x.api.max_tokens_per_user %>
  <% if tokens.size >= cap %>
    <p class="text-base-content/70" data-testid="token-cap-reached">
      You have <%= cap %> tokens, the most one account can hold. Revoke one to create another.
    </p>
  <% else %>
    <% if local_assigns[:errors].present? %>
      <div class="alert alert-error mb-4" role="alert" data-testid="token-form-error">
        <span class="font-bold">Problem:</span>
        <span><%= errors.to_sentence %></span>
      </div>
    <% end %>

    <%= form_with url: developers_tokens_path, scope: :api_token, class: "space-y-4" do |form| %>
      <fieldset class="fieldset">
        <%# A label styled as the legend, with an explicit for: -- the contact
            form's pattern. A <legend> does not label an input. %>
        <%= form.label :name, "Name", for: "api_token_name", class: "fieldset-legend" %>
        <%= form.text_field :name,
              id: "api_token_name",
              required: true,
              maxlength: 60,
              autocomplete: "off",
              class: "input w-full",
              value: local_assigns[:name_value] %>
        <p class="label">Where it will be used, so you know which one to revoke later.</p>
      </fieldset>

      <fieldset class="fieldset">
        <legend class="fieldset-legend">Scopes</legend>
        <% Api::Scopes.mintable_by(current_user).each do |scope| %>
          <% checked = local_assigns[:scopes_value].nil? || scopes_value.include?(scope) %>
          <label class="label cursor-pointer justify-start gap-3" for="<%= "api_token_scope_#{scope.tr(":", "_")}" %>">
            <%= check_box_tag "api_token[scopes][]", scope, checked,
                  id: "api_token_scope_#{scope.tr(":", "_")}",
                  class: "checkbox" %>
            <span><code><%= scope %></code>: <%= Api::Scopes.description(scope) %></span>
          </label>
        <% end %>
      </fieldset>

      <fieldset class="fieldset">
        <%= form.label :expires_in, "Expires", for: "api_token_expires_in", class: "fieldset-legend" %>
        <%# Option values are STRINGS: options_for_select compares the selected
            value with Array#include?, and the re-rendered form passes back the
            posted string, so an integer 90 would never show as selected. %>
        <%= form.select :expires_in,
              [["Never", ""], ["In 30 days", "30"], ["In 90 days", "90"], ["In a year", "365"]],
              {selected: local_assigns[:expires_in_value]},
              id: "api_token_expires_in",
              class: "select w-full" %>
      </fieldset>

      <%= form.submit "Create token", class: "btn btn-primary" %>
    <% end %>
  <% end %>
</section>
```

The `Rails.application.config.x.api.max_tokens_per_user` read in the partial is the same constant `ApiToken#owner_is_under_the_cap` enforces, so the notice and the validation cannot disagree.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/developers/tokens_controller_test.rb test/lint`
Expected: all pass.

- [ ] **Step 7: Lint and commit**

```bash
bundle exec standardrb app/controllers/developers test/controllers/developers
git add app/controllers/developers app/views/developers/tokens test/controllers/developers
git commit -m "feat(developers): /developers/tokens lists a member's tokens behind the api membership gate"
```

---

### Task 3: Create and revoke tokens with Turbo Streams

**Files:**
- Modify: `web-app/app/controllers/developers/tokens_controller.rb`
- Create: `web-app/app/views/developers/tokens/_secret.html.erb`, `create.turbo_stream.erb`, `destroy.turbo_stream.erb`
- Test: `web-app/test/controllers/developers/tokens_controller_test.rb` (append)

**Interfaces:**
- Consumes: `Services::Api::Tokens.generate(user:, name:, scopes:, expires_at: nil)` → `Result(success?, data: {token:, secret:}, errors: [String])`; `Services::Api::Tokens.authenticate(secret)` (tests); the partials from Task 2; the `clipboard-copy` Stimulus controller (targets `source`, `button`; action `copy`).
- Produces: `POST /developers/tokens` → `200 text/vnd.turbo-stream.html` on success (`update #developers_new_token`, `replace #developers_tokens`, `replace #developers_token_form`), `422 text/vnd.turbo-stream.html` on failure (`replace #developers_token_form` with errors); `DELETE /developers/tokens/:id` → `200 text/vnd.turbo-stream.html` (`replace #developers_tokens`, `replace #developers_token_form`), 404 for a token the member does not own. `data-testid`s `new-token` (the panel) and `token-secret` (the readonly input holding the secret).

- [ ] **Step 1: Append the failing tests**

Add inside `module Developers; class TokensControllerTest`, after the index tests:

```ruby
    # --- create -----------------------------------------------------------------

    def create_token(params, user: users(:editor_user))
      sign_in_as(user, stub_auth: true)
      post developers_tokens_path, params: {api_token: params}, headers: TURBO
    end

    def secret_in_body = response.body[/tg_[A-Za-z0-9]{40}/]

    test "a member creates a token and the secret is in the stream exactly once" do
      assert_difference -> { users(:editor_user).api_tokens.count }, 1 do
        create_token(name: "laptop", scopes: ["books:read", "music:read"], expires_in: "")
      end

      assert_response :success
      assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
      assert_equal 1, response.body.scan(/tg_[A-Za-z0-9]{40}/).size
      token = Services::Api::Tokens.authenticate(secret_in_body)
      assert_equal users(:editor_user), token.user
      assert_equal "laptop", token.name
      assert_equal ["books:read", "music:read"], token.scopes
      assert_nil token.expires_at
      assert_select "turbo-stream[action=update][target=developers_new_token] [data-testid=token-secret][value=?]", secret_in_body
      assert_select "turbo-stream[action=replace][target=developers_tokens] [id=?]", dom_id(token)
      assert_select "turbo-stream[action=replace][target=developers_token_form] form[action=?]", developers_tokens_path
    end

    test "the secret is not in the list, a redirect or the flash" do
      create_token(name: "laptop", scopes: ["books:read"], expires_in: "")
      secret = secret_in_body

      assert_nil response.location
      assert_nil flash[:notice]
      assert_select "turbo-stream[target=developers_tokens]", text: /#{Regexp.escape(secret)}/, count: 0

      get developers_tokens_path
      assert_no_match(/#{Regexp.escape(secret)}/, response.body)
    end

    test "an expiry from the list sets expires_at" do
      freeze_time do
        create_token(name: "short", scopes: ["books:read"], expires_in: "30")

        assert_equal 30.days.from_now, Services::Api::Tokens.authenticate(secret_in_body).expires_at
      end
    end

    test "an expiry not on the list is refused" do
      assert_no_difference -> { ApiToken.count } do
        create_token(name: "tampered", scopes: ["books:read"], expires_in: "7")
      end

      assert_response :unprocessable_entity
      assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
      assert_select "turbo-stream[action=replace][target=developers_token_form] [data-testid=token-form-error]"
      assert_select "turbo-stream[target=developers_new_token]", count: 0
    end

    test "no scopes is a 422 that keeps what was typed" do
      assert_no_difference -> { ApiToken.count } do
        create_token(name: "nothing", expires_in: "90")
      end

      assert_response :unprocessable_entity
      assert_select "turbo-stream[target=developers_token_form] input[name='api_token[name]'][value=nothing]"
      assert_select "turbo-stream[target=developers_token_form] select[name='api_token[expires_in]'] option[value='90'][selected]"
      assert_select "turbo-stream[target=developers_token_form] input[type=checkbox][checked]", count: 0
    end

    test "a scope a member may not mint is a 422" do
      assert_no_difference -> { ApiToken.count } do
        create_token(name: "greedy", scopes: ["books:read", "books:admin"], expires_in: "")
      end

      assert_response :unprocessable_entity
    end

    test "a blank name is a 422" do
      assert_no_difference -> { ApiToken.count } do
        create_token(name: "   ", scopes: ["books:read"], expires_in: "")
      end

      assert_response :unprocessable_entity
    end

    test "the cap is enforced and the form becomes the notice" do
      user = users(:editor_user)
      (cap - 1).times { |i| Services::Api::Tokens.generate(user: user, name: "t#{i}", scopes: ["books:read"]) }

      create_token({name: "last", scopes: ["books:read"], expires_in: ""}, user: user)
      assert_response :success
      assert_select "turbo-stream[target=developers_token_form] [data-testid=token-cap-reached]"

      assert_no_difference -> { user.api_tokens.count } do
        post developers_tokens_path, params: {api_token: {name: "one too many", scopes: ["books:read"], expires_in: ""}}, headers: TURBO
      end
      assert_response :unprocessable_entity
    end

    test "a scalar api_token param is a 422, not a 500" do
      sign_in_as(users(:editor_user), stub_auth: true)

      post developers_tokens_path, params: {api_token: "junk"}, headers: TURBO

      assert_response :unprocessable_entity
    end

    test "create is never cached" do
      create_token(name: "laptop", scopes: ["books:read"], expires_in: "")

      assert_includes response.headers["Cache-Control"], "no-store"
    end

    test "a non-member cannot create a token" do
      assert_no_difference -> { ApiToken.count } do
        create_token({name: "nope", scopes: ["books:read"], expires_in: ""}, user: users(:books_viewer_user))
      end

      assert_redirected_to membership_path
    end

    test "a signed-out visitor cannot create a token" do
      assert_no_difference -> { ApiToken.count } do
        post developers_tokens_path, params: {api_token: {name: "nope", scopes: ["books:read"], expires_in: ""}}, headers: TURBO
      end

      assert_redirected_to membership_path
    end

    # --- destroy ---------------------------------------------------------------

    test "a member revokes their own token and the list refreshes" do
      sign_in_as(users(:regular_user), stub_auth: true)
      token = api_tokens(:regular_user_token)

      assert_difference -> { users(:regular_user).api_tokens.count }, -1 do
        delete developers_token_path(token), headers: TURBO
      end

      assert_response :success
      assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response.content_type
      assert_select "turbo-stream[action=replace][target=developers_tokens] [id=?]", dom_id(token), count: 0
      assert_select "turbo-stream[action=replace][target=developers_tokens] [id=?]", dom_id(api_tokens(:regular_user_music_only_token))
      assert_select "turbo-stream[action=replace][target=developers_token_form]"
      assert_select "turbo-stream[target=developers_new_token]", count: 0
      assert_nil Services::Api::Tokens.authenticate(ApiTokenSecrets::MEMBER)
    end

    test "revoking below the cap brings the form back" do
      user = users(:editor_user)
      made = cap.times.map { |i| Services::Api::Tokens.generate(user: user, name: "t#{i}", scopes: ["books:read"]).data[:token] }
      sign_in_as(user, stub_auth: true)

      delete developers_token_path(made.first), headers: TURBO

      assert_select "turbo-stream[target=developers_token_form] form[action=?]", developers_tokens_path
      assert_select "turbo-stream[target=developers_token_form] [data-testid=token-cap-reached]", count: 0
    end

    test "a member cannot revoke another account's token" do
      sign_in_as(users(:regular_user), stub_auth: true)

      assert_no_difference -> { ApiToken.count } do
        delete developers_token_path(api_tokens(:non_member_token)), headers: TURBO
      end

      assert_response :not_found
    end

    test "a signed-out visitor cannot revoke" do
      assert_no_difference -> { ApiToken.count } do
        delete developers_token_path(api_tokens(:regular_user_token)), headers: TURBO
      end

      assert_redirected_to membership_path
    end

    test "destroy is never cached" do
      sign_in_as(users(:regular_user), stub_auth: true)

      delete developers_token_path(api_tokens(:regular_user_token)), headers: TURBO

      assert_includes response.headers["Cache-Control"], "no-store"
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/developers/tokens_controller_test.rb`
Expected: the create/destroy tests fail with `501 Not Implemented`; the index tests still pass.

- [ ] **Step 3: Implement create and destroy**

In `web-app/app/controllers/developers/tokens_controller.rb`, replace everything from `def create` down to (and including) the existing `private` section's `def tokens` line with the block below, so the class tail reads exactly like this (the `index` action, `EXPIRY_DAYS`, includes, `layout` and both `before_action`s above it stay as Task 2 wrote them):

```ruby
    def create
      unless valid_expiry?(token_params[:expires_in])
        return render_form_again(errors: ["Choose an expiry from the list"])
      end

      result = Services::Api::Tokens.generate(
        user: current_user,
        name: token_params[:name].to_s.strip,
        scopes: Array(token_params[:scopes]).reject(&:blank?),
        expires_at: expires_at_from(token_params[:expires_in])
      )

      if result.success?
        @token = result.data[:token]
        @secret = result.data[:secret]
        @tokens = tokens
        render :create, formats: [:turbo_stream]
      else
        render_form_again(errors: result.errors)
      end
    end

    def destroy
      # Scoped through current_user: another account's id is a 404, never a
      # revoke. find (not find_by) so the missing case is Rails' 404.
      current_user.api_tokens.find(params[:id]).destroy!
      @tokens = tokens
      render :destroy, formats: [:turbo_stream]
    end

    private

    def tokens = current_user.api_tokens.order(:created_at, :id)

    # params[:api_token] is untrusted SHAPE as well as content: a hand-built
    # request can send it as a scalar, on which permit raises NoMethodError.
    # Fall back to empty permitted parameters, which fail validation the
    # ordinary way (ContactMessagesController#contact_params does the same).
    def token_params
      candidate = params[:api_token]
      return ActionController::Parameters.new.permit(:name, :expires_in, scopes: []) unless candidate.is_a?(ActionController::Parameters)

      candidate.permit(:name, :expires_in, scopes: [])
    end

    def valid_expiry?(value) = value.blank? || EXPIRY_DAYS.include?(Integer(value, exception: false))

    def expires_at_from(value) = value.blank? ? nil : Integer(value).days.from_now

    # Every failure lands here so what the member typed survives the error.
    # Safe to echo: this response is uncached (prevent_caching) and answers
    # exactly one request.
    def render_form_again(errors:)
      @errors = errors
      @tokens = tokens
      @name_value = token_params[:name]
      @scopes_value = Array(token_params[:scopes]).reject(&:blank?)
      @expires_in_value = token_params[:expires_in]
      render :create, formats: [:turbo_stream], status: :unprocessable_entity
    end
  end
end
```

The file must define `tokens` exactly once (in the block above); the Task 2 version of that line is what the block replaces.

- [ ] **Step 4: Write the secret panel and the two stream views**

`web-app/app/views/developers/tokens/_secret.html.erb`:

```erb
<%# The once-only secret. Rendered into #developers_new_token by
    create.turbo_stream.erb and by nothing else: this markup is the only place
    the secret ever appears. The warning is words plus an icon, never colour
    alone (the owner is red-green colour blind), and role=alert has it read
    out as soon as it lands. The icon is Lucide's triangle-alert, inlined the
    way FooterComponent inlines its brand marks, because the vendored icon set
    is deliberately small (app/assets/svg/icons/README.md). %>
<div class="card bg-base-200 mb-10" data-controller="clipboard-copy" data-testid="new-token">
  <div class="card-body">
    <h2 class="card-title text-xl">New token: <%= token.name %></h2>
    <p role="alert" class="flex items-start gap-2">
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" class="h-5 w-5 shrink-0 mt-0.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/>
        <path d="M12 9v4"/>
        <path d="M12 17h.01"/>
      </svg>
      <span>
        <span class="font-bold">Copy it now.</span> This is the only time it will be
        shown. If you lose it, revoke it and create another.
      </span>
    </p>
    <div class="flex flex-wrap items-center gap-2">
      <input type="text" readonly
             value="<%= secret %>"
             aria-label="Your new API token"
             class="input font-mono flex-1 min-w-0"
             data-clipboard-copy-target="source"
             data-testid="token-secret">
      <button type="button" class="btn btn-primary"
              data-action="clipboard-copy#copy"
              data-clipboard-copy-target="button">Copy</button>
    </div>
    <p class="text-sm text-base-content/70">
      Keep it in an environment variable, not in code, and send it as
      <code>Authorization: Bearer …</code>.
      <%= link_to "How to use it", developers_path(anchor: "quick-start"), class: "link" %>
    </p>
  </div>
</div>
```

`web-app/app/views/developers/tokens/create.turbo_stream.erb`:

```erb
<%# Both outcomes answer in a stream (see the controller comment). Success fills
    the new-token region, refreshes the list so the row appears, and refreshes
    the form so it is blank again, or the cap notice if this was the last slot.
    Failure swaps only the form, with the errors and what was typed. The secret
    is in the update for #developers_new_token and nowhere else in this body. %>
<% if @secret %>
  <%= turbo_stream.update "developers_new_token" do %>
    <%= render "developers/tokens/secret", token: @token, secret: @secret %>
  <% end %>
  <%= turbo_stream.replace "developers_tokens" do %>
    <%= render "developers/tokens/list", tokens: @tokens %>
  <% end %>
  <%= turbo_stream.replace "developers_token_form" do %>
    <%= render "developers/tokens/form", tokens: @tokens %>
  <% end %>
<% else %>
  <%= turbo_stream.replace "developers_token_form" do %>
    <%= render "developers/tokens/form",
          tokens: @tokens,
          errors: @errors,
          name_value: @name_value,
          scopes_value: @scopes_value,
          expires_in_value: @expires_in_value %>
  <% end %>
<% end %>
```

`web-app/app/views/developers/tokens/destroy.turbo_stream.erb`:

```erb
<%# Replace the list rather than remove one row, so the empty state appears
    when the last token goes; replace the form so a member who was at the cap
    gets it back. #developers_new_token is deliberately NOT touched: a revoke
    must never wipe a secret the member has not copied yet. %>
<%= turbo_stream.replace "developers_tokens" do %>
  <%= render "developers/tokens/list", tokens: @tokens %>
<% end %>
<%= turbo_stream.replace "developers_token_form" do %>
  <%= render "developers/tokens/form", tokens: @tokens %>
<% end %>
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/developers/tokens_controller_test.rb test/lint`
Expected: all pass.

If "a scalar api_token param is a 422" returns 500 instead, `token_params` is not being reached before `valid_expiry?`; it is, by construction, so check the `is_a?(ActionController::Parameters)` guard is intact. If "an expiry from the list sets expires_at" is off by microseconds, compare with `assert_in_delta 30.days.from_now.to_f, token.expires_at.to_f, 1`.

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/controllers/developers test/controllers/developers
git add app/controllers/developers app/views/developers/tokens test/controllers/developers
git commit -m "feat(developers): members mint and revoke API tokens; the secret lives in one Turbo Stream"
```

---

### Task 4: The links in: `/members` card and the footer entry

**Files:**
- Modify: `web-app/app/views/members/show.html.erb`
- Modify: `web-app/app/components/footer_component.rb` (`site_links`)
- Test: `web-app/test/controllers/members_controller_test.rb`, `web-app/test/components/footer_component_test.rb`

**Interfaces:**
- Consumes: `developers_path`, `developers_tokens_path` (Task 1).
- Produces: a footer "API" link under Site on all three domains; two links on `/members`.

- [ ] **Step 1: Write the failing tests**

Append to `web-app/test/controllers/members_controller_test.rb`, inside the class:

```ruby
  # The API is the first feature behind the paywall and this card is one of its
  # two links in (the footer is the other; there is no header nav item by design).
  test "the API card links to the token page and the docs" do
    sign_in_as(users(:regular_user), stub_auth: true)

    get members_url

    assert_select "a[href=?]", developers_tokens_path
    assert_select "a[href=?]", developers_path
  end
```

In `web-app/test/components/footer_component_test.rb`, inside the `DOMAINS.each do |domain|` block, after the "links to news and support" test, add:

```ruby
    test "#{domain} footer links to the API docs" do
      render_footer(domain)

      assert_selector "footer a[href='/developers']", text: "API"
    end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bin/rails test test/controllers/members_controller_test.rb test/components/footer_component_test.rb`
Expected: the four new tests fail (no such links yet).

- [ ] **Step 3: Add the footer link**

In `web-app/app/components/footer_component.rb`, change `site_links` to:

```ruby
  # Contact is NOT here. It is a button that opens the contact dialog, not a
  # link, so the template renders it separately -- see the Site column.
  # "API" is the public API's documentation; the footer and the /members card
  # are its only links in (spec D14: no header nav item).
  def site_links
    links = [["News", helpers.news_path]]
    links << ["Ranking Details", rankings_path] if rankings_path
    links << ["Support", helpers.membership_path]
    links << ["API", helpers.developers_path]
    links
  end
```

- [ ] **Step 4: Add the card to `/members`**

In `web-app/app/views/members/show.html.erb`, replace everything from `<h2 class="text-xl font-semibold mb-3">What's here</h2>` to the end of the file with:

```erb
  <h2 class="text-xl font-semibold mb-3">What's here</h2>

  <div class="card bg-base-200 mb-6">
    <div class="card-body">
      <h3 class="card-title text-lg">API access</h3>
      <p>
        Read the rankings from your own scripts and apps. Books and authors are
        on the API now; music and games follow as their resources ship. One token
        works on every site.
      </p>
      <div class="card-actions mt-2">
        <%= link_to "Manage tokens", developers_tokens_path, class: "btn btn-primary" %>
        <%= link_to "Read the docs", developers_path, class: "btn btn-ghost" %>
      </div>
    </div>
  </div>

  <p class="text-base-content/80">
    More lands here as it ships. The site has no ads, sells no data and has no
    investors, and members are the reason that can stay true.
  </p>
</div>
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bin/rails test test/controllers/members_controller_test.rb test/components/footer_component_test.rb test/controllers/pages_controller_test.rb`
Expected: all pass (`pages_controller_test` renders the footer on every site, so it proves the new helper call resolves on each host).

- [ ] **Step 6: Lint and commit**

```bash
bundle exec standardrb app/components/footer_component.rb test/components/footer_component_test.rb test/controllers/members_controller_test.rb
git add app/components/footer_component.rb app/views/members/show.html.erb test/components/footer_component_test.rb test/controllers/members_controller_test.rb
git commit -m "feat(developers): link the API from the /members card and every site's footer"
```

---

### Task 5: A member account for Playwright, and the E2E specs

Shane's decision (2026-09-16): a **second** E2E account that is a member, rather than comping the existing one. `e2e/tests/books/account/membership.spec.ts` depends on `PLAYWRIGHT_ADMIN_EMAIL` staying a non-member and says so; leave it that way.

**Shane's part (needs to happen once, before the specs can run):** create an email/password user in the Firebase project for the member account and put its credentials in `web-app/e2e/.env` as `PLAYWRIGHT_MEMBER_EMAIL` and `PLAYWRIGHT_MEMBER_PASSWORD`, then sign in once through the browser on `dev-new.thegreatestbooks.org` so the Rails `User` row exists, then `bin/rails e2e:member`. The implementer writes everything below without those credentials and does not run the member project; the anonymous and account projects can be run locally if port 3000 is free (see AGENTS.md).

**Files:**
- Modify: `web-app/lib/tasks/e2e.rake`
- Modify: `web-app/e2e/.env.example`, `web-app/e2e/playwright.config.ts`
- Create: `web-app/e2e/auth/books-member-auth.setup.ts`
- Create: `web-app/e2e/tests/books/developers.spec.ts`, `web-app/e2e/tests/books/account/developers.spec.ts`, `web-app/e2e/tests/books/member/developers-tokens.spec.ts`
- Modify: `docs/features/e2e-testing.md`

**Interfaces:**
- Consumes: `Membership` (`source: :comped`, `status: :active`, `current_period_end: nil`, `note`), the `(user_id, source)` index that makes `find_or_initialize_by(source: :comped)` idempotent; `MembershipGated`'s two redirect messages; `data-testid`s from Tasks 2 and 3 (`token-secret`, `new-token`), revoke buttons labelled `Revoke <name>`; `GET /api/v1/books` (401 with `WWW-Authenticate: Bearer error="invalid_token"` for an unknown well-formed token; 200 with `X-RateLimit-Limit: 60` for a member).
- Produces: rake `e2e:member`; Playwright projects `books-member-setup` and `books-member` (specs under `e2e/tests/books/member/`); `e2e/.auth/books-member.json`.

- [ ] **Step 1: Generalise the env reader and add `e2e:member`**

In `web-app/lib/tasks/e2e.rake`, replace the `playwright_email` method with:

```ruby
  # One value from e2e/.env. Read from the file rather than ENV because these
  # tasks run from a shell that has not loaded that file, and dotenv only loads
  # web-app/.env.
  def playwright_env(key)
    env_file = Rails.root.join("e2e", ".env")
    abort "Missing #{env_file}. Copy e2e/.env.example and fill it in." unless File.exist?(env_file)

    value = File.readlines(env_file)
      .grep(/\A#{key}=/)
      .first
      &.split("=", 2)
      &.last
      &.strip
      &.delete_prefix('"')
      &.delete_suffix('"')

    abort "#{key} not set in #{env_file}" if value.blank?
    value
  end

  def playwright_email = playwright_env("PLAYWRIGHT_ADMIN_EMAIL")
```

Then add, after the `admin` task:

```ruby
  desc "Grant the Playwright member account (e2e/.env PLAYWRIGHT_MEMBER_EMAIL) a comped membership"
  task member: :environment do
    email = playwright_env("PLAYWRIGHT_MEMBER_EMAIL")
    user = User.find_by(email: email)

    if user.nil?
      abort <<~MSG
        No User with email #{email}.

        The account must exist in Firebase AND in this database. Sign in once through
        the browser as that account to create the Rails User record, then re-run this task.
      MSG
    end

    # find_or_initialize_by on (user, source): the index on those two columns
    # makes this idempotent, so re-running after a dev-database refresh is safe.
    # A comp with no end date grants access until someone deactivates it.
    membership = user.memberships.find_or_initialize_by(source: :comped)
    membership.assign_attributes(status: :active, current_period_end: nil, note: "Playwright member account (bin/rails e2e:member)")
    membership.save!

    puts "#{email} (id #{user.id}) is a comped member."
  end
```

Check it loads: `bin/rails -T e2e` lists `e2e:member`.

- [ ] **Step 2: The second account in the env example and Playwright config**

Append to `web-app/e2e/.env.example`:

```
PLAYWRIGHT_MEMBER_EMAIL=your-member-test-account@example.com
PLAYWRIGHT_MEMBER_PASSWORD="your-password-here"
```

Create `web-app/e2e/auth/books-member-auth.setup.ts`:

```ts
import { test as setup, expect } from '@playwright/test';
import path from 'path';

// The MEMBER account. PLAYWRIGHT_ADMIN_EMAIL is deliberately a non-member
// (e2e/tests/books/account/membership.spec.ts depends on it), so members-only
// pages get their own account, comped by `bin/rails e2e:member`.
const authFile = path.join(__dirname, '..', '.auth', 'books-member.json');

setup.use({ baseURL: 'https://dev-new.thegreatestbooks.org' });

setup('authenticate as the member on books domain', async ({ page }) => {
  await page.goto('/');

  await page.getByRole('button', { name: 'Login' }).click();

  const modal = page.locator('#login_modal');
  await expect(modal).toBeVisible();

  await modal.getByPlaceholder('Email address').first().fill(process.env.PLAYWRIGHT_MEMBER_EMAIL!);
  await modal.getByRole('button', { name: 'Continue' }).click();

  const passwordInput = modal.getByPlaceholder('Password');
  await expect(passwordInput).toBeVisible();
  await passwordInput.fill(process.env.PLAYWRIGHT_MEMBER_PASSWORD!);
  await modal.getByRole('button', { name: 'Sign In' }).click();

  // Same wait as books-auth.setup.ts: the Rails session cookie is set by the
  // JWT exchange that follows the Firebase sign-in, not by the click itself.
  await page.waitForLoadState('networkidle');
  await page.waitForTimeout(3000);

  await page.context().storageState({ path: authFile });
});
```

In `web-app/e2e/playwright.config.ts`:

1. After `const booksAuthFile = ...` add:
   ```ts
   const booksMemberAuthFile = path.join(__dirname, '.auth', 'books-member.json');
   ```
2. After the `books-setup` project line add:
   ```ts
       { name: 'books-member-setup', testDir: './auth', testMatch: 'books-member-auth.setup.ts' },
   ```
3. Change the `books` project's `testMatch` to exclude the member directory:
   ```ts
         testMatch: /books\/(?!admin\/)(?!account\/)(?!member\/).*/,
   ```
4. After the `books-account` project add:
   ```ts
       {
         name: 'books-member',
         use: {
           ...devices['Desktop Chrome'],
           baseURL: 'https://dev-new.thegreatestbooks.org',
           storageState: booksMemberAuthFile,
         },
         testMatch: /books\/member\/.*/,
         dependencies: ['books-member-setup'],
       },
   ```

- [ ] **Step 3: The anonymous spec**

Create `web-app/e2e/tests/books/developers.spec.ts`:

```ts
import { test, expect } from '@playwright/test';

// Signed-out coverage of the public API pages. Matched by the `books` project
// (no storageState). Signed-in non-member coverage is in
// books/account/developers.spec.ts; the member flow is in
// books/member/developers-tokens.spec.ts.
test.describe('Books API developer pages, signed out', () => {
  test('the documentation page renders and lists the books endpoints', async ({ page }) => {
    await page.goto('/developers');

    await expect(page.getByRole('heading', { level: 1, name: /API/ })).toBeVisible();
    await expect(page.locator('#endpoint-listBooks')).toBeVisible();
    await expect(page.locator('#endpoint-listAuthors')).toBeVisible();
    await expect(page.locator('#errors-rate_limited')).toBeVisible();
  });

  test('the contract link serves the OpenAPI document for this host', async ({ page }) => {
    await page.goto('/developers');

    const href = await page.locator('article#developers').getByRole('link', { name: '/api/v1/openapi.json' }).getAttribute('href');
    const response = await page.request.get(href!);

    expect(response.status()).toBe(200);
    const body = await response.json();
    expect(Object.keys(body.paths)).toContain('/api/v1/books');
    expect(body.servers[0].url).toBe('https://dev-new.thegreatestbooks.org');
  });

  test('the footer links to the documentation', async ({ page }) => {
    await page.goto('/');

    await page.locator('footer').getByRole('link', { name: 'API', exact: true }).click();

    await expect(page).toHaveURL(/\/developers$/);
    await expect(page.getByRole('heading', { level: 1, name: /API/ })).toBeVisible();
  });

  test('the token page sends a signed-out visitor to the membership page', async ({ page }) => {
    await page.goto('/developers/tokens');

    await expect(page).toHaveURL(/\/membership$/);
    await expect(page.getByText(/Sign in to your membership/i)).toBeVisible();
  });

  test('the API itself refuses a request without a token', async ({ page }) => {
    const response = await page.request.get('/api/v1/books?per_page=1');

    expect(response.status()).toBe(401);
    expect(response.headers()['www-authenticate']).toBe('Bearer');
  });
});
```

- [ ] **Step 4: The signed-in non-member spec**

Create `web-app/e2e/tests/books/account/developers.spec.ts`:

```ts
import { test, expect } from '@playwright/test';

// Matched by `books-account`: PLAYWRIGHT_ADMIN_EMAIL, signed in, NOT a member.
// This is the first feature gate (as opposed to the members' area itself), so
// the non-member side is worth its own check. Do not comp this account; the
// member flow uses the separate PLAYWRIGHT_MEMBER_EMAIL account.
test.describe('Books API token page, signed in as a non-member', () => {
  test('is redirected to the membership page with the members-only message', async ({ page }) => {
    await page.goto('/developers/tokens');

    await expect(page).toHaveURL(/\/membership$/);
    await expect(page.getByText(/That page is for members/i)).toBeVisible();
  });

  test('can still read the documentation', async ({ page }) => {
    await page.goto('/developers');

    await expect(page.getByRole('heading', { level: 1, name: /API/ })).toBeVisible();
    // .first(): the docs page links to the token page from two sentences.
    await expect(page.locator('article#developers').getByRole('link', { name: '/developers/tokens' }).first()).toBeVisible();
  });
});
```

- [ ] **Step 5: The member spec**

Create `web-app/e2e/tests/books/member/developers-tokens.spec.ts`:

```ts
import { test, expect, type Page } from '@playwright/test';

// Matched by `books-member`: PLAYWRIGHT_MEMBER_EMAIL, comped by
// `bin/rails e2e:member`. Creates a real token on the shared dev database, so
// it cleans up after itself and also before it starts, in case an earlier run
// died between create and revoke (the account holds at most 10 tokens).
const TOKEN_NAME = 'E2E token';
const SECRET = /^tg_[A-Za-z0-9]{40}$/;

// Assumes the page's dialog handler is already installed (beforeEach below):
// a second `page.on('dialog')` that also calls accept() throws on an
// already-handled dialog.
async function revokeLeftovers(page: Page) {
  await page.goto('/developers/tokens');
  const revokes = page.getByRole('button', { name: `Revoke ${TOKEN_NAME}`, exact: true });
  let remaining = await revokes.count();
  while (remaining > 0) {
    await revokes.first().click();
    // Wait on the whole set, not on .first(): with two leftovers, .first()
    // simply resolves to the next one and never reaches count 0.
    await expect(revokes).toHaveCount(remaining - 1);
    remaining -= 1;
  }
}

test.describe('Books API tokens, as a member', () => {
  test.beforeEach(async ({ page }) => {
    // One handler per page (Playwright gives each test its own page): every
    // revoke button carries a turbo_confirm, which is a native confirm().
    page.on('dialog', (dialog) => dialog.accept());
    await revokeLeftovers(page);
  });

  test.afterEach(async ({ page }) => {
    await revokeLeftovers(page);
  });

  test('the members area shows the API card', async ({ page }) => {
    await page.goto('/members');

    await page.getByRole('link', { name: 'Manage tokens' }).click();

    await expect(page).toHaveURL(/\/developers\/tokens$/);
    await expect(page.getByRole('heading', { level: 1, name: /API tokens/ })).toBeVisible();
  });

  test('create, see the secret once, use it, revoke it, and it stops working', async ({ page }) => {
    await page.goto('/developers/tokens');

    await page.getByLabel('Name').fill(TOKEN_NAME);
    await page.getByLabel('Expires').selectOption('30');
    await page.getByRole('button', { name: 'Create token' }).click();

    // The secret arrives in a Turbo Stream, in one readonly input, once.
    const secretInput = page.getByTestId('token-secret');
    await expect(secretInput).toBeVisible();
    const secret = await secretInput.inputValue();
    expect(secret).toMatch(SECRET);
    await expect(page.getByTestId('new-token').getByRole('alert')).toContainText(/only time/i);

    // The list gained a row showing the display prefix, not the secret.
    const row = page.getByRole('row', { name: new RegExp(TOKEN_NAME) });
    await expect(row).toContainText(secret.slice(0, 12));
    await expect(row).not.toContainText(secret);

    // The token works against the API, with the account-tier rate headers.
    const ok = await page.request.get('/api/v1/books?per_page=1', {
      headers: { Authorization: `Bearer ${secret}` },
    });
    expect(ok.status()).toBe(200);
    expect(ok.headers()['x-ratelimit-limit']).toBe('60');
    expect(ok.headers()['x-ratelimit-daily-limit']).toBe('5000');
    const body = await ok.json();
    expect(body.data).toHaveLength(1);
    expect(body.data[0]).toHaveProperty('rank');

    // Shown once: a reload has no secret on it.
    await page.reload();
    await expect(page.getByTestId('token-secret')).toHaveCount(0);
    expect(await page.content()).not.toContain(secret);

    // Revoke (the beforeEach dialog handler accepts the confirm), then the
    // same call is a 401.
    await page.getByRole('button', { name: `Revoke ${TOKEN_NAME}`, exact: true }).click();
    await expect(page.getByRole('row', { name: new RegExp(TOKEN_NAME) })).toHaveCount(0);

    const gone = await page.request.get('/api/v1/books?per_page=1', {
      headers: { Authorization: `Bearer ${secret}` },
    });
    expect(gone.status()).toBe(401);
    expect(gone.headers()['www-authenticate']).toContain('error="invalid_token"');
  });

  test('a submission with no scopes is refused in place and keeps the name', async ({ page }) => {
    await page.goto('/developers/tokens');

    await page.getByLabel('Name').fill(TOKEN_NAME);
    for (const scope of ['books:read', 'music:read', 'games:read']) {
      await page.getByLabel(new RegExp(`^${scope}`)).uncheck();
    }
    await page.getByRole('button', { name: 'Create token' }).click();

    await expect(page.getByTestId('token-form-error')).toBeVisible();
    await expect(page.getByLabel('Name')).toHaveValue(TOKEN_NAME);
    await expect(page.getByTestId('token-secret')).toHaveCount(0);
    await expect(page).toHaveURL(/\/developers\/tokens$/);
  });
});
```

If `getByLabel(new RegExp('^books:read'))` does not resolve because the label text starts with the `<code>` element, use `page.locator('#api_token_scope_books_read')` etc. instead; the ids are fixed by `_form.html.erb`.

- [ ] **Step 6: Type-check the specs**

```bash
cd web-app && npx tsc --noEmit -p e2e/tsconfig.json
```

Expected: no errors. (If `tsconfig.json` does not include the new files, add nothing: it globs `tests/**` and `auth/**`; verify with `cat e2e/tsconfig.json`.)

- [ ] **Step 7: Run the projects that need no new credentials, if port 3000 is yours**

```bash
pid=$(ss -ltnpH 'sport = :3000' | grep -oP 'pid=\K[0-9]+' | head -1); [ -n "$pid" ] && readlink /proc/$pid/cwd || echo "port 3000 is free"
```

If free: `yarn build:all && (bin/rails server > /tmp/claude-1001/-home-shane-dev-the-greatest/a5fffb2a-d816-45d1-9da3-b5b26e6b5001/scratchpad/server.log 2>&1 &)`, then `yarn test:e2e --project=books -g "developer"` and `yarn test:e2e --project=books-account -g "developer"`. Expected: green. Stop the server afterwards. If another checkout holds the port, do not run E2E; say so in the handback. Do not run `books-member` without `PLAYWRIGHT_MEMBER_*` set; the setup project would fail on `undefined!`.

- [ ] **Step 8: Document the member account**

In `docs/features/e2e-testing.md`, next to the `bin/rails e2e:admin` instructions (around line 105), add a subsection:

```markdown
### The member account

`PLAYWRIGHT_ADMIN_EMAIL` is deliberately **not** a member: `tests/books/account/membership.spec.ts`
proves the paywall turns a signed-in non-member away, and comping that account would make those
tests vacuous. Members-only flows (the first is the API token page, `tests/books/member/`) use a
second account:

1. Create another email/password user in the Firebase project.
2. Put it in `e2e/.env` as `PLAYWRIGHT_MEMBER_EMAIL` and `PLAYWRIGHT_MEMBER_PASSWORD`.
3. Sign in once through the browser on `dev-new.thegreatestbooks.org` so the Rails `User` row exists.
4. `bin/rails e2e:member` grants it a comped membership. Idempotent; re-run after a dev-database refresh,
   like `e2e:admin`.

The `books-member` Playwright project signs this account in (`auth/books-member-auth.setup.ts`) and
matches `tests/books/member/**`. Specs there create real rows on the shared dev database and must
clean up after themselves; `developers-tokens.spec.ts` revokes its own tokens before and after.
```

Also add `PLAYWRIGHT_MEMBER_EMAIL` / `PLAYWRIGHT_MEMBER_PASSWORD` to the env listing near line 39 and the example block near line 122.

- [ ] **Step 9: Lint and commit**

```bash
bundle exec standardrb lib/tasks/e2e.rake
git add lib/tasks/e2e.rake e2e/.env.example e2e/playwright.config.ts e2e/auth/books-member-auth.setup.ts e2e/tests/books/developers.spec.ts e2e/tests/books/account/developers.spec.ts e2e/tests/books/member/developers-tokens.spec.ts ../docs/features/e2e-testing.md
git commit -m "test(e2e): a member Playwright account, and specs for the API developer pages"
```

---

### Task 6: Feature doc and full verification

**Files:**
- Modify: `docs/features/public-api.md`

- [ ] **Step 1: Update the feature doc**

In `docs/features/public-api.md`:

1. In `## Shape`, after the Contract bullet, add:

   ```markdown
   - Pages: `GET /developers` is the documentation, on every site, edge-cached for a day and rendered from the host's OpenAPI document (so it lists only that host's endpoints; every `Api::Problem` code has an `#errors-<code>` anchor there, which is what a problem's `type` URI points at). `GET /developers/tokens` is where a member creates and revokes tokens (`MembershipGate[:api]`, never cached). Create answers with a Turbo Stream that carries the secret exactly once; a revoke refreshes the list and form but never the secret panel. Links in: the `/members` card and each footer's "API" entry. There is no header nav item, on purpose.
   ```

2. In `## Authentication`, add a sentence: "Members mint tokens at `/developers/tokens`: a name (≤60 chars), any of the three read scopes, and an expiry of never, 30, 90 or 365 days. Ten per account."

3. Replace the `## Not yet` line with:

   ```markdown
   `/api/v1/authors/{slug}/books`, search, filters, music/games resources, OAuth/MCP.
   ```

4. Add after `## Service accounts` (before `## Edge`):

   ```markdown
   ## Testing the pages

   `test/controllers/developers_controller_test.rb` compares `/developers` signed out and signed in
   (it is edge-cached, so any per-visitor byte would leak) and pins an anchor per problem code.
   `test/controllers/developers/tokens_controller_test.rb` covers the gate, the cap, the once-only
   secret and the Turbo Stream shapes. Playwright: `e2e/tests/books/developers.spec.ts` (anonymous),
   `books/account/developers.spec.ts` (signed-in non-member), `books/member/developers-tokens.spec.ts`
   (the member account, see `docs/features/e2e-testing.md`).
   ```

Check the file for em dashes afterwards: `grep -nE '—|&mdash;' ../docs/features/public-api.md` should print nothing new (the existing file uses none in prose).

- [ ] **Step 2: Full suite**

```bash
bin/rails db:test:prepare test 2>&1 | tee /tmp/claude-1001/-home-shane-dev-the-greatest/a5fffb2a-d816-45d1-9da3-b5b26e6b5001/scratchpad/inc3-suite.log | tail -6
grep -ciE 'warning' /tmp/claude-1001/-home-shane-dev-the-greatest/a5fffb2a-d816-45d1-9da3-b5b26e6b5001/scratchpad/inc3-suite.log
```

Expected: 0 failures, 0 errors; the warning count is 2 (both the yarn `package-lock.json` line). Any other `warning:` line names a file this increment touched; fix the cause.

- [ ] **Step 3: Lint everything and zeitwerk**

```bash
bundle exec standardrb && CI=1 bin/rails zeitwerk:check
```

Expected: no offences; `All is good!`.

- [ ] **Step 4: Commit**

```bash
git add ../docs/features/public-api.md
git commit -m "docs(api): the developer pages shipped; update the public API feature doc"
```

---

## Self-review against the spec

- §8 `/developers` sections, in order: what it is + membership link (Task 1 intro), quick start with curl and Python (Task 1), authentication (Task 1), rate-limit table and six headers (Task 1), endpoint reference from the OpenAPI document with the `openapi.json` link (Task 1, `operations_for`), pagination (Task 1), error table with `#errors-<code>` anchors (Task 1, test pins every code), versioning (Task 1). Copy pass (Task 1 step 8).
- §8 `/developers/tokens`: `require_membership!(:api)` and never cached (Task 2); non-member redirected to `/membership` with the existing message (Task 2 tests); list with name, prefix, scopes, created, last used, expires and a revoke per row (Task 2 `_list`); create form with name, three checked scope boxes, expiry select never/30/90/365 (Task 2 `_form`); POST answers a Turbo Stream in both outcomes, success shows the secret in words + icon with a copy button and adds the row, failure re-renders the form with errors (Task 3); DELETE via Turbo Stream (Task 3); labels on every input (Task 2 test). **Deviation, deliberate:** the secret panel lives in its own `#developers_new_token` region rather than replacing the form, so a revoke can never wipe an uncopied secret; the form is re-rendered blank beneath it.
- §8 links in: `/members` card and footer entry (Task 4); header untouched (nothing in this plan touches a layout's nav).
- Testing § UI: redirects for anonymous and non-member, create/revoke status codes and effects, the cap, no HTML/CSS/copy assertions (structural ids and `href`s only) (Tasks 2 and 3).
- Testing § E2E: anonymous sees `/developers`; the member creates a token, sees the secret once, calls `GET /api/v1/books` through `request` and gets 200 with rate headers, revokes, gets 401; membership seed via a rake task alongside `e2e:admin` (Task 5). **Deviation, Shane's call 2026-09-16:** the member is a second account, not the existing E2E account.
- Global: no migration, no change to the API stack, no header nav item, no new Stimulus controller, `standardrb` + `zeitwerk:check` + clean warnings (Task 6).
- Type consistency: `developers_path`, `developers_tokens_path`, `developers_token_path(token)` (Tasks 1 to 5); `Developers::TokensController::EXPIRY_DAYS` (Tasks 2, 3); partial locals `tokens:`, `errors:`, `name_value:`, `scopes_value:`, `expires_in_value:` (Tasks 2, 3); stream targets `developers_new_token`, `developers_tokens`, `developers_token_form` (Tasks 2, 3, 5); `data-testid`s `token-secret`, `new-token`, `token-cap-reached`, `token-form-error` (Tasks 2, 3, 5); revoke buttons `aria-label="Revoke <name>"` (Tasks 2, 5); form params `api_token[name|scopes][]|expires_in]` (Tasks 2, 3, 5).
