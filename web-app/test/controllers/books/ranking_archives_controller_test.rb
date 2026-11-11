require "test_helper"

module Books
  class RankingArchivesControllerTest < ActionDispatch::IntegrationTest
    setup do
      host! "dev-new.thegreatestbooks.org"
      @archive = ranking_archives(:books_january_2027)
    end

    test "index lists visible archives newest first and leaves hidden ones out" do
      get "/rankings/archive"

      assert_response :success
      ids = @controller.view_assigns["archives"].map(&:id)
      assert_includes ids, @archive.id
      assert_not_includes ids, ranking_archives(:books_hidden_legacy).id
    end

    test "index orders archives by capture date, newest first" do
      older = make_archive(2, slug: "older", captured_at: Time.utc(2026, 12, 1))

      get "/rankings/archive"

      assert_equal [@archive.id, older.id], @controller.view_assigns["archives"].map(&:id)
    end

    test "index does not load the archive arrays" do
      get "/rankings/archive"

      archive = @controller.view_assigns["archives"].first
      assert_not archive.has_attribute?(:item_ids)
    end

    test "index is publicly cacheable and noindex" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/rankings/archive"

      assert_includes response.headers["Cache-Control"], "public"
      assert_select "meta[name=robots][content='noindex, follow']"
    end

    test "show renders the archive's entries" do
      get "/rankings/archive/january-2027"

      assert_response :success
      assert_equal [books_books(:war_and_peace), books_books(:crime_and_punishment)],
        @controller.view_assigns["entries"].map(&:item)
    end

    test "show is publicly cacheable, noindex, and has no canonical" do
      Books::PublicIndexing.stubs(:enabled?).returns(true)

      get "/rankings/archive/january-2027"

      assert_includes response.headers["Cache-Control"], "public"
      assert_select "meta[name=robots][content='noindex, follow']"
      assert_select "link[rel=canonical]", 0
    end

    test "a hidden archive is a 404" do
      get "/rankings/archive/list-dates-v7"

      assert_response :not_found
    end

    test "an unknown slug is a 404" do
      get "/rankings/archive/no-such-archive"

      assert_response :not_found
    end

    test "page 1 shows the first 100 entries" do
      make_archive(101, slug: "big")

      get "/rankings/archive/big"

      assert_equal 100, @controller.view_assigns["entries"].size
    end

    test "page 2 shows entries 101 onward" do
      make_archive(101, slug: "big")

      get "/rankings/archive/big/page/2"

      assert_response :success
      assert_equal 2, @controller.view_assigns["pagy"].page
      assert_equal [101], @controller.view_assigns["entries"].map(&:rank)
      assert_select "a[href='/rankings/archive/big']"
    end

    test "a page past the last is a 404" do
      get "/rankings/archive/january-2027/page/2"

      assert_response :not_found
    end

    test "a non-numeric page is a 404" do
      get "/rankings/archive/january-2027/page/abc"

      assert_response :not_found
    end

    test "a json request is a 404" do
      get "/rankings/archive/january-2027.json"

      assert_response :not_found
      assert_nil response.headers["Cache-Control"]
    end

    # The archive must never 5xx on these. Where the live ranking answers below
    # 500 the archive answers the same; where the live ranking itself fails the
    # archive answers 404.
    test "page 0 and a huge page behave as they do on the live ranking, without a 5xx" do
      %w[0 99999999999999999999].each do |page|
        expected = live_status_or_404(page)

        get "/rankings/archive/january-2027/page/#{page}"

        assert_operator response.status, :<, 500, "page #{page} returned #{response.status}"
        assert_equal expected, response.status, "page #{page}"
      end
    end

    test "an archive whose books are all gone renders an empty page" do
      archive = make_archive(0, slug: "gone", item_ids: [-1, -2])

      get "/rankings/archive/#{archive.slug}"

      assert_response :success
      assert_equal [], @controller.view_assigns["entries"]
    end

    test "a merged book is shown as its survivor" do
      gone_id = Books::Book.maximum(:id) + 1000
      survivor = books_books(:war_and_peace)
      RecordRedirect.create!(item_type: "Books::Book", from_id: gone_id, to_id: survivor.id)
      archive = make_archive(0, slug: "merged", item_ids: [gone_id])

      get "/rankings/archive/#{archive.slug}"

      assert_equal [survivor], @controller.view_assigns["entries"].map(&:item)
    end

    test "the session is skipped" do
      get "/rankings/archive/january-2027"

      assert_nil response.headers["Set-Cookie"]
    end

    private

    def live_status_or_404(page)
      get "/page/#{page}"
      (response.status < 500) ? response.status : 404
    rescue
      404
    end

    def make_archive(count, slug:, captured_at: Time.utc(2027, 1, 1, 5), item_ids: nil)
      if item_ids.nil?
        now = Time.current
        rows = Array.new(count) { |i| {title: "Archive #{slug} #{i}", slug: "archive-#{slug}-#{i}", created_at: now, updated_at: now} }
        item_ids = Books::Book.insert_all(rows, returning: :id).rows.flatten
      end
      Books::RankingArchive.create!(
        name: slug.titleize, slug: slug, captured_at: captured_at,
        item_ids: item_ids,
        positions: item_ids.each_index.map { |i| i + 1 },
        scores: item_ids.each_index.map { |i| 100.0 - i * 0.01 }
      )
    end
  end
end
