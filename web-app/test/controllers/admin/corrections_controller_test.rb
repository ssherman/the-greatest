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

    test "apply writes the accepted fields and resolves" do
      correction = corrections(:war_and_peace_pending)

      post apply_admin_books_correction_path(correction),
        params: {accepted_fields: ["first_published_year"], accepted: {first_published_year: "1867"}}

      assert_redirected_to admin_books_correction_path(correction)
      assert_equal 1867, books_books(:war_and_peace).reload.first_published_year
      assert_predicate correction.reload, :resolved?
    end

    # The unticked row still submits its value. Without the checkbox list, this
    # would silently apply the title too.
    test "apply rejects a field whose box was not ticked, even though its input was submitted" do
      correction = corrections(:war_and_peace_pending)

      post apply_admin_books_correction_path(correction),
        params: {
          accepted_fields: ["first_published_year"],
          accepted: {first_published_year: "1867", title: "War & Peace"}
        }

      assert_predicate correction.reload.correction_fields.find_by(field_name: "title"), :rejected?
      assert_equal "War and Peace", books_books(:war_and_peace).reload.title
    end

    test "apply writes the admin's edited value" do
      correction = corrections(:war_and_peace_pending)

      post apply_admin_books_correction_path(correction),
        params: {accepted_fields: ["title"], accepted: {title: "War & Peace, Revised"}}

      assert_equal "War & Peace, Revised", books_books(:war_and_peace).reload.title
    end

    test "apply splits a comma-joined array field" do
      correction = ::Correction.create!(correctable: books_books(:war_and_peace),
        correction_fields_attributes: [{field_name: "alternate_titles",
                                        old_value: ["Voyna i mir"],
                                        new_value: ["Voyna i mir", "War & Peace"]}])

      post apply_admin_books_correction_path(correction),
        params: {accepted_fields: ["alternate_titles"],
                 accepted: {alternate_titles: ["Voyna i mir, War & Peace"]}}

      assert_equal ["Voyna i mir", "War & Peace"], books_books(:war_and_peace).reload.alternate_titles
    end

    test "apply reports validation errors without changing anything" do
      correction = corrections(:war_and_peace_pending)

      post apply_admin_books_correction_path(correction),
        params: {accepted_fields: ["title"], accepted: {title: ""}}

      assert_predicate correction.reload, :pending?
      assert_match(/can't be blank/, flash[:alert])
    end

    test "reject stores the reason and does not touch the record" do
      correction = corrections(:war_and_peace_pending)

      post reject_admin_books_correction_path(correction), params: {resolution_notes: "Not supported by any source"}

      correction.reload
      assert_predicate correction, :rejected?
      assert_equal "Not supported by any source", correction.resolution_notes
      assert_equal 1869, books_books(:war_and_peace).reload.first_published_year
      assert correction.correction_fields.all?(&:rejected?)
    end

    test "resolve closes a notes-only correction fixed by hand" do
      correction = corrections(:war_and_peace_notes_only)

      post resolve_admin_books_correction_path(correction)

      assert_predicate correction.reload, :resolved?
      assert_equal @admin, correction.resolved_by
    end

    test "bulk reject closes several at once" do
      ids = [corrections(:war_and_peace_pending).id, corrections(:war_and_peace_notes_only).id]

      post bulk_reject_admin_books_corrections_path, params: {correction_ids: ids}

      assert_equal %w[rejected rejected], Correction.where(id: ids).map(&:status)
    end

    test "bulk reject ignores ids outside this domain" do
      other = Correction.create!(correctable: books_books(:got), notes: "x")
      post bulk_reject_admin_books_corrections_path, params: {correction_ids: [other.id, 999_999]}

      assert_predicate other.reload, :rejected?
    end

    test "a domain user without write access cannot apply" do
      sign_in_as(users(:games_editor_user), stub_auth: true)
      correction = corrections(:war_and_peace_pending)

      post apply_admin_books_correction_path(correction), params: {accepted: {}}

      assert_response :redirect
      assert_predicate correction.reload, :pending?
    end

    # A crafted request can send accepted=foo (a plain String) instead of the
    # nested accepted[field]=... shape the form always sends. .permit! is not
    # defined on String -- without the is_a?(ActionController::Parameters)
    # guard in accepted_params, this is a reachable 500 in the admin.
    test "apply does not crash when accepted arrives as a plain string" do
      correction = corrections(:war_and_peace_pending)

      post apply_admin_books_correction_path(correction),
        params: {accepted_fields: ["title"], accepted: "not-a-hash"}

      assert_response :redirect
      assert_equal "War and Peace", books_books(:war_and_peace).reload.title
    end
  end
end
