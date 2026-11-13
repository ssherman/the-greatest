require "test_helper"

# The guard for every sitemap source: request every URL each host lists and
# require it to render as an indexable page. A listed URL that 404s, redirects
# or renders noindex is a source bug (wrong path or wrong rule), never a reason
# to loosen this test. Each domain must also list at least one URL per source,
# so a source cannot pass by being empty; a new source needs data here that
# puts it in the sitemap.
class SitemapConsistencyTest < ActionDispatch::IntegrationTest
  EXPECTED_KEYS = {
    books: %w[pages news books authors lists filters],
    music: %w[pages news albums songs artists album_lists song_lists categories album_categories],
    games: %w[pages news games lists categories]
  }.freeze

  setup do
    ::Books::PublicIndexing.stubs(:enabled?).returns(true)
    # Fixture categories hold one or two ranked items; production thresholds
    # would leave every category and filter source empty.
    Sitemaps::Thresholds.stubs(:filter_single).returns(1)
    Sitemaps::Thresholds.stubs(:filter_pair).returns(1)
    rank_what_the_fixtures_leave_unranked
  end

  EXPECTED_KEYS.each do |domain, keys|
    test "every url #{domain} lists renders as an indexable page" do
      host! Rails.application.config.domains[domain].split(",").first
      base_url = Api::Host.base_url(domain)

      get "/sitemap.xml"
      assert_response :success
      children = locs(response.body, "//sitemap/loc")

      paths_by_key = {}
      children.each do |child|
        child_path = path_on(child, base_url)
        key = child_path[%r{\A/sitemaps/([a-z_]+)-\d+\.xml\z}, 1]
        assert key, "unexpected child file #{child}"

        get child_path
        assert_response :success, "#{child} did not return 200"
        (paths_by_key[key] ||= []).concat(locs(response.body, "//url/loc").map { |loc| path_on(loc, base_url) })
      end

      assert_equal keys.sort, paths_by_key.keys.sort, "#{domain} child files"
      empty = keys.select { |key| paths_by_key[key].blank? }
      assert_empty empty, "#{domain} sources listed no urls; give each one a row in rank_what_the_fixtures_leave_unranked or a fixture"

      paths_by_key.values.flatten.each do |path|
        get path
        assert_response :success, "#{domain} #{path} did not return 200"
        assert_select "meta[name=robots][content^=index]", {count: 1}, "#{domain} #{path} is not indexable"
      end
    end
  end

  private

  # The fixtures rank nothing in the books primaries or for music albums and
  # artists, hold no active ranked books or games list, and no games news post.
  # These rows live here rather than in the YAML because other tests pin those
  # exact gaps: "fixture drift" guards on category sizes, an empty games news
  # index that must render noindex, and dozens of exact ranked-set assertions.
  # war_and_peace carries two categories and a country, so it also fills the
  # books filter source with a category, a country and a pair page.
  def rank_what_the_fixtures_leave_unranked
    [
      [books_books(:war_and_peace), :books_global],
      [books_authors(:tolstoy), :books_authors_global],
      [music_albums(:dark_side_of_the_moon), :music_albums_global],
      [music_artists(:pink_floyd), :music_artists_global]
    ].each do |item, rc|
      RankedItem.create!(item: item, ranking_configuration: ranking_configurations(rc), rank: 1, score: 90)
    end
    # Both lists already have a ranked_lists row in their primary; they are
    # only approved, and the sitemap lists active lists alone.
    lists(:books_list).update!(status: :active)
    lists(:games_list).update!(status: :active)
    NewsPost.create!(domain: :games, title: "The Greatest Games Is Live", slug: "the-greatest-games-is-live",
      body: "We are live.", published_at: 1.day.ago, user: users(:admin_user))
  end

  def locs(xml, xpath)
    Nokogiri::XML(xml).remove_namespaces!.xpath(xpath).map(&:text)
  end

  def path_on(loc, base_url)
    assert loc.start_with?("#{base_url}/"), "#{loc} is not on #{base_url}"
    loc.delete_prefix(base_url)
  end
end
