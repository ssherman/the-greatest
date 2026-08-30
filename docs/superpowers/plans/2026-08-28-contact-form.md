# Contact Form Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the footer's `mailto:` link with a modal contact form whose submissions are stored as `ContactMessage` rows and emailed to `contact@thegreatestbooks.org`, branded with the site they came from.

**Architecture:** A `<dialog>` rendered by the shared `FooterComponent` on books, music and games. Because every public page is Cloudflare-cached, the form renders identical HTML for every visitor and hydrates the signed-in email plus a fresh CSRF token from an uncached `GET /contact_state` when the modal opens. `POST /contact_messages` persists the row, enqueues an `AdminMailer` delivery, and answers with a turbo-stream that swaps the modal body. Admin reads the queue per site, scoped by domain, exactly as the corrections queue does.

**Tech Stack:** Rails 8.1, Minitest + Mocha + fixtures, Stimulus, Turbo, ViewComponent, daisyUI 5 / Tailwind 4, Sidekiq, Playwright.

**Spec:** `docs/superpowers/specs/2026-08-28-contact-form-design.md`

## Global Constraints

- **Working directory is `web-app/`.** Every `bin/rails` and `yarn` command runs from there. Docs live in `docs/` at the project root, not `web-app/docs/`.
- **Worktree:** `/home/shane/dev/the-greatest/.claude/worktrees/contact-form`, branch `worktree-contact-form`. Use absolute paths — the same relative path exists in every checkout.
- **Linter is `bundle exec standardrb`**, never `bin/rubocop`. Run `--fix` before every commit.
- **Use Rails generators** for models, controllers and components. Never hand-create them; the generator writes the matching test file.
- **Never run a destructive command against the development database.** No `db:drop`, `db:reset`, `db:schema:load`, no `create_fixtures` (it TRUNCATES). The books data exists only in dev and takes hours to rebuild.
- **Rails 8 enum syntax:** `enum :status, {pending: 0}` with the colon prefix.
- **Root-anchor constants** referenced from inside a nested module: `::ContactMessage`, never `ContactMessage`.
- **Result pattern:** `Result = Struct.new(:success?, :data, :errors, keyword_init: true)`, declared inside the service class.
- **Services live in `app/lib/services/<domain>/`**, not `app/services/`.
- **daisyUI 5 only.** These classes were removed in v5, fail silently, and are caught by `test/lint/daisyui_v4_classes_test.rb`: `form-control`, `label-text`, `label-text-alt`, `input-bordered`, `select-bordered`, `textarea-bordered`, `file-input-bordered`, `input-disabled`, `table-hover`, `tabs-boxed`. Use `fieldset` + `fieldset-legend`, `label`, and bare `input`/`textarea`.
- **Minitest 6:** `assert_equal nil, x` is a hard failure — use `assert_nil`.
- **Verify every new test** by deleting the line under test and watching it go red before trusting it. `assert_empty` must never be the only load-bearing assertion.
- **Gate before claiming done:** `bin/rails test` and `bundle exec standardrb`. Do not run brakeman. CI does not run E2E or system tests.
- **Exact string values, copied verbatim from the spec:**
  - `ContactMessage::MAX_MESSAGE_LENGTH = 10_000`
  - `enum :domain, {music: 0, games: 1, books: 2}` (integers match `NewsPost`)
  - `enum :status, {pending: 0, replied: 1, spam: 2}` (no `new` — it collides with the constructor)
  - Rate limits: anonymous **5 / hour** keyed on `visitor_ip`; signed-in **20 / hour** keyed on `current_user.id`
  - Mail recipient: `SiteContact::ADDRESS`
  - Subject: `"Contact via #{site_name}: #{truncated}"`, message truncated to 60 characters

---

### Task 1: ContactMessage, the submission service, and the mailer

No UI. At the end of this task a contact message can be created and emailed from the console.

**Files:**
- Create: `db/migrate/<timestamp>_create_contact_messages.rb`
- Create: `app/models/contact_message.rb`
- Create: `app/lib/services/contact_messages/submission.rb`
- Create: `app/views/admin_mailer/contact_message.html.erb`
- Create: `app/views/admin_mailer/contact_message.text.erb`
- Create: `test/fixtures/contact_messages.yml`
- Modify: `app/mailers/admin_mailer.rb` (add `#contact_message`)
- Test: `test/models/contact_message_test.rb`
- Test: `test/lib/services/contact_messages/submission_test.rb`
- Test: `test/mailers/admin_mailer_test.rb` (append)

**Interfaces:**
- Produces: `ContactMessage` with `email:String`, `message:String`, `domain:` enum, `status:` enum, `user:User?`, `submitter_ip:String?`, `replied_at:Time?`
- Produces: `Services::ContactMessages::Submission.call(email:, message:, user: nil, domain:, submitter_ip: nil) -> Result(success?:, data: ContactMessage, errors: Array<String>)`
- Produces: `AdminMailer#contact_message(contact_message)`

- [ ] **Step 1: Generate the model**

```bash
bin/rails generate model ContactMessage user:references email:string message:text domain:integer status:integer replied_at:datetime submitter_ip:string
```

- [ ] **Step 2: Rewrite the generated migration**

Replace the generated file's body with this. `t.references :user` already creates its own index, so do not add one.

```ruby
class CreateContactMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :contact_messages do |t|
      t.references :user, null: true, foreign_key: true
      t.string :email, null: false
      t.text :message, null: false
      t.integer :domain, null: false
      t.integer :status, null: false, default: 0
      t.datetime :replied_at
      t.string :submitter_ip

      t.timestamps
    end

    # Backs the admin queue: "pending messages for this domain, newest first"
    # is every index page load.
    add_index :contact_messages, [:status, :created_at]
    add_index :contact_messages, [:domain, :created_at]
  end
end
```

- [ ] **Step 3: Run the migration**

```bash
bin/rails db:migrate
```

Expected: `create_table(:contact_messages)` succeeds and `db/schema.rb` gains the table.

- [ ] **Step 4: Write the failing model test**

Replace the generated `test/models/contact_message_test.rb`:

```ruby
require "test_helper"

class ContactMessageTest < ActiveSupport::TestCase
  def valid_attributes
    {email: "reader@example.org", message: "Hello", domain: :books}
  end

  test "is valid with an email, a message and a domain" do
    assert_predicate ContactMessage.new(**valid_attributes), :valid?
  end

  test "requires an email" do
    record = ContactMessage.new(**valid_attributes, email: nil)

    assert_not_predicate record, :valid?
    assert_includes record.errors[:email], "can't be blank"
  end

  # Required for everyone, including anonymous submitters. Legacy accepted a
  # blank one and produced messages nobody could reply to.
  test "rejects a malformed email" do
    record = ContactMessage.new(**valid_attributes, email: "reader@example")

    assert_not_predicate record, :valid?
    assert_includes record.errors[:email], "is invalid"
  end

  test "requires a message" do
    record = ContactMessage.new(**valid_attributes, message: "")

    assert_not_predicate record, :valid?
    assert_includes record.errors[:message], "can't be blank"
  end

  test "rejects a message longer than the cap" do
    record = ContactMessage.new(**valid_attributes, message: "x" * (ContactMessage::MAX_MESSAGE_LENGTH + 1))

    assert_not_predicate record, :valid?
  end

  test "accepts a message exactly at the cap" do
    record = ContactMessage.new(**valid_attributes, message: "x" * ContactMessage::MAX_MESSAGE_LENGTH)

    assert_predicate record, :valid?
  end

  test "is anonymous without a user" do
    record = ContactMessage.new(**valid_attributes)

    assert_predicate record, :valid?
    assert_nil record.user
  end

  # The integers must match NewsPost's mapping, or the two models disagree
  # about what a stored 1 means.
  test "domain integers match NewsPost" do
    assert_equal NewsPost.domains.slice("music", "games", "books"), ContactMessage.domains
  end

  test "defaults to pending" do
    assert_predicate ContactMessage.new(**valid_attributes), :pending?
  end
end
```

