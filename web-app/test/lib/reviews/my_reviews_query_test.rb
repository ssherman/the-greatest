require "test_helper"

module Reviews
  class MyReviewsQueryTest < ActiveSupport::TestCase
    setup do
      @user = users(:regular_user)
      @war_and_peace = books_books(:war_and_peace)
      @crime = books_books(:crime_and_punishment)
    end

    def query(params = {})
      MyReviewsQuery.new(user: @user, reviewable_class: ::Books::Book, params: params)
    end

    test "returns only this user's reviews of this reviewable type" do
      results = query.call.to_a
      assert_equal @user.reviews.count, results.size
      assert results.all? { |review| review.user_id == @user.id }
      assert results.all? { |review| review.reviewable_type == "Books::Book" }
    end

    test "defaults to newest first" do
      assert_equal "recent", query.sort
      created = query.call.map(&:created_at)
      assert_equal created.sort.reverse, created
    end

    test "filters to a single rating" do
      results = query(rating: "5").call.to_a
      assert results.any?
      assert results.all? { |review| review.rating == 5 }
    end

    test "ignores an out-of-range rating rather than returning nothing" do
      assert_equal query.call.count, query(rating: "9").call.count
      assert_nil query(rating: "9").rating
    end

    test "a crafted ?rating[]=1 array is ignored instead of raising" do
      assert_nil query(rating: ["1"]).rating
      assert_nothing_raised { query(rating: ["1"]).call.to_a }
    end

    test "a crafted ?rating[a]=1 hash is ignored instead of raising" do
      assert_nil query(rating: {"a" => "1"}).rating
      assert_nothing_raised { query(rating: {"a" => "1"}).call.to_a }
    end

    test "sort and kind fall back safely on a non-scalar param" do
      # Array#to_s / Hash#to_s never raise, so #sort and #kind's `.to_s` guard
      # already tolerates this -- an array simply fails the allowlist check and
      # falls back, same as any other unrecognised string would.
      assert_equal "recent", query(sort: ["rating_high"]).sort
      assert_nil query(kind: ["written"]).kind
    end

    test "term does not raise on a non-scalar param, even though the result is not useful" do
      # `["war"].to_s` stringifies to the literal `["war"]`, which becomes a
      # harmless zero-result ILIKE pattern rather than a crash -- review_text_search
      # binds it as a SQL parameter, never interpolates it.
      assert_nothing_raised { query(q: ["war"]).call.to_a }
    end

    test "filters to written and to rating-only" do
      assert query(kind: "written").call.all? { |review| review.body.present? }
      assert query(kind: "rating_only").call.all? { |review| review.body.nil? }
    end

    test "sorts by the user's own rating in both directions" do
      high = query(sort: "rating_high").call.map(&:rating)
      assert_equal high.sort.reverse, high
      low = query(sort: "rating_low").call.map(&:rating)
      assert_equal low.sort, low
    end

    test "sorts A-Z by the reviewable's title" do
      # Fixture timestamps are assigned once per fixture FILE, so every review in
      # reviews.yml shares one created_at -- the default sort's tiebreak (id DESC)
      # then decides everything on its own. The fixture ids are
      # Zlib.crc32(label) % (2**30-1), and it happens that crime_and_punishment's
      # id sorts above war_and_peace's, which is ALSO title-ascending order: a
      # title-sort test using only those two fixtures would still pass with the
      # "title" branch deleted entirely. A third title that alphabetically lands
      # between them, backed by a freshly-inserted row whose id sorts outside
      # that order (fixture loading resets the pk sequence past every fixture
      # id), proves the ORDER BY clause itself does the work.
      middle_book = ::Books::Book.create!(title: "Don Quixote")
      Review.create!(user: @user, reviewable: middle_book, rating: 4)

      titles = query(sort: "title").call.map { |review| review.reviewable.title }
      assert_equal ["Crime and Punishment", "Don Quixote", "War and Peace"], titles
    end

    test "sorts by site rank with unranked last" do
      # Ranking war_and_peace (not crime_and_punishment) so the ranked order is
      # the REVERSE of the default id-DESC order (crime, war) -- see the title
      # test above for why that coincidence matters. If it discriminates only
      # INNER-vs-LEFT-join but not "is rank ordering applied at all", deleting
      # the "rank" branch entirely (falling back to the default order) would
      # still pass.
      config = ::Books::RankingConfiguration.default_primary
      RankedItem.create!(item: @war_and_peace, ranking_configuration: config, rank: 1)
      results = query(sort: "rank").call.to_a
      # Both of the user's reviews must still appear -- an INNER JOIN to
      # ranked_items would silently drop the unranked one instead of sorting it
      # last, which on a personal history reads as data loss.
      assert_equal 2, results.size
      assert_equal @war_and_peace.id, results.first.reviewable_id
      assert_equal @crime.id, results.last.reviewable_id
    end

    test "offers the rank sort only when a default primary configuration exists" do
      assert_includes query.available_sorts, "rank"
      ::Books::Book.stubs(:ranking_configuration_class).returns(nil)
      refute_includes query.available_sorts, "rank"
      assert_equal "recent", query(sort: "rank").sort, "an unavailable sort falls back, never raises"
    end

    test "an unknown sort falls back to the default" do
      assert_equal "recent", query(sort: "; DROP TABLE reviews").sort
    end

    test "text search matches title or author" do
      results = query(q: "war and peace").call.to_a
      assert results.any?
      assert results.all? { |review| review.reviewable_id == @war_and_peace.id }
    end

    test "a blank search term is ignored" do
      assert_equal query.call.count, query(q: "   ").call.count
    end
  end
end
