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

      # Scoped to books' correctable types, not Correction.count -- now that a
      # second domain exists (dark_side_pending is a pending Music::Album
      # correction), the unscoped count would include a row this page never
      # shows.
      books_types = Services::Corrections::TypeRegistry.types_for_domain(:books)
      assert_select "[data-testid=status-count-pending]",
        text: Correction.where(status: :pending, correctable_type: books_types).count.to_s
      assert_select "[data-testid=status-count-rejected]",
        text: Correction.where(status: :rejected, correctable_type: books_types).count.to_s
    end

    # Genuinely non-vacuous as of Task 16: fixtures now include a pending
    # Music::Album correction (dark_side_pending) and a pending Games::Game
    # correction (breath_of_the_wild_pending), so this assertion would fail if
    # domain_scope were replaced with ::Correction.all -- before a second
    # correctable domain existed, books was the only kind of row there was to
    # find, and this test could not have caught that regression.
    test "index scopes to this domain's correctable types" do
      get admin_books_corrections_path

      assert_not_empty row_values("data-correctable-type")
      assert_equal ["Books::Book"], row_values("data-correctable-type").uniq
    end

    # The session cookie from setup's sign-in does not carry across -- each
    # domain is a genuinely separate host, so re-authenticating after host! is
    # not optional here the way it would be for a subdomain switch.
    test "index scopes to music's correctable types" do
      host! "dev.thegreatestmusic.org"
      sign_in_as(@admin, stub_auth: true)
      get admin_corrections_path

      assert_not_empty row_values("data-correctable-type")
      assert_equal ["Music::Album"], row_values("data-correctable-type").uniq
    end

    test "index scopes to games' correctable types" do
      host! "dev.thegreatest.games"
      sign_in_as(@admin, stub_auth: true)
      get admin_games_corrections_path

      assert_not_empty row_values("data-correctable-type")
      assert_equal ["Games::Game"], row_values("data-correctable-type").uniq
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

    # books_books(:got) IS the current (books) domain, so this only proves that
    # an id with no matching row in the scope (999_999) does not raise -- the
    # real cross-domain proof is the test below.
    test "bulk reject tolerates an id with no matching row" do
      other = Correction.create!(correctable: books_books(:got), notes: "x")
      post bulk_reject_admin_books_corrections_path, params: {correction_ids: [other.id, 999_999]}

      assert_predicate other.reload, :rejected?
    end

    # THE cross-domain exclusion test: a Music::Album correction id, submitted
    # to bulk_reject from the BOOKS admin. bulk_reject is a mass-write endpoint
    # driven entirely by params[:correction_ids] with no set_correction
    # before_action to catch a wrong id first -- domain_scope is the only thing
    # standing between "select all pending" on one domain's queue and rejecting
    # another domain's row it never rendered. Before Task 16 wired a second
    # correctable domain, this could not be written: every Correction in the
    # test database was a Books::Book correction, so even `::Correction.all`
    # in place of domain_scope would have passed.
    test "bulk reject does not touch a correction from another domain" do
      other = corrections(:dark_side_pending)

      post bulk_reject_admin_books_corrections_path, params: {correction_ids: [other.id]}

      assert_predicate other.reload, :pending?
    end

    # games_editor_user has no DomainRole for books at all, so
    # authenticate_admin! (which runs before require_domain_write!) redirects
    # first -- this proves domain access is required, not that write access is.
    # The "view access but no write access" tests below are what exercise
    # require_domain_write! itself.
    test "a domain user without write access cannot apply" do
      sign_in_as(users(:games_editor_user), stub_auth: true)
      correction = corrections(:war_and_peace_pending)

      post apply_admin_books_correction_path(correction), params: {accepted: {}}

      assert_response :redirect
      assert_predicate correction.reload, :pending?
    end

    # books_viewer_user has a books DomainRole at viewer level, so it clears
    # authenticate_admin! (can_access_domain?) and reaches require_domain_write!,
    # which viewer permission fails (can_write_in_domain? is editor|moderator|
    # admin only). Without require_domain_write! on :apply, this would 200 and
    # write the field.
    test "a domain viewer (read access, no write) cannot apply" do
      sign_in_as(users(:books_viewer_user), stub_auth: true)
      correction = corrections(:war_and_peace_pending)

      post apply_admin_books_correction_path(correction),
        params: {accepted_fields: ["first_published_year"], accepted: {first_published_year: "1867"}}

      assert_response :redirect
      assert_predicate correction.reload, :pending?
      assert_equal 1869, books_books(:war_and_peace).reload.first_published_year
    end

    test "a domain viewer (read access, no write) cannot reject" do
      sign_in_as(users(:books_viewer_user), stub_auth: true)
      correction = corrections(:war_and_peace_pending)

      post reject_admin_books_correction_path(correction), params: {resolution_notes: "no"}

      assert_response :redirect
      assert_predicate correction.reload, :pending?
      assert_nil correction.resolution_notes
    end

    test "a domain viewer (read access, no write) cannot resolve" do
      sign_in_as(users(:books_viewer_user), stub_auth: true)
      correction = corrections(:war_and_peace_notes_only)

      post resolve_admin_books_correction_path(correction)

      assert_response :redirect
      assert_predicate correction.reload, :pending?
      assert_nil correction.resolved_by
    end

    # bulk_reject has no before_action :set_correction (it works on a set of
    # ids, not params[:id]), which makes its require_domain_write! guard the
    # easiest of the four to lose by accident.
    test "a domain viewer (read access, no write) cannot bulk reject" do
      sign_in_as(users(:books_viewer_user), stub_auth: true)
      correction = corrections(:war_and_peace_pending)

      post bulk_reject_admin_books_corrections_path, params: {correction_ids: [correction.id]}

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