- [ ] **Step 5: Run it and watch it fail**

```bash
bin/rails test test/models/contact_message_test.rb
```

Expected: FAIL — `NameError: uninitialized constant ContactMessage::MAX_MESSAGE_LENGTH`.

- [ ] **Step 6: Write the model**

Replace `app/models/contact_message.rb` (keep the schema annotation comment the generator wrote at the top):

```ruby
class ContactMessage < ApplicationRecord
  # The same bound Correction puts on notes. Generous enough that no real
  # message is affected, while bounding an anonymous public write endpoint.
  MAX_MESSAGE_LENGTH = 10_000

  belongs_to :user, optional: true

  # Integers deliberately match NewsPost's mapping.
  enum :domain, {music: 0, games: 1, books: 2}

  # No `new` value: Rails generates a scope per enum value and
  # ContactMessage.new would collide with the constructor.
  enum :status, {pending: 0, replied: 1, spam: 2}

  # Required for anonymous submitters too, unlike legacy. A message with no
  # reply address cannot be answered, which is the entire point of the form.
  # The format check catches the honest typo, not a deliberate fake.
  validates :email, presence: true, format: {with: URI::MailTo::EMAIL_REGEXP}
  validates :message, presence: true, length: {maximum: MAX_MESSAGE_LENGTH}
end
```

- [ ] **Step 7: Run the model test**

```bash
bin/rails test test/models/contact_message_test.rb
```

Expected: PASS, 9 runs.

- [ ] **Step 8: Write the fixtures**

Create `test/fixtures/contact_messages.yml`. Names are semantic, never `one`/`two`.

```yaml
books_pending:
  user: regular_user
  email: <%= "user@example.com" %>
  message: "The publication year on War and Peace looks wrong."
  domain: 2
  status: 0

books_anonymous:
  email: anonymous@example.org
  message: "Love the site. Any chance of an RSS feed?"
  domain: 2
  status: 0

music_pending:
  email: listener@example.org
  message: "A duplicate album on the Radiohead page."
  domain: 0
  status: 0

books_replied:
  email: answered@example.org
  message: "Already dealt with."
  domain: 2
  status: 1
  replied_at: <%= 1.day.ago.to_fs(:db) %>
```

Check `test/fixtures/users.yml` for `regular_user`'s actual email before running — the fixture above must match it for the mailer test in Step 16. Read it with:

```bash
sed -n '/^regular_user:/,/^$/p' test/fixtures/users.yml
```

Set `books_pending.email` to whatever that shows.

- [ ] **Step 9: Verify the fixtures load**

```bash
bin/rails test test/models/contact_message_test.rb
```

Expected: PASS. A malformed fixture fails here, not later in a confusing place.

- [ ] **Step 10: Commit**

```bash
git add db/migrate db/schema.rb app/models/contact_message.rb test/models/contact_message_test.rb test/fixtures/contact_messages.yml
git commit -m "Add the ContactMessage model"
```

- [ ] **Step 11: Write the failing service test**

Create `test/lib/services/contact_messages/submission_test.rb`:

```ruby
require "test_helper"

module Services
  module ContactMessages
    class SubmissionTest < ActiveSupport::TestCase
      test "stores an anonymous submission" do
        result = Submission.call(
          email: "reader@example.org", message: "Hello", domain: :books, submitter_ip: "203.0.113.5"
        )

        assert_predicate result, :success?
        assert_equal "reader@example.org", result.data.email
        assert_equal "203.0.113.5", result.data.submitter_ip
        assert_nil result.data.user
        assert_predicate result.data, :books?
      end

      # The submitted email is IGNORED for a signed-in visitor. The prefill is a
      # convenience; the server decides who the message is from.
      test "uses the signed-in user's email and ignores the submitted one" do
        user = users(:regular_user)

        result = Submission.call(
          email: "attacker@example.org", message: "Hello", user: user, domain: :books
        )

        assert_predicate result, :success?
        assert_equal user.email, result.data.email
        assert_equal user, result.data.user
      end

      test "fails with errors when the message is blank" do
        result = Submission.call(email: "reader@example.org", message: "", domain: :books)

        assert_not_predicate result, :success?
        assert_nil result.data
        assert_not_empty result.errors
      end

      test "fails when an anonymous email is malformed" do
        result = Submission.call(email: "nope", message: "Hello", domain: :books)

        assert_not_predicate result, :success?
        assert_not_empty result.errors
      end

      test "persists nothing on failure" do
        assert_no_difference "ContactMessage.count" do
          Submission.call(email: "reader@example.org", message: "", domain: :books)
        end
      end

      test "enqueues the admin email on success" do
        AdminMailer.expects(:contact_message).returns(stub(deliver_later: true))

        Submission.call(email: "reader@example.org", message: "Hello", domain: :books)
      end

      test "sends no email on failure" do
        AdminMailer.expects(:contact_message).never

        Submission.call(email: "reader@example.org", message: "", domain: :books)
      end
    end
  end
end
```

- [ ] **Step 12: Run it and watch it fail**

```bash
bin/rails test test/lib/services/contact_messages/submission_test.rb
```

Expected: FAIL — `NameError: uninitialized constant Services::ContactMessages::Submission`.

- [ ] **Step 13: Write the service**

Create `app/lib/services/contact_messages/submission.rb`:

```ruby
module Services
  module ContactMessages
    # Turns a submitted contact form into a ContactMessage plus an email to the
    # owner.
    #
    # The submitted email is used ONLY for an anonymous visitor. A signed-in
    # visitor's address is read from the user record, never from the form: the
    # footer is edge-cached and its form is filled in by the client, so the
    # posted value is not evidence of anything.
    class Submission
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(email:, message:, domain:, user: nil, submitter_ip: nil)
        new(email: email, message: message, domain: domain,
          user: user, submitter_ip: submitter_ip).call
      end

      def initialize(email:, message:, domain:, user:, submitter_ip:)
        @email = email
        @message = message
        @domain = domain
        @user = user
        @submitter_ip = submitter_ip
      end

      def call
        # Root-anchored: a bare ContactMessage resolves against Services::
        # first, which has produced confusing NameErrors in this codebase.
        contact_message = ::ContactMessage.new(
          email: reply_address,
          message: @message,
          domain: @domain,
          user: @user,
          submitter_ip: @submitter_ip
        )

        if contact_message.save
          # deliver_later, not deliver_now: a mail outage must not block the
          # submitter, and Sidekiq retries. The row is already saved either way.
          AdminMailer.contact_message(contact_message).deliver_later
          Result.new(success?: true, data: contact_message, errors: [])
        else
          Result.new(success?: false, data: nil, errors: contact_message.errors.full_messages)
        end
      end

      private

      def reply_address = @user&.email.presence || @email
    end
  end
end
```

- [ ] **Step 14: Run the service test**

```bash
bin/rails test test/lib/services/contact_messages/submission_test.rb
```

Expected: PASS, 7 runs.

- [ ] **Step 15: Add the mailer action**

In `app/mailers/admin_mailer.rb`, add this method after `new_correction` and before the `private` keyword:

```ruby
  # Goes to the PUBLIC contact address, not admin_address. That variable is for
  # sales and donation alerts; the footer already advertises this address, so
  # the form and the mailto land in the same inbox.
  def contact_message(contact_message)
    @contact_message = contact_message
    @site_name = MailBranding.for(contact_message.domain).site_name

    branded_mail(
      domain: contact_message.domain,
      to: SiteContact::ADDRESS,
      subject: "Contact via #{@site_name}: #{contact_message.message.truncate(60)}",
      reply_to: contact_message.email
    )
  end
```

