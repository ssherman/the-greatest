require "test_helper"

module Admin
  module Books
    class ListsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        host! Rails.application.config.domains[:books]

        @list = ::Books::List.create!(name: "Test Books List", status: :approved, year_published: 2020)
      end

      test "index redirects unauthenticated users" do
        get admin_books_lists_path
        assert_redirected_to books_root_path
      end

      test "index redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_lists_path
        assert_redirected_to books_root_path
      end

      test "index allows an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_lists_path
        assert_response :success
      end

      test "index allows a books domain editor" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :editor)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_lists_path
        assert_response :success
      end

      test "show renders, and the list's wizard opens on Paste" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_list_path(@list)
        assert_response :success
        assert_select "a[href=?]", admin_books_list_wizard_path(list_id: @list.id)

        get admin_books_list_wizard_path(list_id: @list.id)
        assert_redirected_to step_admin_books_list_wizard_path(list_id: @list.id, step: "paste")
      end

      test "show offers no wizard on an auto-generated list" do
        generated = ::Books::List.create!(name: "Generated", status: :approved, auto_generated_kind: :user_favorites)
        sign_in_as(@admin_user, stub_auth: true)

        get admin_books_list_path(generated)

        assert_response :success
        assert_select "a[href=?]", admin_books_list_wizard_path(list_id: generated.id), count: 0
      end

      test "list show renders for a books domain viewer without error" do
        @regular_user.domain_roles.create!(domain: :books, permission_level: :viewer)
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_list_path(@list)
        assert_response :success
      end

      test "show renders with voter_details" do
        sign_in_as(@admin_user, stub_auth: true)
        @list.update!(voter_details: "Jane Doe, critic")
        get admin_books_list_path(@list)
        assert_response :success
      end

      test "create and update save voter_details from the admin form" do
        sign_in_as(@admin_user, stub_auth: true)
        post admin_books_lists_path, params: {books_list: {name: "Voters List", status: "unapproved", voter_details: "Jane Doe, critic"}}
        assert_equal "Jane Doe, critic", ::Books::List.order(:id).last.voter_details

        patch admin_books_list_path(@list), params: {books_list: {voter_details: "John Roe, editor"}}
        assert_equal "John Roe, editor", @list.reload.voter_details
      end

      test "show renders for an auto-generated list" do
        sign_in_as(@admin_user, stub_auth: true)
        @list.update!(auto_generated_kind: :user_favorites)

        get admin_books_list_path(@list)

        assert_response :success
      end

      test "creates a list for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::List.count", 1) do
          post admin_books_lists_path, params: {books_list: {name: "New List", status: "unapproved"}}
        end
        assert_redirected_to admin_books_list_path(::Books::List.order(:id).last)
      end

      test "updates a list for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_list_path(@list), params: {books_list: {name: "Renamed"}}
        @list.reload
        assert_redirected_to admin_books_list_path(@list)
        assert_equal "Renamed", @list.name
      end

      test "destroys a list for an admin" do
        sign_in_as(@admin_user, stub_auth: true)
        assert_difference("::Books::List.count", -1) do
          delete admin_books_list_path(@list)
        end
        assert_redirected_to admin_books_lists_path
      end

      # The generated list owns its public URL, its RankedList row and its
      # penalties; deleting it takes all of that. The admin Delete button is
      # hidden for it, and the endpoint refuses rather than 500s.
      test "refuses to destroy an auto-generated list" do
        sign_in_as(@admin_user, stub_auth: true)
        @list.update!(auto_generated_kind: :user_favorites)

        assert_no_difference("::Books::List.count") do
          delete admin_books_list_path(@list)
        end

        assert_redirected_to admin_books_list_path(@list)
      end

      test "index filters to user submitted lists" do
        sign_in_as(@admin_user, stub_auth: true)
        submitted = ::Books::List.create!(name: "From a reader", status: :unapproved,
          submitted_at: Time.current, submitter_email: "reader@example.com")
        admin_made = ::Books::List.create!(name: "From an import", status: :unapproved)

        get admin_books_lists_path(submitted: "submitted")

        assert_response :success
        assert_match submitted.name, response.body
        assert_no_match admin_made.name, response.body
      end

      test "index filters to admin created lists" do
        sign_in_as(@admin_user, stub_auth: true)
        submitted = ::Books::List.create!(name: "From a reader", status: :unapproved,
          submitted_at: Time.current)
        admin_made = ::Books::List.create!(name: "From an import", status: :unapproved)

        get admin_books_lists_path(submitted: "admin")

        assert_response :success
        assert_match admin_made.name, response.body
        assert_no_match submitted.name, response.body
      end

      test "index shows every list when the submitted filter is absent" do
        sign_in_as(@admin_user, stub_auth: true)
        submitted = ::Books::List.create!(name: "From a reader", status: :unapproved,
          submitted_at: Time.current)
        admin_made = ::Books::List.create!(name: "From an import", status: :unapproved)

        get admin_books_lists_path

        assert_response :success
        assert_match submitted.name, response.body
        assert_match admin_made.name, response.body
      end

      test "index shows the submitter for an anonymous submission" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Books::List.create!(name: "Anon list", status: :unapproved, submitted_at: Time.current)

        get admin_books_lists_path(submitted: "submitted")

        assert_response :success
        assert_match "Anonymous", response.body
      end

      test "sort links retain the submitted filter when set" do
        sign_in_as(@admin_user, stub_auth: true)
        ::Books::List.create!(name: "From a reader", status: :unapproved,
          submitted_at: Time.current, submitter_email: "reader@example.com")

        get admin_books_lists_path(submitted: "submitted")

        assert_response :success
        assert_match(/href="[^"]*submitted=submitted[^"]*"/, response.body)
      end

      test "index audit=verified returns only the audited list" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_lists_path(audit: "verified", status: "all")
        assert_response :success
        assert_includes response.body, lists(:books_list).name
        assert_not_includes response.body, @list.name
      end

      test "index items_need_revision=1 returns only flagged lists and combines with the audit filter" do
        sign_in_as(@admin_user, stub_auth: true)
        lists(:books_list).update!(items_need_revision: true)
        get admin_books_lists_path(items_need_revision: "1", status: "all")
        assert_response :success
        assert_includes response.body, lists(:books_list).name
        assert_not_includes response.body, @list.name

        get admin_books_lists_path(items_need_revision: "1", audit: "not_audited", status: "all")
        assert_response :success
        assert_not_includes response.body, lists(:books_list).name
      end

      test "the form can set and clear items_need_revision" do
        sign_in_as(@admin_user, stub_auth: true)
        patch admin_books_list_path(@list), params: {books_list: {items_need_revision: "1"}}
        assert @list.reload.items_need_revision

        patch admin_books_list_path(@list), params: {books_list: {items_need_revision: "0"}}
        assert_not @list.reload.items_need_revision
      end

      test "index audit=not_audited leaves out the audited list" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_lists_path(audit: "not_audited")
        assert_response :success
        assert_includes response.body, @list.name
        assert_not_includes response.body, lists(:books_list).name
      end

      test "show renders the audits section and the audit prompt button" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_list_path(lists(:books_list))
        assert_response :success
        assert_select "[data-testid=copy-list-audit-prompt]"
        assert_select "[data-testid=list-audits]"
      end

      test "a re-audited list appears under its latest verdict only" do
        sign_in_as(@admin_user, stub_auth: true)
        audit = ListAudit.find_by!(list: lists(:books_list))
        ListAudit.create!(list: audit.list, user: @admin_user, status: :finished, verdict: :unverifiable,
          started_at: 1.hour.ago, finished_at: 30.minutes.ago, lease_expires_at: 1.hour.from_now, field_changes: {})

        get admin_books_lists_path(audit: "verified")
        assert_not_includes response.body, lists(:books_list).name
        get admin_books_lists_path(audit: "unverifiable")
        assert_includes response.body, lists(:books_list).name
      end

      test "index ignores an unknown audit value" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_lists_path(audit: "bogus")
        assert_response :success
        assert_includes response.body, @list.name
      end
    end
  end
end
