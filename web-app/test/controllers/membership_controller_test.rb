require "test_helper"

class MembershipControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! Rails.application.config.domains[:books]
    Rails.application.config.x.rate_limit_store.clear
  end

  test "the page renders for a signed-out visitor" do
    get membership_url

    assert_response :success
  end

  test "the page renders for a member" do
    sign_in_as(users(:regular_user), stub_auth: true)

    get membership_url

    assert_response :success
  end

  test "the page is never cached" do
    get membership_url

    assert_includes response.headers["Cache-Control"], "no-store"
  end

  test "the legacy /support url permanently redirects" do
    get "/support"

    assert_response :moved_permanently
    assert_redirected_to "/membership"
  end

  test "the page makes no Stripe api calls" do
    Stripe::Checkout::Session.expects(:create).never
    Stripe::Customer.expects(:create).never
    Stripe::Subscription.expects(:list).never

    get membership_url

    assert_response :success
  end

  test "checkout redirects a signed-in visitor to the stripe session" do
    user = users(:admin_user)
    user.memberships.destroy_all
    user.update!(stripe_customer_id: "cus_existing")
    sign_in_as(user, stub_auth: true)
    Services::Billing::CreateCheckoutSession.expects(:call).returns(
      Services::Billing::CreateCheckoutSession::Result.new(
        success?: true, data: "https://checkout.stripe.com/c/pay/cs_1", errors: []
      )
    )

    post membership_checkout_url, params: {plan: "monthly"}

    assert_redirected_to "https://checkout.stripe.com/c/pay/cs_1"
  end

  test "checkout persists the stripe customer id before redirecting" do
    user = users(:admin_user)
    user.memberships.destroy_all
    user.update!(stripe_customer_id: nil)
    sign_in_as(user, stub_auth: true)
    Stripe::Customer.expects(:create).returns(stub(id: "cus_brand_new"))
    Stripe::Checkout::Session.expects(:create).returns(stub(url: "https://checkout.stripe.com/c/pay/cs_1"))

    post membership_checkout_url, params: {plan: "monthly"}

    assert_equal "cus_brand_new", user.reload.stripe_customer_id
  end

  test "checkout ignores a price id, customer id, user id, success url and cancel url supplied by the client" do
    user = users(:admin_user)
    user.memberships.destroy_all
    user.update!(stripe_customer_id: "cus_existing")
    sign_in_as(user, stub_auth: true)
    canonical_host = Rails.application.config.domains[:books]
    Stripe::Checkout::Session.expects(:create).with(
      has_entries(
        line_items: [{price: billing_plans(:monthly).stripe_price_id, quantity: 1}],
        # customer comes from the signed-in user's own record via EnsureCustomer,
        # never from the customer_id param below. success_url/cancel_url come
        # from canonical_host, never from the params of the same name below.
        customer: "cus_existing",
        success_url: "http://#{canonical_host}/membership/thanks",
        cancel_url: "http://#{canonical_host}/membership"
      )
    ).returns(stub(url: "https://checkout.stripe.com/c/pay/cs_1"))

    post membership_checkout_url,
      params: {
        plan: "monthly",
        stripe_price_id: "price_one_cent",
        user_id: users(:regular_user).id,
        customer_id: "cus_attacker_supplied",
        success_url: "https://attacker.example/success",
        cancel_url: "https://attacker.example/cancel"
      }

    assert_response :redirect
  end

  test "checkout builds success and cancel urls from the canonical domain, not a forged Host header" do
    host! "attacker.example"
    user = users(:admin_user)
    user.memberships.destroy_all
    user.update!(stripe_customer_id: "cus_existing")
    sign_in_as(user, stub_auth: true)
    # detect_current_domain falls back to :books for a Host it does not
    # recognise (see ApplicationController), so :books is the correct
    # expectation here, not the forged "attacker.example".
    canonical_host = Rails.application.config.domains[:books]
    Services::Billing::CreateCheckoutSession.expects(:call).with(
      has_entries(
        success_url: "http://#{canonical_host}/membership/thanks",
        cancel_url: "http://#{canonical_host}/membership"
      )
    ).returns(
      Services::Billing::CreateCheckoutSession::Result.new(
        success?: true, data: "https://checkout.stripe.com/c/pay/cs_1", errors: []
      )
    )

    post membership_checkout_url, params: {plan: "monthly"}

    assert_response :redirect
  end

  test "checkout urls carry no port, even when the request's Host does" do
    canonical_host = Rails.application.config.domains[:books]
    host! "#{canonical_host}:9999"
    user = users(:admin_user)
    user.memberships.destroy_all
    user.update!(stripe_customer_id: "cus_existing")
    sign_in_as(user, stub_auth: true)
    Services::Billing::CreateCheckoutSession.expects(:call).with(
      has_entries(
        success_url: "http://#{canonical_host}/membership/thanks",
        cancel_url: "http://#{canonical_host}/membership"
      )
    ).returns(
      Services::Billing::CreateCheckoutSession::Result.new(
        success?: true, data: "https://checkout.stripe.com/c/pay/cs_1", errors: []
      )
    )

    post membership_checkout_url, params: {plan: "monthly"}

    assert_response :redirect
  end

  test "the portal builds its return url from the canonical domain, ignoring a forged Host header and a return_url param" do
    host! "attacker.example"
    sign_in_as(users(:regular_user), stub_auth: true)
    canonical_host = Rails.application.config.domains[:books]
    Services::Billing::CreatePortalSession.expects(:call).with(
      customer_id: "cus_regular", return_url: "http://#{canonical_host}/membership"
    ).returns(
      Services::Billing::CreatePortalSession::Result.new(
        success?: true, data: "https://billing.stripe.com/p/session/x", errors: []
      )
    )

    post membership_portal_url, params: {return_url: "https://attacker.example/return"}

    assert_response :redirect
  end

  test "checkout rejects an unknown plan key" do
    user = users(:admin_user)
    user.memberships.destroy_all
    sign_in_as(user, stub_auth: true)
    Stripe::Checkout::Session.expects(:create).never

    post membership_checkout_url, params: {plan: "free_forever"}

    assert_redirected_to membership_path
  end

  test "checkout rejects an inactive plan" do
    user = users(:admin_user)
    user.memberships.destroy_all
    sign_in_as(user, stub_auth: true)
    Stripe::Checkout::Session.expects(:create).never

    post membership_checkout_url, params: {plan: billing_plans(:retired_monthly).key}

    assert_redirected_to membership_path
  end

  test "checkout rejects the donation plan key" do
    # The donation plan is kind: donation and must not be buyable as a membership.
    user = users(:admin_user)
    user.memberships.destroy_all
    sign_in_as(user, stub_auth: true)
    Stripe::Checkout::Session.expects(:create).never

    post membership_checkout_url, params: {plan: "donation"}

    assert_redirected_to membership_path
  end

  test "an existing member is sent to the portal instead of buying twice" do
    sign_in_as(users(:regular_user), stub_auth: true)
    Stripe::Checkout::Session.expects(:create).never
    Stripe::BillingPortal::Session.expects(:create).returns(stub(url: "https://billing.stripe.com/p/session/x"))

    post membership_checkout_url, params: {plan: "monthly"}

    assert_redirected_to "https://billing.stripe.com/p/session/x"
  end

  test "a comped member who clicks Join is told they are already a member, not sent to a billing error" do
    user = users(:editor_user) # comped: a member, but never billed -- no stripe_customer_id
    sign_in_as(user, stub_auth: true)
    Stripe::Checkout::Session.expects(:create).never
    Stripe::BillingPortal::Session.expects(:create).never

    post membership_checkout_url, params: {plan: "monthly"}

    assert_redirected_to membership_path
    assert flash[:notice].present?
    refute_match(/billing account/, flash[:notice].to_s)
  end

  test "checkout requires sign in" do
    Stripe::Checkout::Session.expects(:create).never

    post membership_checkout_url, params: {plan: "monthly"}

    assert_response :redirect
    refute_match(/checkout\.stripe\.com/, response.location)
  end

  test "a donation does not require sign in" do
    Stripe::Checkout::Session.expects(:create).returns(stub(url: "https://checkout.stripe.com/c/pay/cs_donate"))

    post membership_donate_url

    assert_redirected_to "https://checkout.stripe.com/c/pay/cs_donate"
  end

  test "a donation by a signed-out visitor creates no stripe customer" do
    Stripe::Customer.expects(:create).never
    Stripe::Checkout::Session.expects(:create).returns(stub(url: "https://checkout.stripe.com/c/pay/cs_donate"))

    post membership_donate_url

    assert_response :redirect
  end

  test "the portal requires a stripe customer" do
    user = users(:editor_user) # comped: a member, but never billed
    user.update!(stripe_customer_id: nil)
    sign_in_as(user, stub_auth: true)
    Stripe::BillingPortal::Session.expects(:create).never

    post membership_portal_url

    assert_redirected_to membership_path
  end

  test "thanks reconciles the signed-in visitor's own customer" do
    user = users(:regular_user)
    user.update!(stripe_customer_id: "cus_regular")
    sign_in_as(user, stub_auth: true)
    Services::Billing::ReconcileCustomer.expects(:call).with(stripe_customer_id: "cus_regular").returns(
      Services::Billing::ReconcileCustomer::Result.new(success?: true, data: [], errors: [])
    )

    get membership_thanks_url

    assert_response :success
  end

  test "thanks grants nothing when hit directly by a non-member" do
    user = users(:admin_user)
    user.memberships.destroy_all
    user.update!(stripe_customer_id: nil)
    sign_in_as(user, stub_auth: true)
    Services::Billing::ReconcileCustomer.expects(:call).never

    get membership_thanks_url

    assert_response :success
    refute user.reload.member?
  end

  test "thanks works for a signed-out visitor without reconciling anything" do
    Services::Billing::ReconcileCustomer.expects(:call).never

    get membership_thanks_url

    assert_response :success
  end

  test "a failed checkout session sends the visitor back with a message" do
    user = users(:admin_user)
    user.memberships.destroy_all
    user.update!(stripe_customer_id: "cus_existing")
    sign_in_as(user, stub_auth: true)
    Stripe::Checkout::Session.expects(:create).raises(Stripe::APIConnectionError.new("down"))

    post membership_checkout_url, params: {plan: "monthly"}

    assert_redirected_to membership_path
    assert flash[:alert].present?
    # The visitor must never see the raw Stripe exception message: Stripe
    # echoes request parameters in some error strings, and that is exactly the
    # customer PII the "log the class, never the message" rule exists to
    # contain. checkout_error is the only string this path may flash.
    refute_match(/down/, flash[:alert])
  end

  test "checkout is rate limited" do
    user = users(:admin_user)
    user.memberships.destroy_all
    user.update!(stripe_customer_id: "cus_existing")
    sign_in_as(user, stub_auth: true)
    Stripe::Checkout::Session.stubs(:create).returns(stub(url: "https://checkout.stripe.com/c/pay/cs_1"))

    11.times { post membership_checkout_url, params: {plan: "monthly"} }

    assert_redirected_to membership_path
    assert_match(/Too many attempts/, flash[:alert])
  end

  test "thanks and donate have independent rate limit buckets" do
    Stripe::Checkout::Session.stubs(:create).returns(stub(url: "https://checkout.stripe.com/c/pay/cs_donate"))

    # Exhausts :thanks' own (larger) budget -- this is the traffic every
    # successful payer generates landing back from Stripe, all sharing one
    # apparent IP at a busy Cloudflare edge.
    31.times { get membership_thanks_url }
    # A real donor at the same edge, hitting :donate for the first time this
    # minute, must not inherit :thanks' count.
    post membership_donate_url

    assert_redirected_to "https://checkout.stripe.com/c/pay/cs_donate"
  end

  test "the donate rate limit keys on CF-Connecting-IP, not the shared edge ip" do
    Stripe::Checkout::Session.stubs(:create).returns(stub(url: "https://checkout.stripe.com/c/pay/cs_donate"))

    11.times { post membership_donate_url, headers: {"CF-Connecting-IP" => "203.0.113.5"} }
    # A different real visitor, arriving through the same Cloudflare PoP (so the
    # same request.remote_ip in this environment) but with their own
    # CF-Connecting-IP, must not inherit the first visitor's count.
    post membership_donate_url, headers: {"CF-Connecting-IP" => "203.0.113.9"}

    assert_redirected_to "https://checkout.stripe.com/c/pay/cs_donate"
  end
end