- [ ] **Step 16: Write the mailer templates**

Create `app/views/admin_mailer/contact_message.text.erb`:

```erb
A message was sent from the contact form on <%= @site_name %>.

From:      <%= @contact_message.email %>
Account:   <%= @contact_message.user ? "signed in (##{@contact_message.user.id})" : "anonymous" %>
Submitted: <%= @contact_message.created_at.strftime("%B %-d, %Y at %H:%M") %>

Message:
<%= @contact_message.message %>

Reply to this email to answer the sender directly.
```

Create `app/views/admin_mailer/contact_message.html.erb`:

```erb
<p>A message was sent from the contact form on <%= @site_name %>.</p>

<ul>
  <li>From: <%= @contact_message.email %></li>
  <li>Account: <%= @contact_message.user ? "signed in (##{@contact_message.user.id})" : "anonymous" %></li>
  <li>Submitted: <%= @contact_message.created_at.strftime("%B %-d, %Y at %H:%M") %></li>
</ul>

<p><strong>Message</strong><br>
<%= simple_format(@contact_message.message) %></p>

<p>Reply to this email to answer the sender directly.</p>
```

- [ ] **Step 17: Write the failing mailer test**

Append to `test/mailers/admin_mailer_test.rb`, inside the existing class, before its final `end`:

```ruby
  test "contact_message goes to the public contact address" do
    mail = AdminMailer.contact_message(contact_messages(:books_pending))

    assert_equal [SiteContact::ADDRESS], mail.to
  end

  test "contact_message names the site in the subject" do
    mail = AdminMailer.contact_message(contact_messages(:books_pending))

    assert_match(/The Greatest Books/, mail.subject)
  end

  test "contact_message replies to the sender" do
    message = contact_messages(:books_anonymous)
    mail = AdminMailer.contact_message(message)

    assert_equal [message.email], mail.reply_to
  end

  # Books is MailBranding's DEFAULT_DOMAIN fallback, so a books-only assertion
  # cannot tell a resolved domain from one that fell through to nil. A music
  # message has no such cover.
  test "contact_message is branded for a music message, not books' fallback" do
    mail = AdminMailer.contact_message(contact_messages(:music_pending))

    assert_match(/The Greatest Music/, mail[:from].to_s)
    assert_no_match(/The Greatest Books/, mail[:from].to_s)
  end

  test "contact_message includes the message body" do
    message = contact_messages(:books_anonymous)
    mail = AdminMailer.contact_message(message)

    assert_match(/RSS feed/, mail.text_part.body.to_s)
  end
```

- [ ] **Step 18: Run the mailer test**

```bash
bin/rails test test/mailers/admin_mailer_test.rb
```

Expected: PASS. If the subject assertion fails, check that `MailBranding.for(:books).site_name` reads from `config.domain_settings`, and that `ENV["MAIL_FROM_ADDRESS"]` is set in `web-app/.env`.

- [ ] **Step 19: Verify the tests are not vacuous**

Comment out the `reply_to:` argument in `AdminMailer#contact_message`, run `bin/rails test test/mailers/admin_mailer_test.rb`, and confirm "contact_message replies to the sender" goes RED. Restore it.

- [ ] **Step 20: Lint and run the full suite**

```bash
bundle exec standardrb --fix
bin/rails test
```

Expected: 0 failures, and the run count is up by 21 from the 8199 baseline.

- [ ] **Step 21: Commit**

```bash
git add app/lib/services/contact_messages app/mailers/admin_mailer.rb app/views/admin_mailer test/lib/services/contact_messages test/mailers/admin_mailer_test.rb
git commit -m "Add the contact message submission service and mailer"
```

---

### Task 2: The public endpoints

**Files:**
- Create: `app/controllers/contact_state_controller.rb`
- Create: `app/controllers/contact_messages_controller.rb`
- Create: `app/views/contact_messages/create.turbo_stream.erb`
- Create: `app/views/contact_messages/_form.html.erb`
- Create: `app/views/contact_messages/_thanks.html.erb`
- Modify: `config/routes.rb` (beside the correction endpoints, near line 318)
- Test: `test/controllers/contact_state_controller_test.rb`
- Test: `test/controllers/contact_messages_controller_test.rb`

**Interfaces:**
- Consumes: `Services::ContactMessages::Submission.call(...)` from Task 1
- Produces: route helpers `contact_state_path` (GET) and `contact_messages_path` (POST)
- Produces: `GET /contact_state` -> `{"email": String|null, "csrf_token": String}`
- Produces: partials `contact_messages/_form` and `contact_messages/_thanks`, both rendered inside a `<div id="contact_modal_body">` that Task 3 puts in the footer

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, immediately after the `resources :corrections, only: [:create]` line (around line 319), add:

```ruby
  # Uncached, no database query. Exists so the edge-cached footer form can get a
  # token that belongs to the caller's session, and the signed-in visitor's own
  # email, without either being baked into cacheable HTML.
  get "contact_state", to: "contact_state#show", as: :contact_state
  resources :contact_messages, only: [:create]
```

- [ ] **Step 2: Write the failing state-endpoint test**

Create `test/controllers/contact_state_controller_test.rb`:

```ruby
require "test_helper"

class ContactStateControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "dev-new.thegreatestbooks.org"
  end

  test "returns a null email for an anonymous visitor" do
    get contact_state_path

    assert_response :success
    body = response.parsed_body
    assert_nil body["email"]
    assert body["csrf_token"].present?
  end

  test "returns the signed-in visitor's email" do
    user = users(:regular_user)
    sign_in_as(user, stub_auth: true)

    get contact_state_path

    assert_response :success
    assert_equal user.email, response.parsed_body["email"]
  end

  # The footer is on every edge-cached page. If this response were cacheable,
  # Cloudflare would hand one visitor's address to the next.
  test "is never cached" do
    get contact_state_path

    assert_match(/no-store/, response.headers["Cache-Control"])
  end
end
```

- [ ] **Step 3: Run it and watch it fail**

```bash
bin/rails test test/controllers/contact_state_controller_test.rb
```

Expected: FAIL — uninitialized constant `ContactStateController`.

- [ ] **Step 4: Write the state controller**

Create `app/controllers/contact_state_controller.rb`:

```ruby
# The footer is rendered on every public page, and every public page is
# edge-cached, so the form's HTML must be identical for everyone and the
# <meta name="csrf-token"> in the page belongs to whoever populated the cache.
# This hands the caller their own token and their own email address.
#
# Deliberately does no database work beyond loading the session: it is the one
# uncached endpoint a public, anonymous surface touches, and the Stimulus
# controller only calls it when the modal actually opens, so a crawler that
# never opens the modal never reaches it.
class ContactStateController < ApplicationController
  include Cacheable

  before_action :prevent_caching

  def show
    render json: {
      email: current_user&.email,
      csrf_token: form_authenticity_token
    }
  end
end
```

- [ ] **Step 5: Run the state test**

```bash
bin/rails test test/controllers/contact_state_controller_test.rb
```

Expected: PASS, 3 runs.

- [ ] **Step 6: Write the form partials**

Create `app/views/contact_messages/_form.html.erb`. Note there is no `form-control`, no `label-text`, no `textarea-bordered` — all removed in daisyUI 5.

