require "test_helper"

class Admin::MembershipsControllerTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @admin = users(:admin_user)
    @editor = users(:editor_user)
    @membership = memberships(:regular_user_monthly)
    host! Rails.application.config.domains[:music]
  end

  test "an admin sees the index" do
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url
    assert_response :success
  end

  test "an editor is denied the index" do
    sign_in_as(@editor, stub_auth: true)
    get admin_memberships_url
    assert_response :redirect
  end

  test "a signed-out visitor is denied the index" do
    get admin_memberships_url
    assert_response :redirect
  end

  test "filters by source" do
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url(source: "comped")
    assert_response :success
    assert_equal [memberships(:editor_user_comped).id],
      @controller.view_assigns["memberships"].map(&:id)
  end

  test "filters by status" do
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url(status: "canceled")
    assert_response :success
    assert_equal [memberships(:google_user_canceled_in_grace).id],
      @controller.view_assigns["memberships"].map(&:id)
  end

  test "filters to unattached rows" do
    sign_in_as(@admin, stub_auth: true)
    orphan = ::Membership.create!(
      user: nil, source: :stripe, status: :active,
      stripe_subscription_id: "sub_filter_unattached", stripe_customer_id: "cus_filter_unattached"
    )

    get admin_memberships_url(attached: "false")
    assert_response :success
    assert_equal [orphan.id], @controller.view_assigns["memberships"].map(&:id)
  end

  test "ignores a source that is not a known enum value" do
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url(source: "'; drop table memberships; --")
    assert_response :success
  end

  test "survives an array-valued search param" do
    # ?q[]=foo arrives as an Array; Reviews::MyReviewsQuery and
    # Admin::ReviewsBaseController both hit this exact shape.
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url("q" => ["cus_regular"])
    assert_response :success
  end

  test "searches by stripe customer id" do
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url(q: "cus_regular")
    assert_response :success
    assert_equal [memberships(:regular_user_monthly).id],
      @controller.view_assigns["memberships"].map(&:id)
  end

  test "searches by user email" do
    sign_in_as(@admin, stub_auth: true)
    # editor_user's email, not regular_user's: "user@example.com" is itself a
    # suffix of both "passworduser@example.com" and "googleuser@example.com",
    # so searching on it would match three memberships instead of one and the
    # assertion below would be asserting the wrong thing.
    get admin_memberships_url(q: users(:editor_user).email)
    assert_response :success
    assert_equal [memberships(:editor_user_comped).id],
      @controller.view_assigns["memberships"].map(&:id)
  end

  test "a literal percent sign in the search term is escaped, not treated as a wildcard" do
    sign_in_as(@admin, stub_auth: true)
    # Unescaped, "%" ILIKE-matches every row -- sanitize_sql_like is what
    # keeps a typed "%" a literal character instead of a wildcard.
    get admin_memberships_url(q: "%")
    assert_response :success
    assert_equal [], @controller.view_assigns["memberships"].map(&:id)
  end

  test "an admin sees the detail page" do
    sign_in_as(@admin, stub_auth: true)
    get admin_membership_url(@membership)
    assert_response :success
  end

  test "an editor is denied the detail page" do
    sign_in_as(@editor, stub_auth: true)
    get admin_membership_url(@membership)
    assert_response :redirect
  end

  test "a signed-out visitor is denied the detail page" do
    get admin_membership_url(@membership)
    assert_response :redirect
  end

  test "the index does not N+1 over users" do
    sign_in_as(@admin, stub_auth: true)
    # An extra row owned by a user setup never references, so the margin between
    # "preloaded" and "not preloaded" comes from real uncached SELECTs rather
    # than from which fixtures setup happened to warm the query cache with.
    Membership.create!(user: users(:contractor_user), source: :comped, status: :active)

    # includes(:user, :granted_by) is load-bearing: the table renders both in a
    # loop. Pinned at 7 with .includes present; deleting it raises this to 10
    # (a real margin of 3 uncached SELECTs, not the incidental margin of 1 an
    # earlier version of this test had from setup's own fixture-cache warming).
    assert_queries_count(7) { get admin_memberships_url }
  end

  test "an admin comps a user" do
    sign_in_as(@admin, stub_auth: true)
    assert_difference -> { Membership.source_comped.count }, 1 do
      post admin_memberships_url, params: {
        membership: {user_id: users(:contractor_user).id, note: "Wrote the importer"}
      }
    end

    membership = Membership.source_comped.find_by(user_id: users(:contractor_user).id)
    assert_equal "active", membership.status
    assert_nil membership.current_period_end
    assert_equal "Wrote the importer", membership.note
    assert_equal @admin.id, membership.granted_by_id
    assert_redirected_to admin_membership_url(membership)
  end

  test "an editor may not comp" do
    sign_in_as(@editor, stub_auth: true)
    assert_no_difference -> { Membership.count } do
      post admin_memberships_url, params: {membership: {user_id: users(:contractor_user).id}}
    end
    assert_response :redirect
  end

  test "a signed-out visitor may not comp" do
    assert_no_difference -> { Membership.count } do
      post admin_memberships_url, params: {membership: {user_id: users(:contractor_user).id}}
    end
    assert_response :redirect
  end

  test "granted_by cannot be forged through params" do
    sign_in_as(@admin, stub_auth: true)
    post admin_memberships_url, params: {
      membership: {user_id: users(:contractor_user).id, granted_by_id: users(:regular_user).id}
    }
    assert_equal @admin.id, Membership.source_comped.find_by(user_id: users(:contractor_user).id).granted_by_id
  end

  test "a comp cannot smuggle in a source or a subscription id" do
    sign_in_as(@admin, stub_auth: true)
    post admin_memberships_url, params: {
      membership: {
        user_id: users(:contractor_user).id,
        source: "stripe",
        stripe_subscription_id: "sub_smuggled"
      }
    }
    membership = Membership.source_comped.find_by(user_id: users(:contractor_user).id)
    assert_not_nil membership
    assert_nil membership.stripe_subscription_id
  end

  test "comping accepts an end date and stores end-of-day, not midnight" do
    sign_in_as(@admin, stub_auth: true)
    post admin_memberships_url, params: {
      membership: {user_id: users(:contractor_user).id, current_period_end: "2027-01-01"}
    }
    membership = Membership.source_comped.find_by(user_id: users(:contractor_user).id)
    # Asserting only .to_date is exactly what let a midnight-truncation bug
    # through before: midnight and end-of-day are the same calendar date but
    # very different instants for entitlement checks.
    # .floor(6): Postgres timestamp columns are microsecond precision, so the
    # nanosecond-precision Ruby Time this computes gets truncated on the round
    # trip through the database.
    assert_equal Time.zone.parse("2027-01-01").end_of_day.floor(6), membership.current_period_end
  end

  test "an end date comped through midday of its own last day still grants access" do
    # The property the admin actually meant by "access through 2027-01-01":
    # current_period_end must still be in the future at midday on that date,
    # not already passed the moment the date begins.
    sign_in_as(@admin, stub_auth: true)
    post admin_memberships_url, params: {
      membership: {user_id: users(:contractor_user).id, current_period_end: "2027-01-01"}
    }
    membership = Membership.source_comped.find_by(user_id: users(:contractor_user).id)

    travel_to Time.zone.parse("2027-01-01 12:00") do
      assert membership.current_period_end > Time.current
    end
  end

  test "comping with a blank end date stores nil, not a truncated blank" do
    sign_in_as(@admin, stub_auth: true)
    post admin_memberships_url, params: {
      membership: {user_id: users(:contractor_user).id, current_period_end: ""}
    }
    membership = Membership.source_comped.find_by(user_id: users(:contractor_user).id)
    assert_nil membership.current_period_end
  end

  test "comping a user who already has a comp updates it rather than adding a second" do
    sign_in_as(@admin, stub_auth: true)
    # editor_user already holds editor_user_comped. find_or_initialize_by means
    # this is an update, which is the intended behaviour: comping someone twice
    # revises their comp. The (user_id, source) index makes it impossible for
    # this to become a duplicate even under a race.
    assert_no_difference -> { Membership.count } do
      post admin_memberships_url, params: {membership: {user_id: users(:editor_user).id, note: "Revised comp"}}
    end
    assert_equal "Revised comp", memberships(:editor_user_comped).reload.note
    assert_equal 1, Membership.source_comped.where(user_id: users(:editor_user).id).count
  end

  test "re-comping a revoked user clears canceled_at" do
    sign_in_as(@admin, stub_auth: true)
    comped = memberships(:editor_user_comped)
    post revoke_admin_membership_url(comped)
    comped.reload
    assert_equal "canceled", comped.status
    assert_not_nil comped.canceled_at

    post admin_memberships_url, params: {membership: {user_id: users(:editor_user).id}}

    comped.reload
    assert_equal "active", comped.status
    assert_nil comped.canceled_at
  end

  test "a scalar-shaped comp body is a 400, not a 500" do
    sign_in_as(@admin, stub_auth: true)
    assert_no_difference -> { Membership.count } do
      post admin_memberships_url, params: {membership: "x"}
    end
    assert_response :bad_request
  end

  test "comping an unknown user id re-renders the form" do
    sign_in_as(@admin, stub_auth: true)
    assert_no_difference -> { Membership.count } do
      post admin_memberships_url, params: {membership: {user_id: 999_999_999}}
    end
    # A body, not `head :unprocessable_entity`: Turbo replaces the whole page
    # with a non-2xx response, so a bodiless one blanks it. Four routes in this
    # app have been bitten by that.
    assert_response :unprocessable_entity
  end

  test "an admin edits a comped membership's note and end date, storing end-of-day" do
    sign_in_as(@admin, stub_auth: true)
    comped = memberships(:editor_user_comped)
    patch admin_membership_url(comped), params: {
      membership: {note: "Renewed for another year", current_period_end: "2027-06-30"}
    }
    comped.reload
    assert_equal "Renewed for another year", comped.note
    # Same weak-assertion trap as the create test: .to_date alone would pass
    # even if the bug re-truncated this to midnight.
    # .floor(6): see the comment on the equivalent create-path assertion above.
    assert_equal Time.zone.parse("2027-06-30").end_of_day.floor(6), comped.current_period_end
  end

  test "an end date updated through midday of its own last day still grants access" do
    sign_in_as(@admin, stub_auth: true)
    comped = memberships(:editor_user_comped)
    patch admin_membership_url(comped), params: {
      membership: {current_period_end: "2027-01-01"}
    }
    comped.reload

    travel_to Time.zone.parse("2027-01-01 12:00") do
      assert comped.current_period_end > Time.current
    end
  end

  test "updating with a blank end date stores nil" do
    sign_in_as(@admin, stub_auth: true)
    comped = memberships(:editor_user_comped)
    patch admin_membership_url(comped), params: {
      membership: {current_period_end: ""}
    }
    assert_nil comped.reload.current_period_end
  end

  test "a scalar-shaped update body is a 400, not a 500" do
    sign_in_as(@admin, stub_auth: true)
    comped = memberships(:editor_user_comped)
    patch admin_membership_url(comped), params: {membership: "x"}
    assert_equal "Contributor comp", comped.reload.note
    assert_response :bad_request
  end

  test "an editor may not update a comp" do
    sign_in_as(@editor, stub_auth: true)
    comped = memberships(:editor_user_comped)
    patch admin_membership_url(comped), params: {membership: {note: "Should not stick"}}
    assert_equal "Contributor comp", comped.reload.note
    assert_response :redirect
  end

  test "a signed-out visitor may not update a comp" do
    comped = memberships(:editor_user_comped)
    patch admin_membership_url(comped), params: {membership: {note: "Should not stick"}}
    assert_equal "Contributor comp", comped.reload.note
    assert_response :redirect
  end

  test "editing a stripe membership is refused" do
    sign_in_as(@admin, stub_auth: true)
    patch admin_membership_url(@membership), params: {membership: {note: "Should not stick"}}
    assert_nil @membership.reload.note
    assert_response :redirect
  end

  test "an admin revokes a comp" do
    sign_in_as(@admin, stub_auth: true)
    comped = memberships(:editor_user_comped)
    post revoke_admin_membership_url(comped)
    comped.reload
    assert_equal "canceled", comped.status
    assert_not_nil comped.canceled_at
    assert comped.current_period_end <= Time.current
  end

  test "revoking a stripe membership is refused" do
    sign_in_as(@admin, stub_auth: true)
    post revoke_admin_membership_url(@membership)
    assert_equal "active", @membership.reload.status
    assert_response :redirect
  end

  test "an editor may not revoke" do
    sign_in_as(@editor, stub_auth: true)
    comped = memberships(:editor_user_comped)
    post revoke_admin_membership_url(comped)
    assert_equal "active", comped.reload.status
  end

  test "a signed-out visitor may not revoke" do
    comped = memberships(:editor_user_comped)
    post revoke_admin_membership_url(comped)
    assert_equal "active", comped.reload.status
    assert_response :redirect
  end

  test "an admin attaches an unattached membership to a user" do
    sign_in_as(@admin, stub_auth: true)
    orphan = Membership.create!(
      user: nil, source: :stripe, status: :active,
      stripe_subscription_id: "sub_orphan_attach", stripe_customer_id: "cus_orphan_attach"
    )

    post attach_admin_membership_url(orphan), params: {user_id: users(:contractor_user).id}
    assert_equal users(:contractor_user).id, orphan.reload.user_id
    # The durable half of the fix: the next reconcile resolves this customer by
    # the user record rather than needing the link again.
    assert_equal "cus_orphan_attach", users(:contractor_user).reload.stripe_customer_id
  end

  test "attaching does not overwrite a customer id the user already has" do
    sign_in_as(@admin, stub_auth: true)
    orphan = Membership.create!(
      user: nil, source: :stripe, status: :active,
      stripe_subscription_id: "sub_orphan_two", stripe_customer_id: "cus_orphan_two"
    )

    post attach_admin_membership_url(orphan), params: {user_id: users(:regular_user).id}
    assert_equal users(:regular_user).id, orphan.reload.user_id
    assert_equal "cus_regular", users(:regular_user).reload.stripe_customer_id
  end

  test "attaching an already-attached membership is refused" do
    sign_in_as(@admin, stub_auth: true)
    post attach_admin_membership_url(@membership), params: {user_id: users(:contractor_user).id}
    assert_equal users(:regular_user).id, @membership.reload.user_id
    assert_response :redirect
  end

  test "survives an array-valued user_id on attach" do
    # user_id[]=42&user_id[]=99 must not become a Postgres `IN (...) LIMIT 1`
    # that attaches to whichever row Postgres returns first.
    sign_in_as(@admin, stub_auth: true)
    orphan = Membership.create!(
      user: nil, source: :stripe, status: :active,
      stripe_subscription_id: "sub_orphan_array", stripe_customer_id: "cus_orphan_array"
    )

    post attach_admin_membership_url(orphan), params: {user_id: [users(:contractor_user).id, users(:regular_user).id]}
    assert_nil orphan.reload.user_id
    assert_response :redirect
  end

  test "attaching to an unknown user id is refused" do
    sign_in_as(@admin, stub_auth: true)
    orphan = Membership.create!(
      user: nil, source: :stripe, status: :active,
      stripe_subscription_id: "sub_orphan_three", stripe_customer_id: "cus_orphan_three"
    )

    post attach_admin_membership_url(orphan), params: {user_id: 999_999_999}
    assert_nil orphan.reload.user_id
    assert_response :redirect
  end

  test "attaching an unattached non-stripe row to a user who already holds that grant is refused, not a 500" do
    sign_in_as(@admin, stub_auth: true)
    # Nothing in app/ produces an unattached comped/legacy row today (the
    # reachability note on attach's rescue) -- constructed by hand here to
    # exercise the rescue at all.
    orphan = ::Membership.create!(user: nil, source: :comped, status: :active)

    assert_no_difference -> { ::Membership.count } do
      post attach_admin_membership_url(orphan), params: {user_id: users(:editor_user).id}
    end
    assert_nil orphan.reload.user_id
    assert_response :redirect
    assert_equal "That user already has a grant of this type.", flash[:alert]
  end

  test "an editor may not attach" do
    sign_in_as(@editor, stub_auth: true)
    orphan = Membership.create!(
      user: nil, source: :stripe, status: :active,
      stripe_subscription_id: "sub_orphan_four", stripe_customer_id: "cus_orphan_four"
    )

    post attach_admin_membership_url(orphan), params: {user_id: users(:contractor_user).id}
    assert_nil orphan.reload.user_id
  end

  test "a signed-out visitor may not attach" do
    orphan = Membership.create!(
      user: nil, source: :stripe, status: :active,
      stripe_subscription_id: "sub_orphan_five", stripe_customer_id: "cus_orphan_five"
    )

    post attach_admin_membership_url(orphan), params: {user_id: users(:contractor_user).id}
    assert_nil orphan.reload.user_id
    assert_response :redirect
  end

  test "an admin sees the comp form" do
    sign_in_as(@admin, stub_auth: true)
    get new_admin_membership_url
    assert_response :success
  end

  test "an editor is denied the comp form" do
    sign_in_as(@editor, stub_auth: true)
    get new_admin_membership_url
    assert_response :redirect
  end

  test "a signed-out visitor is denied the comp form" do
    get new_admin_membership_url
    assert_response :redirect
  end

  test "an admin sees the edit form for a comp" do
    sign_in_as(@admin, stub_auth: true)
    get edit_admin_membership_url(memberships(:editor_user_comped))
    assert_response :success
  end

  test "an editor is denied the edit form for a comp" do
    sign_in_as(@editor, stub_auth: true)
    get edit_admin_membership_url(memberships(:editor_user_comped))
    assert_response :redirect
  end

  test "a signed-out visitor is denied the edit form for a comp" do
    get edit_admin_membership_url(memberships(:editor_user_comped))
    assert_response :redirect
  end
end
