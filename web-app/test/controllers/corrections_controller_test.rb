require "test_helper"

class CorrectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "dev-new.thegreatestbooks.org"
    @book = books_books(:war_and_peace)

    # The rate limit store is a single MemoryStore instance shared by the whole
    # process (config/initializers/rate_limit_store.rb) -- without clearing it
    # here, whichever test runs after enough anonymous submissions trips the
    # limit instead of the dedicated rate-limit test below. Same fix as
    # ReviewsControllerTest's setup, for the same reason.
    Rails.application.config.x.rate_limit_store.clear
  end

  test "renders the form for a book" do
    get books_book_correction_path(slug: @book.slug)

    assert_response :success
  end

  test "404s for an unknown slug" do
    get books_book_correction_path(slug: "no-such-book")

    assert_response :not_found
  end

  # These six tests exist to stop the anti-DDoS hole this whole feature was built
  # to close from coming back through the routing table.
  #
  # The correction pages are edge-cached for 24 hours. CorrectionsController never
  # calls load_ranking_configuration -- it renders record fields, not rankings --
  # so while these routes sat inside `scope "(/rc/:ranking_configuration_id)"`,
  # /rc/<anything>/book/:slug/suggest-correction returned 200 with
  # `Cache-Control: public, max-age=86400`. Every distinct segment value is a
  # distinct Cloudflare cache key, so every one is a MISS and a full render at
  # origin: exactly the flood that took the legacy page down, with one extra path
  # segment, and a Cache Rule that normalises query strings cannot see it.
  #
  # A routing error is the cheapest possible rejection -- no controller, no view,
  # no database. Constraining the segment to /\d+/ would NOT be equivalent, since
  # there are unbounded distinct integers.
  #
  # Both halves of assert_unroutable matter. The status alone would pass on a
  # route that answered 404 from the controller after a full render; the absent
  # public cache header alone would pass on a 200 that merely forgot to cache.
  # Together they say what the fix is for: nothing was rendered, and Cloudflare
  # has nothing to key on.
  def assert_unroutable(path)
    get path

    assert_response :not_found
    assert_nil response.headers["Cache-Control"],
      "#{path} still answers with a cache header, so it is still a cacheable origin hit"
  end

  test "an rc-prefixed correction form url does not resolve for a book" do
    assert_unroutable "/rc/99999/book/#{@book.slug}/suggest-correction"
  end

  test "an rc-prefixed correction thanks url does not resolve for a book" do
    assert_unroutable "/rc/99999/book/#{@book.slug}/suggest-correction/thanks"
  end

  # A non-numeric segment too: constraining the segment to /\d+/ would leave this
  # one rejected but still admit unbounded distinct integers, which is why the
  # scope is gone rather than constrained.
  test "a non-numeric rc-prefixed correction url does not resolve for a book" do
    assert_unroutable "/rc/anything/book/#{@book.slug}/suggest-correction"
  end

  test "an rc-prefixed correction form url does not resolve for a music album" do
    host! "dev.thegreatestmusic.org"

    assert_unroutable "/rc/99999/album/#{music_albums(:dark_side_of_the_moon).slug}/suggest-correction"
  end

  test "an rc-prefixed correction form url does not resolve for a game" do
    host! "dev.thegreatest.games"

    assert_unroutable "/rc/99999/game/#{games_games(:breath_of_the_wild).slug}/suggest-correction"
  end

  # (.:format) is the same unbounded cache-key axis one level down -- .json, .foo,
  # .anything is another distinct key on a page cached for a day. constraints:
  # {format: /html/} closes it, following the news routes' existing precedent.
  test "a format-suffixed correction url does not resolve" do
    assert_unroutable "/book/#{@book.slug}/suggest-correction.json"
  end

  # The three public show pages ARE inside the rc scope, so their correction link
  # is generated from a request that has a ranking_configuration_id in scope. It
  # must still generate, and it must NOT pick the segment up -- an rc-prefixed
  # href would be a link straight back into the hole above.
  test "the book show page links to the correction form with no rc prefix, even under an rc prefix" do
    rc = ranking_configurations(:books_inherited)

    get "/rc/#{rc.id}/book/#{@book.slug}"

    assert_response :success
    assert_select "a[href=?]", "/book/#{@book.slug}/suggest-correction"
  end

  test "the album show page links to the correction form with no rc prefix, even under an rc prefix" do
    host! "dev.thegreatestmusic.org"
    album = music_albums(:dark_side_of_the_moon)
    rc = ranking_configurations(:music_albums_secondary)

    get "/rc/#{rc.id}/album/#{album.slug}"

    assert_response :success
    assert_select "a[href=?]", "/album/#{album.slug}/suggest-correction"
  end

  test "the game show page links to the correction form with no rc prefix, even under an rc prefix" do
    host! "dev.thegreatest.games"
    game = games_games(:breath_of_the_wild)
    rc = ranking_configurations(:games_secondary)

    get "/rc/#{rc.id}/game/#{game.slug}"

    assert_response :success
    assert_select "a[href=?]", "/game/#{game.slug}/suggest-correction"
  end

  # The whole point of caching this page: it is the surface that took the live
  # site down when it was uncached.
  test "is publicly cacheable" do
    get books_book_correction_path(slug: @book.slug)

    assert_match(/public/, response.headers["Cache-Control"])
    assert_match(/max-age=86400/, response.headers["Cache-Control"])
  end

  # allow_forgery_protection is off for the whole test environment (config/environments/test.rb),
  # so csrf_meta_tags renders nothing and never writes a session token -- this request would
  # never touch session, and the assertion below could never fail, with or without
  # skip_session_for_caching doing its job. Flipping protection on for the duration of this one
  # request (same pattern as reviews_controller_test.rb's "422s and stays a turbo stream when the
  # csrf token is invalid") makes csrf_meta_tags actually generate and store a real token, which
  # is exactly the write skip_session_for_caching exists to keep out of the response. Restored in
  # an ensure -- the suite runs parallel, and this is a global class attribute. Do not "simplify"
  # this back to a plain get: without the flip this test cannot go red, ever.
  test "sets no session cookie, so Cloudflare does not bypass the cache" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    get books_book_correction_path(slug: @book.slug)

    assert_nil response.headers["Set-Cookie"]
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  # THIS TEST CANNOT FAIL, AND IT CANNOT BE MADE TO ON BOOKS. Books::DefaultHelper
  # renders `@indexable ? "index, follow" : "noindex, follow"`, so a nil @indexable
  # already produces "noindex, follow" -- delete `@indexable = false` from
  # CorrectionsController#new and this still passes. It is kept as documentation
  # that the page is deliberately not indexed, on the domain the feature was built
  # against.
  #
  # The assertion with teeth is "is not indexable for a music album" below (and the
  # games equivalent): Music::DefaultHelper and Games::DefaultHelper both render
  # `(@indexable == false) ? "noindex, follow" : "index, follow"`, so on those two
  # domains the controller line is the only thing producing noindex. Verified by
  # deleting it and watching both go red.
  test "is not indexable" do
    get books_book_correction_path(slug: @book.slug)

    assert_select "meta[name=robots][content=?]", "noindex, follow"
  end

  def submit(params = {})
    post corrections_path, params: {
      correctable_type: "Books::Book",
      correctable_id: @book.id,
      correction: {notes: "The year is wrong"}
    }.deep_merge(params)
  end

  test "creates a correction anonymously and redirects to the thanks page" do
    assert_difference -> { Correction.count }, 1 do
      submit
    end

    assert_redirected_to books_book_correction_thanks_path(slug: @book.slug)
    assert_nil Correction.last.user
  end

  test "attaches the signed-in user" do
    sign_in_as(users(:regular_user), stub_auth: true)
    submit

    assert_equal users(:regular_user), Correction.last.user
  end

  test "records the Cloudflare connecting ip, not the edge ip" do
    post corrections_path,
      params: {correctable_type: "Books::Book", correctable_id: @book.id, correction: {notes: "wrong"}},
      headers: {"CF-Connecting-IP" => "198.51.100.4"}

    assert_equal "198.51.100.4", Correction.last.submitter_ip
  end

  # BOTH fields are submitted and only one of them moved. Submitting just the
  # moved one -- which is what this test used to do -- passes with Submission's
  # `next if current == proposed` deleted, because with a single moved field
  # "every submitted field" and "every moved field" are the same list. The
  # unchanged title is what makes the two lists differ. Its value is war_and_peace's
  # actual fixture title, so the form's own prefill would submit exactly this.
  test "creates a field row only for the value that moved, not for every field submitted" do
    submit(correction: {fields: {first_published_year: "1867", title: @book.title}})

    assert_equal %w[first_published_year], Correction.last.correction_fields.map(&:field_name)
  end

  test "rejects an unknown correctable type without constantizing it" do
    post corrections_path, params: {
      correctable_type: "Kernel", correctable_id: 1, correction: {notes: "x"}
    }

    assert_response :bad_request
  end

  test "rejects a correctable type that is not correctable" do
    post corrections_path, params: {
      correctable_type: "Books::Edition", correctable_id: 1, correction: {notes: "x"}
    }

    assert_response :bad_request
  end

  # Accept-and-discard: a bot that gets a 200 stops retrying, and one that gets a
  # 422 comes back. Same redirect target as a real success -- see the next test
  # -- so a bot cannot tell its submission was discarded.
  test "silently discards a submission with the honeypot filled" do
    assert_no_difference -> { Correction.count } do
      submit(website: "http://spam.example")
    end

    assert_redirected_to books_book_correction_thanks_path(slug: @book.slug)
  end

  test "re-renders with an error when nothing was submitted" do
    post corrections_path, params: {
      correctable_type: "Books::Book", correctable_id: @book.id, correction: {notes: ""}
    }

    assert_response :unprocessable_entity
    assert_match(/no-store/, response.headers["Cache-Control"])
    assert_select "[data-testid=correction-error]", "Tell us what's wrong, or propose a change to at least one field"
  end

  # The submitter is TOLD, through the same inline error the empty-submission case
  # uses. An over-cap value is never silently truncated -- half a sentence stored
  # as a proposal is worse than no proposal, because an admin may apply it.
  test "rejects an over-length field value with a visible error rather than truncating it" do
    assert_no_difference -> { Correction.count } do
      submit(correction: {fields: {title: "x" * (Correction::MAX_FIELD_VALUE_LENGTH + 1)}})
    end

    assert_response :unprocessable_entity
    assert_select "[data-testid=correction-error]", /Title is too long/
  end

  test "never caches the create response" do
    submit

    assert_match(/no-store/, response.headers["Cache-Control"])
  end

  test "rate limits by ip and re-renders the form with an inline error rather than raising" do
    Rails.application.config.x.rate_limit_store.clear

    6.times do
      post corrections_path,
        params: {correctable_type: "Books::Book", correctable_id: @book.id, correction: {notes: "wrong"}},
        headers: {"CF-Connecting-IP" => "198.51.100.9"}
    end

    assert_response :too_many_requests
    assert_match(/no-store/, response.headers["Cache-Control"])
    assert_select "[data-testid=correction-error]", "Thanks — you've sent us several corrections just now. Please try again shortly."
  end

  # The cached page ships no usable token. null_session must accept the write as
  # anonymous rather than 422 the submitter, who can do nothing about it.
  test "accepts a submission with no csrf token instead of raising" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    assert_difference -> { Correction.count }, 1 do
      post corrections_path, params: {
        correctable_type: "Books::Book", correctable_id: @book.id,
        correction: {notes: "wrong"}, authenticity_token: "stale"
      }
    end

    assert_redirected_to books_book_correction_thanks_path(slug: @book.slug)
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "emails the owner on a successful submission" do
    with_env("ADMIN_NOTIFICATION_EMAIL" => "owner@example.org") do
      assert_emails 1 do
        submit
      end
    end
  end

  test "sends nothing when the submission fails" do
    assert_emails 0 do
      post corrections_path, params: {
        correctable_type: "Books::Book", correctable_id: @book.id, correction: {notes: ""}
      }
    end
  end

  test "sends nothing for a honeypot submission" do
    assert_emails 0 do
      submit(website: "http://spam.example")
    end
  end

  # Music and games mirror the books coverage above -- proof the shared
  # controller works from a second and third domain, not just the one it was
  # built against.
  test "renders the form for a music album" do
    host! "dev.thegreatestmusic.org"
    album = music_albums(:dark_side_of_the_moon)

    get music_album_correction_path(slug: album.slug)

    assert_response :success
  end

  test "is publicly cacheable for a music album" do
    host! "dev.thegreatestmusic.org"
    album = music_albums(:dark_side_of_the_moon)

    get music_album_correction_path(slug: album.slug)

    assert_match(/public/, response.headers["Cache-Control"])
    assert_match(/max-age=86400/, response.headers["Cache-Control"])
  end

  # THE assertion with teeth for #new's `@indexable = false` -- Music::DefaultHelper
  # renders "index, follow" unless @indexable is explicitly false, so deleting that
  # controller line turns this red. The books equivalent above cannot.
  test "is not indexable for a music album" do
    host! "dev.thegreatestmusic.org"
    album = music_albums(:dark_side_of_the_moon)

    get music_album_correction_path(slug: album.slug)

    assert_select "meta[name=robots][content=?]", "noindex, follow"
  end

  test "creates a correction for a music album and redirects to the thanks page" do
    host! "dev.thegreatestmusic.org"
    album = music_albums(:dark_side_of_the_moon)

    assert_difference -> { Correction.count }, 1 do
      post corrections_path, params: {
        correctable_type: "Music::Album", correctable_id: album.id,
        correction: {notes: "The release year is wrong"}
      }
    end

    assert_redirected_to music_album_correction_thanks_path(slug: album.slug)
  end

  test "renders the form for a game" do
    host! "dev.thegreatest.games"
    game = games_games(:breath_of_the_wild)

    get games_game_correction_path(slug: game.slug)

    assert_response :success
  end

  test "is publicly cacheable for a game" do
    host! "dev.thegreatest.games"
    game = games_games(:breath_of_the_wild)

    get games_game_correction_path(slug: game.slug)

    assert_match(/public/, response.headers["Cache-Control"])
    assert_match(/max-age=86400/, response.headers["Cache-Control"])
  end

  test "is not indexable for a game" do
    host! "dev.thegreatest.games"
    game = games_games(:breath_of_the_wild)

    get games_game_correction_path(slug: game.slug)

    assert_select "meta[name=robots][content=?]", "noindex, follow"
  end

  test "creates a correction for a game and redirects to the thanks page" do
    host! "dev.thegreatest.games"
    game = games_games(:breath_of_the_wild)

    assert_difference -> { Correction.count }, 1 do
      post corrections_path, params: {
        correctable_type: "Games::Game", correctable_id: game.id,
        correction: {notes: "The release year is wrong"}
      }
    end

    assert_redirected_to games_game_correction_thanks_path(slug: game.slug)
  end

  # The robots assertion in here CANNOT FAIL and cannot be made to on books, for
  # the same reason as "is not indexable" above: Books::DefaultHelper already
  # renders "noindex, follow" for a nil @indexable, so deleting `@indexable = false`
  # from CorrectionsController#thanks leaves this green. The other three assertions
  # do have teeth. The teeth for #thanks's @indexable line are in the two
  # thanks-page tests immediately below, on music and games.
  test "the thanks page renders, is cacheable and not indexable, for a book" do
    get books_book_correction_thanks_path(slug: @book.slug)

    assert_response :success
    assert_match(/public/, response.headers["Cache-Control"])
    assert_match(/max-age=86400/, response.headers["Cache-Control"])
    assert_select "meta[name=robots][content=?]", "noindex, follow"
    assert_select "a[href=?]", book_path(slug: @book.slug)
  end

  # #thanks sets its own @indexable = false, separately from #new, and until these
  # two existed nothing anywhere could see it: the only assertion on it was the
  # books one above, which passes either way.
  test "the thanks page is not indexable for a music album" do
    host! "dev.thegreatestmusic.org"
    album = music_albums(:dark_side_of_the_moon)

    get music_album_correction_thanks_path(slug: album.slug)

    assert_response :success
    assert_select "meta[name=robots][content=?]", "noindex, follow"
  end

  test "the thanks page is not indexable for a game" do
    host! "dev.thegreatest.games"
    game = games_games(:breath_of_the_wild)

    get games_game_correction_thanks_path(slug: game.slug)

    assert_response :success
    assert_select "meta[name=robots][content=?]", "noindex, follow"
  end

  test "the thanks page 404s for an unknown slug" do
    get books_book_correction_thanks_path(slug: "no-such-book")

    assert_response :not_found
  end
end