```erb
<%# Rendered inside #contact_modal_body. Identical HTML for every visitor: the
    email is filled in by contact--form from /contact_state, never here, because
    this markup is served from the Cloudflare cache. %>
<h3 class="text-lg font-bold">Contact us</h3>

<% if local_assigns[:error].present? %>
  <p class="text-error mt-2" data-testid="contact-error"><%= error %></p>
<% end %>

<%= form_with url: contact_messages_path,
      data: {contact__form_target: "form", action: "submit->contact--form#submitting"},
      class: "mt-4 space-y-4" do |form| %>
  <fieldset class="fieldset">
    <legend class="fieldset-legend">Your email</legend>
    <%= form.email_field :email,
          required: true,
          class: "input w-full",
          autocomplete: "email",
          data: {contact__form_target: "email"} %>
  </fieldset>

  <fieldset class="fieldset">
    <legend class="fieldset-legend">Message</legend>
    <%= form.text_area :message,
          required: true,
          rows: 8,
          maxlength: ContactMessage::MAX_MESSAGE_LENGTH,
          class: "textarea w-full" %>
  </fieldset>

  <%# Honeypot. Hidden from people, filled by bots. Not `type=hidden`, which a
      bot skips; visually removed and taken out of the tab order instead. %>
  <div class="hidden" aria-hidden="true">
    <label for="contact_website">Website</label>
    <input type="text" name="website" id="contact_website" tabindex="-1" autocomplete="off">
  </div>

  <div class="modal-action">
    <button type="button" class="btn" data-action="contact--form#close">Cancel</button>
    <%= form.submit "Send", class: "btn btn-primary" %>
  </div>
<% end %>
```

- [ ] **Step 7: Write the thanks partial**

Create `app/views/contact_messages/_thanks.html.erb`:

```erb
<h3 class="text-lg font-bold">Thanks — your message is on its way</h3>
<p class="mt-2">We read everything and will reply to the address you gave us.</p>

<div class="modal-action">
  <button type="button" class="btn btn-primary" data-action="contact--form#close">Close</button>
</div>
```

- [ ] **Step 8: Write the turbo-stream response**

Create `app/views/contact_messages/create.turbo_stream.erb`:

```erb
<%# Every outcome swaps the same target. A bare `head :unprocessable_entity`
    blanks the page, and public layouts render no flash, so this is the only
    way to tell the submitter what happened. %>
<%= turbo_stream.replace "contact_modal_body" do %>
  <div id="contact_modal_body">
    <% if @sent %>
      <%= render "contact_messages/thanks" %>
    <% else %>
      <%= render "contact_messages/form", error: @error %>
    <% end %>
  </div>
<% end %>
```

- [ ] **Step 9: Write the failing create test**

Create `test/controllers/contact_messages_controller_test.rb`:

```ruby
require "test_helper"

class ContactMessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "dev-new.thegreatestbooks.org"

    # The rate limit store is one MemoryStore shared by the whole process
    # (config/initializers/rate_limit_store.rb). Without clearing it, whichever
    # test runs after enough submissions trips the limit instead of the
    # dedicated rate-limit test below. Same fix as CorrectionsControllerTest.
    Rails.application.config.x.rate_limit_store.clear
  end

  def valid_params
    {contact_message: {email: "reader@example.org", message: "Hello there"}}
  end

  test "stores an anonymous message" do
    assert_difference "ContactMessage.count", 1 do
      post contact_messages_path, params: valid_params, as: :turbo_stream
    end

    assert_response :success
    message = ContactMessage.order(:id).last
    assert_equal "reader@example.org", message.email
    assert_predicate message, :books?
    assert_nil message.user
  end

  test "records the domain the message came from" do
    host! "dev.thegreatestmusic.org"

    post contact_messages_path, params: valid_params, as: :turbo_stream

    assert_predicate ContactMessage.order(:id).last, :music?
  end

  # The posted email is ignored for a signed-in visitor: the footer's HTML is
  # edge-cached and filled in by the client, so it is not evidence.
  test "uses the signed-in user's email over the posted one" do
    user = users(:regular_user)
    sign_in_as(user, stub_auth: true)

    post contact_messages_path,
      params: {contact_message: {email: "attacker@example.org", message: "Hello"}},
      as: :turbo_stream

    message = ContactMessage.order(:id).last
    assert_equal user.email, message.email
    assert_equal user, message.user
  end

  test "answers a successful submission with a turbo stream" do
    post contact_messages_path, params: valid_params, as: :turbo_stream

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_match(/contact_modal_body/, response.body)
  end

  test "answers a validation failure with a turbo stream, not a bare 422" do
    assert_no_difference "ContactMessage.count" do
      post contact_messages_path,
        params: {contact_message: {email: "reader@example.org", message: ""}},
        as: :turbo_stream
    end

    assert_response :unprocessable_entity
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_match(/contact_modal_body/, response.body)
  end

  # A filled honeypot persists nothing but still looks like success: a 200 stops
  # a bot retrying, where a 422 brings it back.
  test "silently discards a submission with the honeypot filled" do
    assert_no_difference "ContactMessage.count" do
      post contact_messages_path,
        params: valid_params.merge(website: "http://spam.example"),
        as: :turbo_stream
    end

    assert_response :success
    assert_match(/contact_modal_body/, response.body)
  end

  test "sends no email when the honeypot is filled" do
    AdminMailer.expects(:contact_message).never

    post contact_messages_path,
      params: valid_params.merge(website: "http://spam.example"),
      as: :turbo_stream
  end

  test "rate limits an anonymous submitter after five in an hour" do
    5.times do |i|
      post contact_messages_path,
        params: {contact_message: {email: "reader@example.org", message: "Message #{i}"}},
        as: :turbo_stream
      assert_response :success
    end

    assert_no_difference "ContactMessage.count" do
      post contact_messages_path, params: valid_params, as: :turbo_stream
    end

    assert_response :too_many_requests
    assert_equal "text/vnd.turbo-stream.html", response.media_type
  end

  test "gives a signed-in submitter a larger allowance than an anonymous one" do
    sign_in_as(users(:regular_user), stub_auth: true)

    6.times do |i|
      post contact_messages_path,
        params: {contact_message: {email: "reader@example.org", message: "Message #{i}"}},
        as: :turbo_stream
      assert_response :success
    end
  end

  test "is never cached" do
    post contact_messages_path, params: valid_params, as: :turbo_stream

    assert_match(/no-store/, response.headers["Cache-Control"])
  end
end
```

- [ ] **Step 10: Run it and watch it fail**

```bash
bin/rails test test/controllers/contact_messages_controller_test.rb
```

Expected: FAIL — uninitialized constant `ContactMessagesController`.

- [ ] **Step 11: Write the create controller**

Create `app/controllers/contact_messages_controller.rb`:

```ruby
class ContactMessagesController < ApplicationController
  include Cacheable
  include VisitorIp

  # The footer form is served from the Cloudflare cache, so its authenticity
  # token belongs to whoever populated that cache. contact--form fetches a real
  # one from /contact_state when the modal opens -- but if that fetch never
  # happened (JS off, blocked, slow), null_session accepts the write as
  # ANONYMOUS rather than showing a 422 the submitter cannot act on.
  #
  # Sound, not a compromise: CSRF exists to stop a forged request riding a
  # victim's ambient authority, and null_session removes exactly that authority.
  # What lands is a message the attacker could have posted directly, into a
  # queue a human reads before anything happens.
  protect_from_forgery with: :null_session, only: [:create]

  before_action :prevent_caching

  # Two buckets. An anonymous submitter shares an IP bucket and cannot be
  # identified, so the cap is tight; a signed-in one is attributable and can be
  # banned, so theirs is looser. Both are guesses -- legacy stored no contact
  # messages, so there is no history to set them from.
  #
  # by: goes through visitor_ip, NEVER request.remote_ip, which in production is
  # the Cloudflare edge IP and would put every visitor in one bucket.
  #
  # with: is not optional -- Rails' default raises TooManyRequests and renders an
  # HTML error body, which would blank the modal.
  ANONYMOUS_RATE = 5
  SIGNED_IN_RATE = 20
  RATE_WINDOW = 1.hour

  rate_limit to: SIGNED_IN_RATE, within: RATE_WINDOW,
    by: -> { current_user.id },
    with: -> { render_rate_limited },
    store: Rails.application.config.x.rate_limit_store,
    name: "contact-messages-create-signed-in",
    only: [:create],
    if: -> { current_user.present? }

  rate_limit to: ANONYMOUS_RATE, within: RATE_WINDOW,
    by: -> { visitor_ip },
    with: -> { render_rate_limited },
    store: Rails.application.config.x.rate_limit_store,
    name: "contact-messages-create-anonymous",
    only: [:create],
    unless: -> { current_user.present? }

  def create
    # Same response as a real success. A bot told its submission was discarded
    # learns to try again differently.
    return render_sent if honeypot_filled?

    result = Services::ContactMessages::Submission.call(
      email: contact_params[:email],
      message: contact_params[:message],
      user: current_user,
      domain: Current.domain,
      submitter_ip: visitor_ip
    )

    if result.success?
      render_sent
    else
      @error = result.errors.to_sentence
      render :create, formats: [:turbo_stream], status: :unprocessable_entity
    end
  end

  private

  def contact_params
    params.fetch(:contact_message, {}).permit(:email, :message)
  end

  def honeypot_filled? = params[:website].present?

  def render_sent
    @sent = true
    render :create, formats: [:turbo_stream]
  end

  # Shared by both rate-limit buckets so a throttled submitter sees the same
  # thing either way, and so the two declarations cannot drift apart.
  def render_rate_limited
    @error = "Thanks — you've sent us several messages just now. Please try again shortly."
    render :create, formats: [:turbo_stream], status: :too_many_requests
  end
end
```

