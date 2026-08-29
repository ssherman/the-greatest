require "test_helper"

class ListSubmissionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "dev-new.thegreatestbooks.org"
    @user = users(:regular_user)
    @params = {
      list: {name: "Greatest Books Ever", source: "The Times",
             url: "https://example.com/greatest", description: "A list."},
      list_type: "Books::List"
    }
    # The rate limit store is a single MemoryStore instance shared by the whole
    # process (config/initializers/rate_limit_store.rb) -- without clearing it
    # here, whichever test runs after enough anonymous submissions trips the
    # limit instead of the dedicated rate-limit test below. Same fix as
    # CorrectionsControllerTest's and ReviewsControllerTest's setup.
    Rails.application.config.x.rate_limit_store.clear
  end

  test "new renders the form" do
    get "/lists/new"

    assert_response :success
    assert_select "form[action=?]", "/list_submissions"
  end

  # Read the books layout's robots helper and match this assertion to the markup it
  # ACTUALLY emits before running the test -- the selector below is the expected
  # shape, not verified output. Books defaults to noindex unless @indexable is
  # truthy, so this passes on books either way; the assertion exists to pin it.
  test "new is not indexable" do
    get "/lists/new"

    assert_response :success
    assert_select "meta[name=robots][content*=?]", "noindex"
  end

  test "new does not render a type picker on books" do
    get "/lists/new"

    assert_response :success
    assert_select "input[name=list_type][type=radio]", count: 0
  end

  test "create stores an anonymous submission and redirects to thanks" do
    assert_difference "Books::List.count", 1 do
      post "/list_submissions", params: @params
    end

    assert_redirected_to "/lists/thanks"
    list = Books::List.order(:created_at).last
    assert list.unapproved?
    assert_not_nil list.submitted_at
    assert_nil list.submitted_by
  end

  test "create attributes a signed-in submission" do
    sign_in_as(@user, stub_auth: true)

    post "/list_submissions", params: @params

    assert_redirected_to "/lists/thanks"
    assert_equal @user, Books::List.order(:created_at).last.submitted_by
  end

  test "create stores an anonymous submitter email" do
    post "/list_submissions", params: @params.merge(submitter_email: "reader@example.com")

    assert_equal "reader@example.com", Books::List.order(:created_at).last.submitter_email
  end

  test "a filled honeypot is discarded but still looks like success" do
    assert_no_difference "Books::List.count" do
      post "/list_submissions", params: @params.merge(website: "http://spam.example")
    end

    assert_redirected_to "/lists/thanks"
  end

  test "create re-renders the form with an error when the name is blank" do
    assert_no_difference "Books::List.count" do
      post "/list_submissions", params: @params.deep_merge(list: {name: ""})
    end

    assert_response :unprocessable_entity
  end

  test "create tells the submitter when the url is already known" do
    Books::List.create!(name: "Already here", status: :active,
      url: "https://example.com/greatest")

    assert_no_difference "Books::List.count" do
      post "/list_submissions", params: @params
    end

    assert_response :unprocessable_entity
    assert_match(/already have this list/i, response.body)
  end

  test "create rejects a list type the domain does not accept" do
    post "/list_submissions", params: @params.merge(list_type: "Music::Albums::List")

    assert_response :bad_request
  end

  test "create rejects an unknown list type without constantizing it" do
    post "/list_submissions", params: @params.merge(list_type: "Kernel")

    assert_response :bad_request
  end

  test "thanks renders" do
    get "/lists/thanks"

    assert_response :success
  end

  test "create notifies the owner" do
    AdminMailer.expects(:new_list_submission).once.returns(stub(deliver_later: true))

    post "/list_submissions", params: @params
  end

  test "an anonymous submitter is rate limited" do
    (ListSubmissionsController::ANONYMOUS_RATE + 1).times do |i|
      post "/list_submissions", params: @params.deep_merge(list: {url: "https://example.com/anon-#{i}"}),
        headers: {"CF-Connecting-IP" => "198.51.100.9"}
    end

    assert_response :too_many_requests
    assert_select ".alert-error", "Thanks — you've sent us several lists just now. Please try again shortly."
  end

  # request.remote_ip is a constant "127.0.0.1" for every request in this test
  # process regardless of what CF-Connecting-IP carries (ActionDispatch::RemoteIp
  # does not fold that header in -- confirmed empirically, not assumed), so a
  # single-anonymous-submitter loop trips at the same iteration count whichever
  # field by: reads, even with an explicit header set throughout. The only test
  # shape that can tell visitor_ip and remote_ip apart is two DIFFERENT visitor
  # ips: with by: visitor_ip each gets its own bucket and both loops below
  # succeed in full; with by: request.remote_ip -- the production bug that
  # shares one bucket across every visitor behind Cloudflare -- the second
  # visitor's requests land in the SAME already-exhausted bucket as the
  # first's, and the second loop's last request comes back rate limited
  # instead of redirecting.
  test "an anonymous rate limit is keyed on visitor ip, not the shared remote_ip" do
    ListSubmissionsController::ANONYMOUS_RATE.times do |i|
      post "/list_submissions", params: @params.deep_merge(list: {url: "https://example.com/ip-a-#{i}"}),
        headers: {"CF-Connecting-IP" => "198.51.100.9"}
    end
    assert_response :redirect

    ListSubmissionsController::ANONYMOUS_RATE.times do |i|
      post "/list_submissions", params: @params.deep_merge(list: {url: "https://example.com/ip-b-#{i}"}),
        headers: {"CF-Connecting-IP" => "203.0.113.5"}
    end
    assert_response :redirect
  end

  # In the migrated corrections corpus one user submitted 27 corrections inside
  # a single hour; the same shape motivates a separate, higher cap for a
  # signed-in contributor here. The anonymous cap must not apply to them.
  test "a signed-in submitter is not held to the anonymous cap" do
    sign_in_as(@user, stub_auth: true)

    (ListSubmissionsController::ANONYMOUS_RATE + 1).times do |i|
      post "/list_submissions", params: @params.deep_merge(list: {url: "https://example.com/signed-in-not-anon-#{i}"}),
        headers: {"CF-Connecting-IP" => "198.51.100.9"}
    end

    assert_response :redirect
  end

  test "rate limits a signed-in submitter at the higher cap" do
    sign_in_as(@user, stub_auth: true)

    (ListSubmissionsController::SIGNED_IN_RATE + 1).times do |i|
      post "/list_submissions", params: @params.deep_merge(list: {url: "https://example.com/signed-in-cap-#{i}"})
    end

    assert_response :too_many_requests
    assert_select ".alert-error", "Thanks — you've sent us several lists just now. Please try again shortly."
  end

  # The signed-in limiter keys on user id, so one heavy contributor cannot
  # throttle another.
  test "two signed-in submitters do not share a rate limit bucket" do
    sign_in_as(@user, stub_auth: true)

    ListSubmissionsController::SIGNED_IN_RATE.times do |i|
      post "/list_submissions", params: @params.deep_merge(list: {url: "https://example.com/user-one-#{i}"})
    end
    assert_response :redirect

    sign_in_as(users(:admin_user), stub_auth: true)
    post "/list_submissions", params: @params.deep_merge(list: {url: "https://example.com/user-two"})

    assert_response :redirect
  end

  # ActionController::Parameters#fetch only wraps a Hash or Array value in a new
  # Parameters instance -- a scalar list param (list=x) or an array one
  # (list[]=x) comes back as-is, and String/Array have no #permit. Without the
  # is_a? guard in list_params this is a 500 any anonymous client can trigger in
  # a loop, on a public write endpoint across three live sites.
  #
  # 422, not 400: the guard replaces the scalar with an empty Parameters, so
  # nothing raises -- it reaches Submission.call with no attributes at all,
  # which fails the same name-presence validation as any other empty
  # submission and re-renders the form. The point being pinned is that this is
  # an ordinary handled validation failure, not a crash.
  test "a non-hash list param is a client error, not a server error" do
    post "/list_submissions", params: {list: "x", list_type: "Books::List"}

    assert_response :unprocessable_entity
  end

  # These three exist to stop the anti-DDoS hole this whole feature was built to
  # close from coming back through the routing table -- see the comment above
  # the routes in config/routes.rb. The pages are edge-cached; ListSubmissionsController
  # never calls load_ranking_configuration, so while these routes sat inside
  # scope "(/rc/:ranking_configuration_id)" (or without the format constraint),
  # every distinct segment or format value would be a new Cloudflare cache key
  # and a new full render at origin. A routing error is the cheapest possible
  # rejection -- no controller, no view, no database.
  #
  # Both halves of assert_unroutable matter, same as CorrectionsControllerTest's
  # copy of this helper: the status alone would pass a route that 404s from the
  # controller after a full render; the absent cache header alone would pass a
  # 200 that merely forgot to cache. Together they say nothing was rendered and
  # Cloudflare has nothing to key on.
  def assert_unroutable(path)
    get path

    assert_response :not_found
    assert_nil response.headers["Cache-Control"],
      "#{path} still answers with a cache header, so it is still a cacheable origin hit"
  end

  test "an rc-prefixed list submission form url does not resolve" do
    assert_unroutable "/rc/99999/lists/new"
  end

  test "a non-numeric rc-prefixed list submission thanks url does not resolve" do
    assert_unroutable "/rc/anything/lists/thanks"
  end

  test "a format-suffixed list submission form url does not resolve" do
    assert_unroutable "/lists/new.json"
  end

  test "games renders the form without a type picker" do
    host! "dev.thegreatest.games"

    get "/lists/new"

    assert_response :success
    assert_select "input[name=list_type][type=radio]", count: 0
  end

  test "games creates a games list" do
    host! "dev.thegreatest.games"

    assert_difference "Games::List.count", 1 do
      post "/list_submissions", params: {
        list: {name: "Greatest Games", url: "https://example.com/games"},
        list_type: "Games::List"
      }
    end

    assert_redirected_to "/lists/thanks"
  end

  # Same DDoS-hardening rationale as the books block above -- games' lists/new
  # and lists/thanks sit right next to a scope "(/rc/:ranking_configuration_id)"
  # block that wraps the show/index routes, so it is easy to mis-place them a
  # line too low and reopen the unbounded cache-key hole.
  test "an rc-prefixed games list submission form url does not resolve" do
    host! "dev.thegreatest.games"

    assert_unroutable "/rc/99999/lists/new"
  end

  test "a non-numeric rc-prefixed games list submission thanks url does not resolve" do
    host! "dev.thegreatest.games"

    assert_unroutable "/rc/anything/lists/thanks"
  end

  test "a format-suffixed games list submission form url does not resolve" do
    host! "dev.thegreatest.games"

    assert_unroutable "/lists/new.json"
  end

  test "music renders a type picker with both list types" do
    host! "dev.thegreatestmusic.org"

    get "/lists/new"

    assert_response :success
    assert_select "input[name=list_type][value=?]", "Music::Albums::List"
    assert_select "input[name=list_type][value=?]", "Music::Songs::List"
  end

  test "music creates an album list when albums is chosen" do
    host! "dev.thegreatestmusic.org"

    assert_difference "Music::Albums::List.count", 1 do
      post "/list_submissions", params: {
        list: {name: "Greatest Albums", url: "https://example.com/albums"},
        list_type: "Music::Albums::List"
      }
    end

    assert_redirected_to "/lists/thanks"
  end

  test "music creates a song list when songs is chosen" do
    host! "dev.thegreatestmusic.org"

    assert_difference "Music::Songs::List.count", 1 do
      post "/list_submissions", params: {
        list: {name: "Greatest Songs", url: "https://example.com/songs"},
        list_type: "Music::Songs::List"
      }
    end

    assert_redirected_to "/lists/thanks"
  end

  test "music rejects a submission with no type chosen" do
    host! "dev.thegreatestmusic.org"

    post "/list_submissions", params: {list: {name: "No type"}}

    assert_response :bad_request
  end

  # Music has no rc-scoped equivalent of the lists routes to accidentally
  # collide with (its "lists" route lives in a plain `scope as: "music"`
  # block, not under `scope "(/rc/:ranking_configuration_id)"`), so an
  # rc-prefixed hardening test would pin nothing this change could break.
  # The format axis is still unconstrained by default on any GET, so that
  # one test carries over.
  test "a format-suffixed music list submission form url does not resolve" do
    host! "dev.thegreatestmusic.org"

    assert_unroutable "/lists/new.json"
  end
end
