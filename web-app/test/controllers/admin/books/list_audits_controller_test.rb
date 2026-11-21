require "test_helper"

module Admin
  module Books
    class ListAuditsControllerTest < ActionDispatch::IntegrationTest
      setup do
        @admin_user = users(:admin_user)
        @regular_user = users(:regular_user)
        @viewer = users(:books_viewer_user)
        @list = lists(:books_list)
        host! Rails.application.config.domains[:books]
      end

      def open_audit_for(user)
        ListAudit.create!(list: @list, user: user, status: :in_progress,
          started_at: Time.current, lease_expires_at: 1.hour.from_now)
      end

      test "index redirects a regular user" do
        sign_in_as(@regular_user, stub_auth: true)
        get admin_books_list_audits_path
        assert_redirected_to books_root_path
      end

      test "index allows an admin and assigns the prompt and counts" do
        sign_in_as(@admin_user, stub_auth: true)
        get admin_books_list_audits_path
        assert_response :success
        assert_equal ::Services::AgentPrompts.for_list_audit, @controller.view_assigns["agent_prompt"]
        assert_equal ::Services::Lists::Audits::Counts.call, @controller.view_assigns["counts"]
      end

      test "index allows a books viewer" do
        sign_in_as(@viewer, stub_auth: true)
        get admin_books_list_audits_path
        assert_response :success
      end

      test "release by an admin releases another user's audit" do
        audit = open_audit_for(@regular_user)
        sign_in_as(@admin_user, stub_auth: true)
        post release_admin_books_list_audit_path(audit)
        assert_redirected_to admin_books_list_audits_path
        assert audit.reload.released?
      end

      test "a viewer cannot release" do
        audit = open_audit_for(@regular_user)
        sign_in_as(@viewer, stub_auth: true)
        post release_admin_books_list_audit_path(audit)
        assert_redirected_to books_root_path
        assert audit.reload.in_progress?
      end

      test "releasing an audit that is no longer open redirects with an alert" do
        audit = ListAudit.find_by!(list: @list)
        sign_in_as(@admin_user, stub_auth: true)
        post release_admin_books_list_audit_path(audit)
        assert_redirected_to admin_books_list_audits_path
        assert audit.reload.finished?
      end
    end
  end
end