- [ ] **Step 12: Run the create test**

```bash
bin/rails test test/controllers/contact_messages_controller_test.rb
```

Expected: PASS, 10 runs. If the domain test fails, confirm `Current.domain` is set by the middleware for `dev.thegreatestmusic.org` — check `Rails.application.config.domains[:music]` matches that host.

- [ ] **Step 13: Verify the honeypot test is not vacuous**

Delete the `return render_sent if honeypot_filled?` line, run `bin/rails test test/controllers/contact_messages_controller_test.rb`, and confirm "silently discards a submission with the honeypot filled" goes RED. Restore it.

- [ ] **Step 14: Lint and run the full suite**

```bash
bundle exec standardrb --fix
bin/rails test
```

Expected: 0 failures.

- [ ] **Step 15: Commit**

```bash
git add app/controllers/contact_state_controller.rb app/controllers/contact_messages_controller.rb app/views/contact_messages config/routes.rb test/controllers/contact_state_controller_test.rb test/controllers/contact_messages_controller_test.rb
git commit -m "Add the public contact form endpoints"
```

---

### Task 3: The footer modal and its Stimulus controller

**Files:**
- Modify: `app/components/footer_component.rb` (`site_links`, plus a `contact?` helper)
- Modify: `app/components/footer_component.html.erb` (render the button and the dialog)
- Create: `app/javascript/controllers/contact/form_controller.js`
- Modify: `app/javascript/manifests/web_shared.js` (register `contact--form`)
- Test: `test/components/footer_component_test.rb` (replace the mailto test)

**Interfaces:**
- Consumes: `contact_state_path`, `contact_messages_path`, and the `contact_messages/_form` partial from Task 2
- Produces: `<div id="contact_modal_body">` — the turbo-stream target Task 2's `create.turbo_stream.erb` already replaces
- Produces: Stimulus identifier `contact--form` with targets `form`, `email`, `dialog`

- [ ] **Step 1: Write the failing component test**

In `test/components/footer_component_test.rb`, REPLACE the existing test named `"#{domain} footer links to the contact address"` (it asserts `a[href='mailto:...']` and will fail once the link becomes a button) with these three, keeping them inside the same `DOMAINS.each` block:

```ruby
    test "#{domain} footer opens the contact form rather than a mail client" do
      render_footer(domain)

      assert_selector "button", text: "Contact"
      assert_no_selector "footer a[href^='mailto:']"
    end

    test "#{domain} footer carries the contact dialog and its turbo target" do
      render_footer(domain)

      assert_selector "dialog#contact_modal"
      assert_selector "#contact_modal_body"
    end

    # The footer is on every edge-cached page. If any per-visitor value were
    # rendered here, Cloudflare would serve one person's data to the next.
    test "#{domain} footer renders identical HTML signed in and signed out" do
      signed_out = render_footer(domain).to_html

      Current.stubs(:user).returns(users(:regular_user))
      signed_in = render_footer(domain).to_html

      assert_equal signed_out, signed_in
    end
```

Add `require "test_helper"` is already present. The third test needs Mocha's `stubs`, which is already loaded globally.

- [ ] **Step 2: Run it and watch it fail**

```bash
bin/rails test test/components/footer_component_test.rb
```

Expected: FAIL — no `button` with text "Contact"; the footer still renders a mailto link.

- [ ] **Step 3: Change site_links in the component**

In `app/components/footer_component.rb`, replace the `site_links` method with:

```ruby
  # "Ranking Details" is deliberately absent for books: music and games each
  # define a /rankings page and books does not, so listing it there would link
  # every books page to a 404.
  #
  # Contact is NOT here. It is a button that opens the contact dialog, not a
  # link, so the template renders it separately -- see the Site column.
  def site_links
    links = [["News", helpers.news_path]]
    links << ["Ranking Details", rankings_path] if rankings_path
    links << ["Support", helpers.membership_path]
    links
  end
```

- [ ] **Step 4: Render the button and dialog in the template**

In `app/components/footer_component.html.erb`, replace the `Site` nav block with this (the `<nav aria-label="Site">` element and its contents):

```erb
    <nav aria-label="Site">
      <h2 class="footer-title">Site</h2>
      <% site_links.each do |label, path| %>
        <%= link_to label, path, class: "link" %>
      <% end %>
      <%# A button, not a link: it opens the contact dialog below. Styled `link`
          so it reads identically to its siblings. %>
      <button type="button" class="link text-left" data-action="contact--form#open">Contact</button>
    </nav>
```

Then, immediately before the closing `</footer>` tag, add the dialog and put the controller on a wrapper that contains BOTH the button and the dialog. Wrap the whole `<footer>` element's contents by changing the opening tag to:

```erb
<footer class="<%= background %> text-base-content"
        data-controller="contact--form"
        data-contact--form-state-url-value="<%= helpers.contact_state_path %>">
```

And add this just before `</footer>`:

```erb
  <%# Identical HTML for every visitor -- the email is filled in by
      contact--form from /contact_state, never rendered here, because this
      markup is served from the Cloudflare edge cache. %>
  <dialog id="contact_modal" class="modal" data-contact--form-target="dialog">
    <div class="modal-box">
      <div id="contact_modal_body">
        <%= render "contact_messages/form" %>
      </div>
    </div>
    <form method="dialog" class="modal-backdrop">
      <button>close</button>
    </form>
  </dialog>
```

- [ ] **Step 5: Write the Stimulus controller**

