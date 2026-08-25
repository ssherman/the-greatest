require "test_helper"

module Admin
  class CorrectionsControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
      @admin = users(:admin_user)
      sign_in_as(@admin, stub_auth: true)
    end

    # Reads an attribute off every rendered correction row.
    def row_values(attribute)
      css_select("[data-testid=correction-row]").map { |row| row[attribute] }
    end

    def row_ids
      row_values("data-correction-id").map(&:to_i)
    end

    test "index defaults to pending" do
      get admin_books_corrections_path

      assert_response :success
      assert_not_empty row_values("data-status")
      assert_equal %w[pending], row_values("data-status").uniq
    end

    test "index filters by status" do
      get admin_books_corrections_path(status: "rejected")

      assert_not_empty row_values("data-status")
      assert_equal %w[rejected], row_values("data-status").uniq
    end

    test "index ignores an unknown status and falls back to pending" do
      get admin_books_corrections_path(status: "nonsense")

      assert_equal %w[pending], row_values("data-status").uniq
    end

    test "index reports counts for every status" do
      get admin_books_corrections_path

      assert_select "[data-testid=status-count-pending]",
        text: Correction.where(status: :pending).count.to_s
      assert_select "[data-testid=status-count-rejected]",
        text: Correction.where(status: :rejected).count.to_s
    end

    test "index scopes to this domain's correctable types" do
      get admin_books_corrections_path

      assert_not_empty row_values("data-correctable-type")
      assert_equal ["Books::Book"], row_values("data-correctable-type").uniq
    end

    test "index searches notes" do
      get admin_books_corrections_path(status: "rejected", q: "watches")

      assert_includes row_ids, corrections(:crime_rejected).id
    end

    test "index excludes corrections whose notes do not match the search" do
      get admin_books_corrections_path(status: "pending", q: "zzzznomatch")

      assert_empty row_ids
    end

    # ?q[]=x arrives as params[:q] == ["x"], not a String. sanitize_sql_like
    # calls .gsub on whatever it's given, so an uncoerced Array raises
    # NoMethodError -- a reachable 500 for any admin who double-submits a
    # search param. Same shape this repo already guards against in
    # Admin::StripeEventsController, Admin::DonationsController and
    # Admin::MembershipsController.
    test "index does not crash when q arrives as an array" do
      get admin_books_corrections_path(status: "pending", q: ["x"])

      assert_response :success
    end

    test "show renders" do
      get admin_books_correction_path(corrections(:war_and_peace_pending))

      assert_response :success
    end

    test "turns away a user with no books access" do
      sign_in_as(users(:games_editor_user), stub_auth: true)
      get admin_books_corrections_path

      assert_response :redirect
    end
  end
end
