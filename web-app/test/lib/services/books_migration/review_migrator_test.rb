require "test_helper"

class Services::BooksMigration::ReviewMigratorTest < ActiveSupport::TestCase
  include SequenceIsolation

  isolate_sequences "reviews"

  # Rows are yielded NEWEST FIRST, matching find_each(order: :desc) in the real
  # legacy_each. Order is load-bearing for the dedup rule.
  def run_migrator(rows)
    m = Services::BooksMigration::ReviewMigrator.new
    m.stubs(:legacy_each).multiple_yields(*rows.zip)
    m.call
  end

  # Sequence changes survive the test transaction, so start low: otherwise an
  # earlier test that already pushed the sequence past the ceiling would make the
  # finalize assertion pass with finalize deleted.
  def start_sequence_low(table)
    connection = ActiveRecord::Base.connection
    sequence = connection.select_value("SELECT pg_get_serial_sequence(#{connection.quote(table)}, 'id')")
    connection.execute("SELECT setval(#{connection.quote(sequence)}, 1, false)")
  end

  def next_sequence_value(table)
    ActiveRecord::Base.connection.select_value("SELECT nextval(pg_get_serial_sequence('#{table}', 'id'))").to_i
  end

  # A legacy reviews row as the migrator yields it: String keys.
  def legacy_review(id, overrides = {})
    {
      "id" => id,
      "user_id" => users(:regular_user).id,
      "book_id" => books_books(:got).id,
      "title" => nil,
      "body" => nil,
      "rating" => 4,
      "created_at" => Time.utc(2025, 1, 2, 3, 4, 5),
      "updated_at" => Time.utc(2025, 6, 7, 8, 9, 10)
    }.merge(overrides)
  end

  setup do
    # reviews.yml ships four fixture rows; clear them so counts in this file are
    # about the migrator's own output. Test-transactional, rolled back after each test.
    ::Review.delete_all
    ::ReviewSummary.delete_all
  end

  test "preserves the legacy id, ids, rating and timestamps" do
    result = run_migrator([legacy_review(200_001, "rating" => 5)])

    assert result[:success], result[:error]
    assert_equal 1, result[:data][:count]

    review = ::Review.find(200_001)
    assert_equal users(:regular_user).id, review.user_id
    assert_equal "Books::Book", review.reviewable_type
    assert_equal books_books(:got).id, review.reviewable_id
    assert_equal 5, review.rating
    assert_equal Time.utc(2025, 1, 2, 3, 4, 5), review.created_at
    assert_equal Time.utc(2025, 6, 7, 8, 9, 10), review.updated_at
  end

  test "sanitizes the body" do
    run_migrator([legacy_review(200_001, "body" => "good <script>alert('xss')</script>")])

    body = ::Review.find(200_001).body
    assert_not_includes body, "<script"
    assert_includes body, "good"
  end

  test "normalizes an empty-string body to nil" do
    run_migrator([legacy_review(200_001, "body" => "")])
    assert_nil ::Review.find(200_001).body
  end

  test "normalizes a whitespace-only body to nil" do
    run_migrator([legacy_review(200_001, "body" => "   \n\t ")])
    assert_nil ::Review.find(200_001).body
  end

  test "normalizes an image-only body to nil" do
    run_migrator([legacy_review(200_001, "body" => %(<img src="https://x.test/a.png">))])
    assert_nil ::Review.find(200_001).body
  end

  test "drops a body that exceeds MAX_BODY_LENGTH after sanitizing, keeping the rating" do
    oversized = "<p>#{"a" * (::Review::MAX_BODY_LENGTH + 100)}</p>"
    run_migrator([legacy_review(200_001, "body" => oversized, "rating" => 3)])

    review = ::Review.find(200_001)
    assert_nil review.body
    assert_equal 3, review.rating
  end

  test "keeps a body exactly at MAX_BODY_LENGTH" do
    exact = "a" * ::Review::MAX_BODY_LENGTH
    run_migrator([legacy_review(200_001, "body" => exact)])

    assert_equal ::Review::MAX_BODY_LENGTH, ::Review.find(200_001).body.length
  end

  test "normalizes a blank title to nil and strips a real one" do
    run_migrator([
      legacy_review(200_001, "title" => "   "),
      legacy_review(200_002, "title" => "  A great read  ", "book_id" => books_books(:war_and_peace).id)
    ])

    assert_nil ::Review.find(200_001).title
    assert_equal "A great read", ::Review.find(200_002).title
  end

  test "keeps the newer row when a user reviewed the same book twice" do
    # Yielded newest-first, as find_each(order: :desc) does.
    result = run_migrator([
      legacy_review(200_002, "rating" => 2),
      legacy_review(200_001, "rating" => 5)
    ])

    assert_equal 1, result[:data][:count]
    assert_equal 2, ::Review.find(200_002).rating
    assert_not ::Review.exists?(200_001)
  end

  test "keeps both rows when the same user reviews different books" do
    result = run_migrator([
      legacy_review(200_002, "book_id" => books_books(:war_and_peace).id),
      legacy_review(200_001)
    ])

    assert_equal 2, result[:data][:count]
  end

  test "is idempotent across runs" do
    rows = [legacy_review(200_001), legacy_review(200_002, "book_id" => books_books(:war_and_peace).id)]

    assert_equal 2, run_migrator(rows)[:data][:count]
    assert_equal 0, run_migrator(rows)[:data][:count]
    assert_equal 2, ::Review.count
  end

  test "fails loudly when the legacy book was never migrated" do
    result = run_migrator([legacy_review(200_001, "book_id" => 999_999_999)])

    assert_not result[:success]
    assert_includes result[:error], "999999999"
  end

  test "fails loudly when the legacy user was never migrated" do
    result = run_migrator([legacy_review(200_001, "user_id" => 999_999_999)])

    assert_not result[:success]
    assert_includes result[:error], "999999999"
  end

  test "does not maintain review_summaries" do
    run_migrator([legacy_review(200_001)])

    assert_equal 0, ::ReviewSummary.count,
      "insert_all bypasses after_commit by design; the rake task calls backfill_all!"
  end

  test "moves the reviews sequence to the reserved ceiling after the load" do
    start_sequence_low("reviews")

    run_migrator([legacy_review(200_001)])

    next_id = next_sequence_value("reviews")
    assert_operator next_id, :>=, Services::BooksMigration::RESERVED_CEILINGS.fetch("reviews")
    assert_operator next_id, :>, 200_001
  end

  test "fails the run when a legacy review id reaches the reserved ceiling" do
    ceiling = Services::BooksMigration::RESERVED_CEILINGS.fetch("reviews")

    result = run_migrator([legacy_review(ceiling)])

    refute result[:success]
    assert_includes result[:error], "reserved ceiling"
    refute ::Review.exists?(ceiling)
  end

  # The dedup rule ("the newer duplicate wins") is only true because rows arrive
  # newest-first. Every other test stubs legacy_each, so without this one, deleting
  # `order: :desc` would silently invert the rule and stay green.
  test "reads the legacy table newest-first" do
    LegacyBooks::Review.expects(:find_each).with(has_entry(order: :desc))

    Services::BooksMigration::ReviewMigrator.new.send(:legacy_each) { |_| }
  end

  test "converts a legacy spoiler tag into a marker before sanitizing" do
    migrator = Services::BooksMigration::ReviewMigrator.new
    migrator.stubs(:legacy_each).multiple_yields(
      [{"id" => 1, "user_id" => users(:regular_user).id, "book_id" => books_books(:war_and_peace).id,
        "rating" => 4, "title" => nil, "body" => "He <spoiler>dies</spoiler> at the end.",
        "created_at" => Time.current, "updated_at" => Time.current}]
    )

    migrator.call

    body = ::Review.find(1).body
    assert_includes body, "||dies||"
    refute_includes body, "spoiler>"
  end

  # Regression: everything downstream of this pre-pass is case-insensitive (the
  # HTML5 parser lowercases tag names; BodySanitizer's own spoiler handling and
  # BLOCK_MARKUP are case-insensitive too), so an uppercase legacy <SPOILER> tag
  # must convert exactly the same as a lowercase one. A prior version of the
  # guard here checked for the literal lowercase string and skipped uppercase
  # tags entirely, unwrapping them like any other disallowed tag and publishing
  # the spoiler text in the clear.
  test "converts an uppercase legacy spoiler tag into a marker" do
    run_migrator([legacy_review(200_001, "body" => "He <SPOILER>dies</SPOILER> at the end.")])

    body = ::Review.find(200_001).body
    assert_includes body, "||dies||"
    refute_includes body.downcase, "spoiler>"
  end

  # Real data: 31 of the 118 legacy rows with a <spoiler> tag wrap a <br>. Unwrapping
  # in place, not flattening to `.text`, is what keeps it.
  test "keeps a <br> inside a legacy spoiler tag" do
    run_migrator([legacy_review(200_001, "body" => "<spoiler>line one<br>line two</spoiler>")])

    assert_includes ::Review.find(200_001).body, "||line one<br>line two||"
  end

  # Real data: 2 of the 118 rows wrap an <i>.
  test "keeps an inline tag like <i> inside a legacy spoiler tag" do
    run_migrator([legacy_review(200_001, "body" => "He <spoiler>said <i>hello</i> to her</spoiler>.")])

    assert_includes ::Review.find(200_001).body, "||said <i>hello</i> to her||"
  end

  # Real data: legacy review 88697's <spoiler> wraps two <blockquote>s. blockquote is
  # a spoiler SCOPE boundary at render time, so unwrapping in place would split the
  # opening and closing "||" into two scopes that never pair up, leaking everything
  # after the blockquote. Flattening to `.text` instead loses the internal formatting
  # but keeps both markers -- and everything between them -- in one scope.
  test "falls back to flattening a legacy spoiler tag with a block-level child" do
    run_migrator([legacy_review(200_001,
      "body" => "<spoiler>before<blockquote>quoted</blockquote>after</spoiler>")])

    body = ::Review.find(200_001).body
    assert_includes body, "||beforequotedafter||"
    refute_includes body, "<blockquote"
  end

  # Real data: 17 of the 118 rows have more than one <spoiler> tag.
  test "converts multiple legacy spoiler tags in one body" do
    run_migrator([legacy_review(200_001, "body" => "<spoiler>one</spoiler> and <spoiler>two</spoiler>")])

    assert_includes ::Review.find(200_001).body, "||one|| and ||two||"
  end

  test "leaves a body with no legacy spoiler tag unaffected by the conversion pass" do
    run_migrator([legacy_review(200_001, "body" => "<p>Nothing hidden.</p>")])

    assert_equal "<p>Nothing hidden.</p>", ::Review.find(200_001).body
  end
end