Create `app/javascript/controllers/contact/form_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// The footer is rendered on every public page and every public page is
// edge-cached, so the form's HTML is identical for everyone: no email baked in,
// and an authenticity token belonging to whoever populated the cache.
//
// This fetches the visitor's own token and email from /contact_state when the
// modal OPENS -- not on page load, so a crawler that never opens it never
// reaches the endpoint; and not on first focus (which is what corrections does)
// because a signed-in visitor should see their address already filled in rather
// than watch it appear after they click elsewhere.
//
// If the fetch fails there is deliberately no error and no blocked submit: the
// server's protect_from_forgery :null_session accepts the write as anonymous.
// Losing attribution beats a 422 the submitter cannot act on.
export default class extends Controller {
  static targets = ["form", "email", "dialog"]
  static values = { stateUrl: String }

  connect() {
    this.stateFetched = false
    this._inflight = null
  }

  open() {
    this.dialogTarget.showModal()
    this.ensureState()
  }

  close() {
    this.dialogTarget.close()
  }

  ensureState() {
    if (this.stateFetched) return this._inflight
    if (this._inflight) return this._inflight

    this._inflight = this._fetchState().finally(() => {
      this._inflight = null
    })
    return this._inflight
  }

  async _fetchState() {
    let response
    try {
      response = await fetch(this.stateUrlValue, {
        headers: { Accept: "application/json" },
        credentials: "same-origin"
      })
    } catch (err) {
      console.warn("contact--form: state fetch failed", err)
      return
    }

    if (!response.ok) return

    const data = await response.json()
    this.stateFetched = true

    if (data.csrf_token) this._applyToken(data.csrf_token)
    if (data.email) this._applyEmail(data.email)
  }

  _applyToken(token) {
    if (this.hasFormTarget) {
      const field = this.formTarget.querySelector('input[name="authenticity_token"]')
      if (field) field.value = token
    }

    // Also patch the page meta tag: the cached page's token is stale for every
    // other Turbo request on this page too. Same as corrections/form_controller.
    const meta = document.querySelector('meta[name="csrf-token"]')
    if (meta) meta.setAttribute("content", token)
  }

  // Read-only rather than disabled: a disabled input is not submitted at all,
  // and while the server ignores this value for a signed-in visitor, an empty
  // required field would block the browser's own validation before it got there.
  _applyEmail(email) {
    if (!this.hasEmailTarget) return
    this.emailTarget.value = email
    this.emailTarget.readOnly = true
  }

  // The turbo-stream response replaces #contact_modal_body, which destroys the
  // form element this controller had already hydrated. Re-arm so a second
  // submission in the same modal session fetches state again.
  submitting() {
    this.stateFetched = false
  }
}
```

- [ ] **Step 6: Register the controller**

In `app/javascript/manifests/web_shared.js`, add these two lines in alphabetical position — after the `Autocomplete` registration and before `Corrections__FormController`:

```javascript
import Contact__FormController from "../controllers/contact/form_controller"
application.register("contact--form", Contact__FormController)
```

- [ ] **Step 7: Run the component test**

```bash
bin/rails test test/components/footer_component_test.rb
```

Expected: PASS. If "renders identical HTML signed in and signed out" fails, something per-visitor leaked into the footer — find it and remove it rather than relaxing the assertion.

- [ ] **Step 8: Verify the cache-safety test is not vacuous**

Temporarily add `<%= Current.user&.email %>` inside the dialog's `modal-box`, run the component test, and confirm "renders identical HTML signed in and signed out" goes RED. Remove it.

- [ ] **Step 9: Check the daisyUI and Stimulus lints**

```bash
bin/rails test test/lint/daisyui_v4_classes_test.rb test/lint/stimulus_manifest_test.rb
```

Expected: PASS. The manifest lint scans views and components; `FooterComponent` is a component, so the new `data-action="contact--form#open"` is visible to it.

- [ ] **Step 10: Build the bundles and check Zeitwerk**

```bash
yarn build:all
CI=1 bin/rails zeitwerk:check
```

Expected: both succeed. A green suite never proves Zeitwerk can boot, because `eager_load` is off in test.

- [ ] **Step 11: Lint and run the full suite**

```bash
bundle exec standardrb --fix
bin/rails db:test:prepare test
```

Use `db:test:prepare test`, not plain `bin/rails test` — only the former builds the JS bundles.

Expected: 0 failures.

- [ ] **Step 12: Commit**

```bash
git add app/components/footer_component.rb app/components/footer_component.html.erb app/javascript/controllers/contact app/javascript/manifests/web_shared.js test/components/footer_component_test.rb
git commit -m "Open the contact form from the footer instead of a mailto"
```

---

### Task 4: The admin queue

**Files:**
- Create: `app/controllers/admin/contact_messages_controller.rb`
- Create: `app/views/admin/contact_messages/index.html.erb`
- Create: `app/views/admin/contact_messages/_row.html.erb`
- Create: `app/views/admin/contact_messages/show.html.erb`
- Modify: `config/routes.rb` (three admin namespaces: music ~line 279, books ~line 577, games ~line 994)
- Modify: `app/lib/admin/domain_nav.rb` (a Contact item in all three `CONFIGS`)
- Test: `test/controllers/admin/contact_messages_controller_test.rb`

**Interfaces:**
- Consumes: `ContactMessage` and its `status` enum from Task 1
- Produces: route helpers `admin_contact_messages_path` (music), `admin_books_contact_messages_path`, `admin_games_contact_messages_path`, plus a `resolve` member POST on each

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, add this inside each of the three admin namespace blocks, immediately after the existing `resources :corrections` block in that same namespace:

```ruby
      resources :contact_messages, only: [:index, :show], controller: "/admin/contact_messages" do
        member do
          post :resolve
        end
      end
```

There are three such places — the music block near line 279, the books block near line 577, and the games block near line 994. Add it to all three.

- [ ] **Step 2: Write the failing admin test**

Create `test/controllers/admin/contact_messages_controller_test.rb`:

```ruby
require "test_helper"

module Admin
  class ContactMessagesControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
      sign_in_as(users(:admin_user), stub_auth: true)
    end

    # This app has no rails-controller-testing gem, so `assigns` does not exist.
    # Assert on the rendered rows instead, the way
    # Admin::CorrectionsControllerTest does.
    def row_values(attribute)
      css_select("[data-testid=contact-message-row]").map { |row| row[attribute] }
    end

    def row_ids
      row_values("data-contact-message-id").map(&:to_i)
    end

    test "index renders" do
      get admin_books_contact_messages_path

      assert_response :success
    end

    # A books admin must not see music's inbox. This is the whole reason the
    # queue is split per site rather than combined. Non-vacuous because
    # music_pending is a pending message in another domain: were domain_scope
    # replaced with ContactMessage.all, it would appear here.
    test "index shows only this domain's messages" do
      get admin_books_contact_messages_path

      assert_includes row_ids, contact_messages(:books_pending).id
      assert_not_includes row_ids, contact_messages(:music_pending).id
    end

    test "index defaults to pending" do
      get admin_books_contact_messages_path

      assert_not_empty row_values("data-status")
      assert_equal %w[pending], row_values("data-status").uniq
    end

    test "index can filter to replied" do
      get admin_books_contact_messages_path(status: "replied")

      assert_not_empty row_values("data-status")
      assert_equal %w[replied], row_values("data-status").uniq
      assert_includes row_ids, contact_messages(:books_replied).id
    end

    test "index ignores an unknown status and falls back to pending" do
      get admin_books_contact_messages_path(status: "nonsense")

      assert_equal %w[pending], row_values("data-status").uniq
    end

    test "index reports a count for every status" do
      get admin_books_contact_messages_path

      # Scoped to this domain, not ContactMessage.count -- an unscoped count
      # would include music's rows, which this page never shows.
      assert_select "[data-testid=status-count-pending]",
        text: ContactMessage.where(status: :pending, domain: :books).count.to_s
    end

    test "show renders a message" do
      get admin_books_contact_message_path(contact_messages(:books_pending))

      assert_response :success
    end

    test "show 404s for another domain's message" do
      get admin_books_contact_message_path(contact_messages(:music_pending))

      assert_response :not_found
    end

    test "resolve marks a message replied and stamps the time" do
      message = contact_messages(:books_pending)

      post resolve_admin_books_contact_message_path(message), params: {status: "replied"}

      message.reload
      assert_predicate message, :replied?
      assert_not_nil message.replied_at
    end

    test "resolve can mark a message as spam" do
      message = contact_messages(:books_pending)

      post resolve_admin_books_contact_message_path(message), params: {status: "spam"}

      assert_predicate message.reload, :spam?
    end

    test "resolve rejects an unknown status" do
      message = contact_messages(:books_pending)

      post resolve_admin_books_contact_message_path(message), params: {status: "nonsense"}

      assert_predicate message.reload, :pending?
    end

    test "requires an admin" do
      sign_in_as(users(:regular_user), stub_auth: true)

      get admin_books_contact_messages_path

      assert_response :redirect
    end
  end
end
```

