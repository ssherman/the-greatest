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

  # These three assert that the right STORY renders per host, not that the copy
  # says anything in particular. Each matches one short distinctive phrase; if
  # the copy is rewritten, update the phrase here and nothing else.
  test "the books host renders the books story" do
    host! Rails.application.config.domains[:books]

    get membership_url

    assert_match "In 2009", response.body
  end

  test "the music host renders the music story" do
    host! Rails.application.config.domains[:music]

    get membership_url

    assert_match "greatest albums", response.body
    assert_no_match(/In 2009/, response.body)
  end

  test "the games host renders the games story" do
    host! Rails.application.config.domains[:games]

    get membership_url

    assert_match "spreadsheet", response.body
    assert_no_match(/In 2009/, response.body)
  end

  test "an unrecognised host still renders the page" do
    # detect_current_domain (ApplicationController) falls back to :books for a
    # Host it does not recognise -- a pre-existing, app-wide default that
    # predates this feature and is out of scope to change here -- so this
    # particular host renders the books story, not the site-neutral one. See
    # the next test for a host that genuinely reaches the site-neutral path.
    host! "unknown.example.com"

    get membership_url

    assert_response :success
  end

  test "the configured domain with no story of its own renders the site-neutral story, not another site's" do
    # The membership route is deliberately global -- "one membership covers
    # every site, so there is one set of URLs served on every host" (see
    # config/routes.rb) -- and config.domains has one more entry than
    # STORY_DOMAINS covers, so a real request with that domain's own
    # configured Host reaches membership_story_partial's fallback branch over
    # HTTP today, live in production. Derived rather than named so this stays
    # correct if the set of configured domains ever changes -- what's under
    # test is "whatever isn't books/music/games gets the neutral story", not
    # any one specific host.
    extra_domain = (Rails.application.config.domains.keys - MembershipHelper::STORY_DOMAINS.map(&:to_sym)).first
    host! Rails.application.config.domains[extra_domain]

    get membership_url

    assert_response :success
    assert_no_match(/In 2009/, response.body)
    assert_no_match(/greatest albums/, response.body)
    assert_no_match(/spreadsheet/, response.body)
  end

  test "plan prices come from the database" do
    billing_plans(:monthly).update!(amount_cents: 700)

    get membership_url

    assert_match "$7", response.body
  end

  # Turbo Drive hijacks button_to submissions via fetch(), and a fetch cannot
  # follow the 303 these actions issue to checkout.stripe.com/billing.stripe.com
  # cross-origin -- the browser rejects it as a CORS request and the button just
  # goes idle. data-turbo="false" on the submitter is what makes the browser
  # submit the form natively instead, so it follows the redirect itself. Rails'
  # button_to puts html_options (including data:) on the <button>, not the
  # <form> -- assert against the actual element, not merely "somewhere in the
  # response body", so a future edit that moves the attribute to the wrong tag
  # (or drops it) is caught.
  test "the donate button submits natively, not through Turbo" do
    get membership_url

    assert_select "form[action=?] button[data-turbo='false']", membership_donate_path
  end

  test "the join buttons submit natively, not through Turbo" do
    user = users(:admin_user)
    user.memberships.destroy_all
    sign_in_as(user, stub_auth: true)

    get membership_url

    assert_select "form[action=?] button[data-turbo='false']", membership_checkout_path, minimum: 1
  end

  test "the manage billing button submits natively, not through Turbo" do
    sign_in_as(users(:regular_user), stub_auth: true)

    get membership_url

    assert_select "form[action=?] button[data-turbo='false']", membership_portal_path
  end

  test "an inactive plan is not offered" do
    get membership_url

    assert_no_match(/#{Regexp.escape(billing_plans(:retired_monthly).name)}/, response.body)
  end

  test "the page still renders when no plans are configured" do
    # Production reaches this state between the deploy and stripe:sync_plans, and
    # a 500 on /membership would be the first thing a visitor sees.
    BillingPlan.delete_all

    get membership_url

    assert_response :success
  end

  test "a flash alert reaches the page after a failing action redirects and is followed" do
    user = users(:admin_user)
    user.memberships.destroy_all
    sign_in_as(user, stub_auth: true)

    post membership_checkout_url, params: {plan: "free_forever"}
    follow_redirect!

    assert_match "That membership option is not available.", response.body
  end

  test "a flash notice reaches the page after a redirect and is followed" do
    user = users(:editor_user) # comped: a member, but never billed -- no stripe_customer_id
    sign_in_as(user, stub_auth: true)

    post membership_checkout_url, params: {plan: "monthly"}
    follow_redirect!

    # Not "You're already a member": ERB auto-escapes the apostrophe to
    # &#39;, so a literal one in the assertion would never match the body.
    assert_match "already a member -- thank you for your support", response.body
  end
end
