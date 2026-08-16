require "test_helper"

class Admin::StripeEventsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin_user)
    @editor = users(:editor_user)
    host! Rails.application.config.domains[:music]
  end

  def failed_event
    StripeEvent.create!(
      stripe_event_id: "evt_admin_failed", event_type: "customer.subscription.updated",
      payload: {"data" => {"object" => {"object" => "subscription", "customer" => "cus_admin"}}},
      livemode: false, status: :failed, stripe_created_at: Time.current, error: "Boom"
    )
  end

  test "an admin sees the index" do
    sign_in_as(@admin, stub_auth: true)
    get admin_stripe_events_url
    assert_response :success
  end

  test "an editor is denied the index" do
    sign_in_as(@editor, stub_auth: true)
    get admin_stripe_events_url
    assert_response :redirect
  end

  test "a signed-out visitor is denied the index" do
    get admin_stripe_events_url
    assert_response :redirect
  end

  test "filters by status" do
    sign_in_as(@admin, stub_auth: true)
    get admin_stripe_events_url(status: "failed")
    assert_response :success
  end

  test "ignores a status that is not a known enum value" do
    sign_in_as(@admin, stub_auth: true)
    get admin_stripe_events_url(status: "nonsense")
    assert_response :success
  end

  test "survives an array-valued search param" do
    sign_in_as(@admin, stub_auth: true)
    get admin_stripe_events_url("q" => ["cus_admin"])
    assert_response :success
  end

  test "an admin sees the detail page" do
    sign_in_as(@admin, stub_auth: true)
    get admin_stripe_event_url(failed_event)
    assert_response :success
  end

  test "an editor is denied the detail page" do
    sign_in_as(@editor, stub_auth: true)
    get admin_stripe_event_url(failed_event)
    assert_response :redirect
  end

  test "an admin re-enqueues a failed event" do
    sign_in_as(@admin, stub_auth: true)
    event = failed_event
    ::Billing::ProcessStripeEventJob.expects(:perform_async).with(event.id).once

    post reprocess_admin_stripe_event_url(event)
    assert_redirected_to admin_stripe_event_url(event)
  end

  test "an editor may not re-enqueue" do
    sign_in_as(@editor, stub_auth: true)
    event = failed_event
    ::Billing::ProcessStripeEventJob.expects(:perform_async).never

    post reprocess_admin_stripe_event_url(event)
    assert_response :redirect
  end

  test "a processed event cannot be re-enqueued" do
    sign_in_as(@admin, stub_auth: true)
    event = failed_event
    event.mark_processed!
    ::Billing::ProcessStripeEventJob.expects(:perform_async).never

    post reprocess_admin_stripe_event_url(event)
    assert_response :redirect
  end

  test "an ignored event cannot be re-enqueued" do
    sign_in_as(@admin, stub_auth: true)
    event = failed_event
    event.mark_ignored!("livemode mismatch")
    ::Billing::ProcessStripeEventJob.expects(:perform_async).never

    post reprocess_admin_stripe_event_url(event)
    assert_response :redirect
  end

  test "re-enqueueing is not reachable by GET" do
    # Asked of the routing table directly, not through an integration request:
    # with show_exceptions set to :rescuable in test, a routing failure comes
    # back as a 404 rather than an exception, which would make an assert_raises
    # around `get` pass or fail for the wrong reason.
    assert_raises(ActionController::RoutingError) do
      Rails.application.routes.recognize_path("/admin/stripe_events/1/reprocess", method: :get)
    end
    assert_equal(
      {controller: "admin/stripe_events", action: "reprocess", id: "1"},
      Rails.application.routes.recognize_path("/admin/stripe_events/1/reprocess", method: :post)
    )
  end
end