- [ ] **Step 3: Run it and watch it fail**

```bash
bin/rails test test/controllers/admin/contact_messages_controller_test.rb
```

Expected: FAIL — uninitialized constant `Admin::ContactMessagesController`.

- [ ] **Step 4: Write the admin controller**

Create `app/controllers/admin/contact_messages_controller.rb`:

```ruby
# The contact inbox, scoped to one site. Split per domain rather than combined,
# following Admin::CorrectionsController: each admin reads its own site's queue.
class Admin::ContactMessagesController < Admin::BaseController
  STATUSES = %w[pending replied spam].freeze

  # The single source of truth for which route helper prefix each domain's admin
  # namespace uses. Music's has no domain infix.
  ADMIN_PATHS = {
    books: :admin_books_contact_messages_path,
    music: :admin_contact_messages_path,
    games: :admin_games_contact_messages_path
  }.freeze

  before_action :set_contact_message, only: [:show, :resolve]

  def index
    @status = STATUSES.include?(params[:status]) ? params[:status] : "pending"
    @counts = domain_scope.group(:status).count
    @pagy, @contact_messages = pagy(domain_scope.where(status: @status).order(created_at: :desc))
  end

  def show
  end

  def resolve
    status = params[:status]
    return redirect_to contact_messages_index_path unless STATUSES.include?(status)

    @contact_message.update!(
      status: status,
      replied_at: (status == "replied") ? Time.current : @contact_message.replied_at
    )

    redirect_to contact_messages_index_path, notice: "Message marked #{status}."
  end

  private

  # find_by!(id:) inside the domain scope, so another site's message 404s here
  # rather than rendering under the wrong admin.
  def set_contact_message
    @contact_message = domain_scope.find_by!(id: params[:id])
  end

  def domain_scope
    ContactMessage.where(domain: current_domain)
  end

  def contact_messages_index_path(**options)
    public_send(ADMIN_PATHS.fetch(current_domain.to_sym), **options)
  end
  helper_method :contact_messages_index_path

  def contact_message_path_for(contact_message)
    helper = ADMIN_PATHS.fetch(current_domain.to_sym).to_s.sub("_messages_path", "_message_path")
    public_send(helper, contact_message)
  end
  helper_method :contact_message_path_for
end
```

- [ ] **Step 5: Write the index view**

Create `app/views/admin/contact_messages/index.html.erb`:

```erb
<% content_for :title, "Contact" %>

<div class="space-y-4">
  <h1 class="text-2xl font-bold">Contact</h1>

  <div role="tablist" class="tabs tabs-border">
    <% Admin::ContactMessagesController::STATUSES.each do |status| %>
      <%= link_to contact_messages_index_path(status: status),
            role: "tab",
            class: "tab #{"tab-active" if @status == status}",
            data: {testid: "status-tab-#{status}"} do %>
        <%= status.titleize %>
        <span class="badge badge-sm ml-2"
              data-testid="status-count-<%= status %>"><%= @counts[status].to_i %></span>
      <% end %>
    <% end %>
  </div>

  <div class="overflow-x-auto">
    <table class="table bg-base-100">
      <thead>
        <tr>
          <th>From</th>
          <th>Message</th>
          <th>Received</th>
        </tr>
      </thead>
      <tbody>
        <%= render partial: "admin/contact_messages/row", collection: @contact_messages, as: :contact_message %>
      </tbody>
    </table>
  </div>

  <%# series_nav, NOT pagy_nav -- this app is on a Pagy version whose nav is
      built from the pagy object. Every other admin index uses this form. %>
  <%== @pagy.series_nav %>
</div>
```

- [ ] **Step 6: Write the row partial**

Create `app/views/admin/contact_messages/_row.html.erb`:

The `data-` attributes are what the controller test asserts on — this app has no
`assigns`, so the rendered row is the only evidence a test has.

```erb
<tr data-testid="contact-message-row"
    data-contact-message-id="<%= contact_message.id %>"
    data-status="<%= contact_message.status %>"
    data-domain="<%= contact_message.domain %>">
  <td><%= contact_message.email %></td>
  <td class="max-w-md">
    <%# overflow-wrap: anywhere, not break-words -- this is visitor-supplied
        text and a long unbroken string blows out the table otherwise. %>
    <%= link_to contact_message.message.truncate(80),
          contact_message_path_for(contact_message),
          class: "link [overflow-wrap:anywhere]" %>
  </td>
  <td><%= contact_message.created_at.strftime("%b %-d, %Y") %></td>
</tr>
```

- [ ] **Step 7: Write the show view**

Create `app/views/admin/contact_messages/show.html.erb`:

```erb
<% content_for :title, "Contact message" %>

<div class="space-y-4">
  <%= link_to "← Back to Contact", contact_messages_index_path, class: "link" %>

  <h1 class="text-2xl font-bold">Message from <%= @contact_message.email %></h1>

  <ul class="text-sm opacity-70">
    <li>Received <%= @contact_message.created_at.strftime("%B %-d, %Y at %H:%M") %></li>
    <li><%= @contact_message.user ? "Signed in as ##{@contact_message.user.id}" : "Anonymous" %></li>
    <li>Status: <%= @contact_message.status.titleize %></li>
  </ul>

  <div class="card bg-base-100">
    <div class="card-body">
      <p class="whitespace-pre-wrap [overflow-wrap:anywhere]"><%= @contact_message.message %></p>
    </div>
  </div>

  <div class="flex flex-wrap gap-2">
    <%= link_to "Reply by email",
          "mailto:#{@contact_message.email}",
          class: "btn btn-primary" %>
    <%= button_to "Mark replied",
          resolve_path_for(@contact_message),
          params: {status: "replied"},
          class: "btn" %>
    <%= button_to "Mark spam",
          resolve_path_for(@contact_message),
          params: {status: "spam"},
          class: "btn btn-ghost" %>
  </div>
</div>
```

- [ ] **Step 8: Add the resolve path helper**

The show view calls `resolve_path_for`. Add it to `app/controllers/admin/contact_messages_controller.rb` beside the other helpers:

```ruby
  def resolve_path_for(contact_message)
    helper = "resolve_" + ADMIN_PATHS.fetch(current_domain.to_sym).to_s.sub("_messages_path", "_message_path")
    public_send(helper, contact_message)
  end
  helper_method :resolve_path_for
```

- [ ] **Step 9: Run the admin test**

```bash
bin/rails test test/controllers/admin/contact_messages_controller_test.rb
```

Expected: PASS, 12 runs.

- [ ] **Step 10: Verify the domain-scoping test is not vacuous**

Change `domain_scope` to `ContactMessage.all`, run the admin test, and confirm both "index shows only this domain's messages" and "show 404s for another domain's message" go RED. Restore it.

- [ ] **Step 11: Add the sidebar entries**

In `app/lib/admin/domain_nav.rb`, add a Contact item to each of the three `CONFIGS`, immediately after that domain's existing `Corrections` line:

```ruby
          {label: "Contact", icon: :chat, path: -> { URL_HELPERS.admin_contact_messages_path }},
```

for `music:`, and:

```ruby
          {label: "Contact", icon: :chat, path: -> { URL_HELPERS.admin_books_contact_messages_path }},
```

for `books:`, and:

```ruby
          {label: "Contact", icon: :chat, path: -> { URL_HELPERS.admin_games_contact_messages_path }},
```

for `games:`.

- [ ] **Step 12: Lint and run the full suite**

