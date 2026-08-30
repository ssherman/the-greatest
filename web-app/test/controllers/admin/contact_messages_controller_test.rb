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

    # Proves Admin::DomainScopedAuth is actually included: a books DomainRole at
    # viewer level clears authenticate_admin! here (it would not clear the base
    # Admin::BaseController#authenticate_admin!, which admits only global
    # admins/editors) -- this is what makes the sidebar's Contact link a real
    # destination for a domain-scoped admin rather than a dead end.
    test "a books domain viewer can load the index" do
      sign_in_as(users(:books_viewer_user), stub_auth: true)

      get admin_books_contact_messages_path

      assert_response :success
    end

    # require_domain_write! is what keeps DomainScopedAuth from being a
    # regression: authenticate_admin! alone proves domain ACCESS, which a
    # viewer has, so without this guard a read-only viewer could mark messages
    # replied or spam. Asserting the status is unchanged, not just the
    # redirect, is what would catch a guard that redirected AFTER the update.
    test "a books domain viewer cannot resolve" do
      sign_in_as(users(:books_viewer_user), stub_auth: true)
      message = contact_messages(:books_pending)

      post resolve_admin_books_contact_message_path(message), params: {status: "replied"}

      assert_response :redirect
      assert_predicate message.reload, :pending?
    end

    # The other half of that guard: a domain user who genuinely holds WRITE
    # access (editor, not viewer) must still be able to resolve. Without this,
    # "a books domain viewer cannot resolve" alone could not tell a correct
    # require_domain_write! from one that denies everyone.
    test "a games domain editor can resolve a games message" do
      host! Rails.application.config.domains[:games]
      sign_in_as(users(:games_editor_user), stub_auth: true)
      message = contact_messages(:games_pending)

      post resolve_admin_games_contact_message_path(message), params: {status: "replied"}

      assert_predicate message.reload, :replied?
    end
  end
end