```bash
bundle exec standardrb --fix
bin/rails db:test:prepare test
```

Expected: 0 failures.

- [ ] **Step 13: Commit**

```bash
git add app/controllers/admin/contact_messages_controller.rb app/views/admin/contact_messages app/lib/admin/domain_nav.rb config/routes.rb test/controllers/admin/contact_messages_controller_test.rb
git commit -m "Add the per-site contact message admin queue"
```

---

### Task 5: End-to-end coverage and the feature doc

**Files:**
- Create: `web-app/e2e/tests/books/contact.spec.ts`
- Modify: `web-app/e2e/tests/books/footer.spec.ts` (replace the mailto assertion)
- Create: `docs/features/contact_form.md` (project root, NOT `web-app/docs/`)

**Interfaces:**
- Consumes: everything from Tasks 1–4. No new application code.

- [ ] **Step 1: Replace the stale footer E2E assertion**

In `web-app/e2e/tests/books/footer.spec.ts`, replace the test named `'the contact link opens a mail client'` with:

```typescript
  test('the contact control opens the form rather than a mail client', async ({ page }) => {
    await page.goto('/privacy_policy');

    const footer = page.locator('footer');

    await expect(footer.getByRole('button', { name: 'Contact', exact: true })).toBeVisible();
    await expect(footer.locator(`a[href="mailto:${CONTACT}"]`)).toHaveCount(0);
  });
```

Leave `'the policy body names the contact address'` alone — the deletion policy still carries a real mailto, deliberately.

- [ ] **Step 2: Run the footer E2E spec**

Start a server in one terminal, then run the spec:

```bash
yarn build:all
bin/rails server
```

```bash
yarn test:e2e e2e/tests/books/footer.spec.ts
```

Expected: PASS. `bin/dev` needs a TTY and will not work here — use `yarn build:all` plus `bin/rails server`.

- [ ] **Step 3: Write the contact form E2E spec**

Create `web-app/e2e/tests/books/contact.spec.ts`:

```typescript
import { test, expect } from '@playwright/test';

// The contact form is one FooterComponent shared by books, music and games, and
// is covered per-domain by test/components/footer_component_test.rb. These run
// against books alone because it is the one e2e project here that needs no auth
// setup.
test.describe('Contact form', () => {
  test('opens from the footer', async ({ page }) => {
    await page.goto('/');

    await page.locator('footer').getByRole('button', { name: 'Contact', exact: true }).click();

    const dialog = page.locator('#contact_modal');
    await expect(dialog).toBeVisible();
    await expect(dialog.getByRole('heading', { name: 'Contact us' })).toBeVisible();
  });

  test('sends an anonymous message and confirms in place', async ({ page }) => {
    await page.goto('/');

    await page.locator('footer').getByRole('button', { name: 'Contact', exact: true }).click();

    const dialog = page.locator('#contact_modal');
    await dialog.getByLabel('Your email').fill('e2e-reader@example.org');
    await dialog.getByLabel('Message').fill('An end-to-end test message.');
    await dialog.getByRole('button', { name: 'Send' }).click();

    // The modal stays open and swaps its body -- public layouts render no flash,
    // so this panel is the only confirmation there is.
    await expect(dialog.getByText(/your message is on its way/i)).toBeVisible();
  });

  test('rejects a message with no address', async ({ page }) => {
    await page.goto('/');

    await page.locator('footer').getByRole('button', { name: 'Contact', exact: true }).click();

    const dialog = page.locator('#contact_modal');
    await dialog.getByLabel('Message').fill('No address on this one.');
    await dialog.getByRole('button', { name: 'Send' }).click();

    // The browser's own required-field validation stops this before the request.
    await expect(dialog.getByLabel('Your email')).toBeFocused();
  });

  test('closes without sending', async ({ page }) => {
    await page.goto('/');

    await page.locator('footer').getByRole('button', { name: 'Contact', exact: true }).click();

    const dialog = page.locator('#contact_modal');
    await expect(dialog).toBeVisible();

    await dialog.getByRole('button', { name: 'Cancel' }).click();

    await expect(dialog).not.toBeVisible();
  });
});
```

- [ ] **Step 4: Run the new E2E spec**

```bash
yarn test:e2e e2e/tests/books/contact.spec.ts
```

Expected: PASS, 4 tests. If the labels do not resolve, check that `fieldset-legend` is what `getByLabel` matches — if not, add `data-testid="contact-email"` and `data-testid="contact-message"` to the inputs in `app/views/contact_messages/_form.html.erb` and target those instead.

- [ ] **Step 5: Write the feature doc**

Create `docs/features/contact_form.md` at the **project root**:

```markdown
# Contact form

A modal contact form opened from the footer link on books, music and games.
Replaces the `mailto:` that shipped with the footer.

## Flow

1. `FooterComponent` renders a `<dialog id="contact_modal">` containing
   `contact_messages/_form`. The markup is identical for every visitor, because
   the footer appears on every Cloudflare-cached page.
2. The `contact--form` Stimulus controller opens the dialog and fetches
   `GET /contact_state` (uncached, no database query), which returns the
   signed-in visitor's email and a CSRF token for their own session.
3. `POST /contact_messages` persists a `ContactMessage`, enqueues
   `AdminMailer#contact_message`, and answers with a turbo-stream that swaps
   `#contact_modal_body` to a confirmation.

## Why it works this way

- **The form cannot be prefilled server-side.** The footer is on every
  edge-cached page, so rendering one visitor's email would serve it to
  everyone. `test/components/footer_component_test.rb` asserts the footer's
  HTML is identical signed in and signed out.
- **The posted email is ignored for a signed-in visitor.** The server reads
  `current_user.email`. The prefill is a convenience, not evidence.
- **The email is required for anonymous submitters**, unlike the legacy site,
  which accepted blank addresses and produced messages nobody could answer.
- **Every response is a turbo-stream**, including failures. A bare
  `head :unprocessable_entity` blanks the page, and public layouts render no
  flash.

## Spam controls

A honeypot field (`website`) and two rate-limit buckets: 5/hour for anonymous
submitters keyed on `visitor_ip`, 20/hour for signed-in ones keyed on user id.
Both numbers are guesses — legacy stored no contact messages, so there was no
history to set them from. Adjust in `ContactMessagesController`.

## Mail

`AdminMailer#contact_message` sends to `SiteContact::ADDRESS` with the
submitter as `Reply-To`, branded per domain via `MailBranding`. The subject
carries the site name and the first 60 characters of the message.

## Admin

Split per site, like corrections: `Admin::ContactMessagesController` scoped to
`current_domain`, reachable from the Contact entry in `Admin::DomainNav`.
```

- [ ] **Step 6: Final gate**

```bash
bundle exec standardrb
bin/rails db:test:prepare test
CI=1 bin/rails zeitwerk:check
```

Expected: standardrb clean, 0 test failures, zeitwerk clean.

- [ ] **Step 7: Commit**

```bash
git add web-app/e2e/tests/books/contact.spec.ts web-app/e2e/tests/books/footer.spec.ts docs/features/contact_form.md
git commit -m "Cover the contact form end to end and document it"
```

---

## Notes for the reviewer

- **Two existing tests change on purpose.** `test/components/footer_component_test.rb`'s "footer links to the contact address" and `e2e/tests/books/footer.spec.ts`'s "the contact link opens a mail client" both assert the `mailto:` that this work removes. Task 3 Step 1 and Task 5 Step 1 replace them. The policy pages keep their `mailto:` — `/deletion_policy` is Facebook's data-deletion URL and needs a reachable address in the page body.
- **The footer ships to music and games, which are live.** Books is pre-launch; the other two are not.
- **Not covered by any automated test:** whether Cloudflare actually caches the footer's new markup as expected in production. Verify after deploy on the games zone, which does not cache HTML and therefore always reflects the running code.
