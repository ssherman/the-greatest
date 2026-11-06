require "test_helper"

module Books
  class BrowseQueryTest < ActiveSupport::TestCase
    setup do
      @rc = ranking_configurations(:books_global)
      RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
      RankedItem.create!(item: books_books(:got), ranking_configuration: @rc, rank: 2, score: 90)
      RankedItem.create!(item: books_books(:of_mice_and_men), ranking_configuration: @rc, rank: 3, score: 80)
      CategoryItem.create!(category: categories(:books_politics_subject), item: books_books(:war_and_peace))
    end

    def categories_for(**options)
      Books::BrowseQuery.categories(ranking_configuration: @rc, **options)
    end

    def countries_for(**options)
      Books::BrowseQuery.countries(ranking_configuration: @rc, **options)
    end

    test "audience categories list without the ranked-book minimum, like genres" do
      audience = Books::Category.create!(name: "Young Adult", category_type: :audience)
      CategoryItem.create!(category: audience, item: books_books(:war_and_peace))

      ids = with_browse_minimum(2) { categories_for(type: "audience").map(&:id) }

      assert_equal [audience.id], ids
    end

    test "categories returns only the requested type" do
      # The fixture subject has one ranked book; lower the card minimum so the
      # type filter is what is under test.
      types = with_browse_minimum(1) { categories_for(type: "subject").map { |c| c.category_type.to_s }.uniq }

      assert_equal ["subject"], types
    end

    test "categories defaults to genres" do
      types = categories_for.map { |c| c.category_type.to_s }.uniq

      assert_equal ["genre"], types
    end

    test "an unknown type falls back to genre rather than raising" do
      assert_equal categories_for.to_a, categories_for(type: "nonsense").to_a
    end

    test "categories excludes soft-deleted rows" do
      assert_not_includes categories_for.to_a, categories(:books_deleted_genre)
    end

    test "categories excludes a category whose books are none of them ranked" do
      fiction = categories(:books_fiction_genre)

      assert_operator fiction.item_count, :>, 0
      assert_not_includes categories_for.to_a, fiction
    end

    test "categories excludes a category ranked only in another configuration" do
      other = ranking_configurations(:books_inherited)
      empty = Books::Category.create!(name: "Elsewhere Genre", category_type: :genre)
      CategoryItem.create!(category: empty, item: books_books(:clash))
      RankedItem.create!(item: books_books(:clash), ranking_configuration: other, rank: 1, score: 10)

      assert_not_includes categories_for.to_a, empty
    end

    test "categories excludes other media types" do
      # A Music::Category that satisfies every other gate -- same category_type,
      # not deleted, and carrying a ranked Books::Book -- so only the STI scope
      # can keep it out.
      rock = categories(:music_rock_genre)
      CategoryItem.create!(category: rock, item: books_books(:war_and_peace))

      assert_not_includes categories_for(type: "genre").map(&:id), rock.id
    end

    test "categories counts only ranked books, not the catalog counter cache" do
      novels = categories_for.find { |c| c.slug == "novels" }

      assert_equal 2, novels.ranked_count
      assert_operator novels.item_count, :>, novels.ranked_count
    end

    test "categories sorts by ranked count then name by default" do
      slugs = categories_for.map(&:slug)

      assert_equal ["novels", "classics"], slugs
    end

    test "categories sorts by name on request" do
      names = categories_for(sort: "name").map(&:name)

      assert_equal names.sort, names
    end

    test "an unknown sort falls back to count rather than raising" do
      assert_equal categories_for.to_a, categories_for(sort: "nonsense").to_a
    end

    test "countries exclude the unknown bucket even when it holds ranked books" do
      # The production unknown bucket holds ~34,000 books, so the ranked-count
      # gate cannot exclude it -- only Books::Country.filterable can.
      Books::BookCountry.create!(book: books_books(:war_and_peace), country: books_countries(:unknown))

      slugs = countries_for.map(&:slug)

      assert_not_includes slugs, "unknown"
      assert_includes slugs, "french"
    end

    test "countries exclude a country whose books are none of them ranked" do
      algerian = books_countries(:algerian)

      assert_operator algerian.book_count, :>, 0
      assert_not_includes countries_for.map(&:id), algerian.id
    end

    test "countries count only ranked books" do
      french = countries_for.find { |c| c.slug == "french" }

      assert_equal 2, french.ranked_count
    end

    test "countries sort by ranked count then name by default" do
      slugs = countries_for.map(&:slug)

      assert_equal ["french", "japanese"], slugs
    end

    test "countries sort by name on request" do
      names = countries_for(sort: "name").map(&:name)

      assert_equal names.sort, names
    end

    test "both stay paginatable relations" do
      [categories_for, countries_for].each do |relation|
        assert_kind_of ActiveRecord::Relation, relation
        assert_kind_of Integer, relation.count(:all)
        assert_equal 1, relation.limit(1).offset(0).to_a.size
      end
    end

    test "subject and location cards need the minimum number of ranked books; genres do not" do
      with_browse_minimum(2) do
        rare_place = ::Books::Category.create!(name: "Kilwa", category_type: :location)
        rare_genre = ::Books::Category.create!(name: "Tiny Genre", category_type: :genre)
        book = books_books(:war_and_peace)
        CategoryItem.create!(category: rare_place, item: book)
        CategoryItem.create!(category: rare_genre, item: book)

        place_ids = categories_for(type: "location").map(&:id)
        genre_ids = categories_for(type: "genre").map(&:id)

        refute_includes place_ids, rare_place.id
        assert_includes genre_ids, rare_genre.id
      end
    end

    test "search matches all three types" do
      tag_americas

      types = with_browse_minimum(1) { search_for("americ").map { |c| c.category_type.to_s }.sort }

      assert_equal %w[genre location subject], types
    end

    test "search puts the current type first among equal name matches" do
      # All three "americ" fixtures are prefix matches, so match quality ties.
      tag_americas

      first = with_browse_minimum(1) { search_for("americ", type: "subject").first }

      assert_equal categories(:books_american_history_subject), first
    end

    test "a name match outranks an alias-only match" do
      alias_only = Books::Category.create!(name: "Zebra Studies", category_type: :genre, alternative_names: ["warfare notes"])
      by_name = Books::Category.create!(name: "Warfare", category_type: :genre)
      ranked_books.each { |book| tag(alias_only, book) }
      tag(by_name, ranked_books.first)

      names = with_browse_minimum(1) { search_for("warf").map(&:name) }

      assert_equal ["Warfare", "Zebra Studies"], names
    end

    test "an exact name outranks a prefix, which outranks a word-start, which outranks a substring" do
      # Ranked counts run the opposite way (Steward most), and every category is a
      # genre, so neither count nor type can explain the order.
      {"Steward" => 3, "Cold War" => 2, "Warsaw" => 1, "War" => 1}.each do |name, count|
        category = Books::Category.create!(name: name, category_type: :genre)
        ranked_books.first(count).each { |book| tag(category, book) }
      end

      names = with_browse_minimum(1) { search_for("war").map(&:name) }

      assert_equal ["War", "Warsaw", "Cold War", "Steward"], names
    end

    test "a word after punctuation counts as a word start" do
      # The mid-word match has more ranked books, so only the word-start tier
      # can put Post-Apocalyptic first.
      {"Zzapoczz" => 3, "Post-Apocalyptic" => 1}.each do |name, count|
        category = Books::Category.create!(name: name, category_type: :genre)
        ranked_books.first(count).each { |book| tag(category, book) }
      end

      names = with_browse_minimum(1) { search_for("apoc").map(&:name) }

      assert_equal ["Post-Apocalyptic", "Zzapoczz"], names
    end

    # The word-start tier is a regex; an unescaped "(" would be a Postgres
    # syntax error on the uncached search endpoint, i.e. a 500 per keystroke.
    test "regex metacharacters in the query do not raise" do
      tag(Books::Category.create!(name: "Cold (War)", category_type: :genre))

      assert_equal ["Cold (War)"], with_browse_minimum(1) { search_for("(war").map(&:name) }
    end

    test "search applies the ranked minimum to subjects and settings but not genres" do
      tag_americas

      assert_equal [categories(:books_americana_genre)], search_for("americ").to_a
    end

    test "search ignores a category none of whose books are ranked" do
      tag(categories(:books_americana_genre), books_books(:crime_and_punishment))

      assert_empty search_for("americana").to_a
    end

    test "search matches alternative_names" do
      france = categories(:books_france_location)
      france.update!(alternative_names: ["Gallia"])
      tag(france)

      assert_equal [france], with_browse_minimum(1) { search_for("gall").to_a }
    end

    test "search treats LIKE metacharacters literally" do
      tag(categories(:books_american_history_subject))

      with_browse_minimum(1) do
        assert_empty search_for("%%").to_a
        assert_empty search_for("a_e").to_a # as a wildcard, "a_e" matches "AMErican History"
        # Unescaped, "\a" is a literal "a", so %ic\a% would match "AmerICAn History".
        assert_empty search_for("ic\\a").to_a
      end
    end

    test "a query shorter than two characters after stripping returns nothing" do
      tag(categories(:books_americana_genre))

      assert_empty search_for("a").to_a
      assert_empty search_for("   ").to_a
      assert_empty search_for(nil).to_a
    end

    test "search caps results at the limit" do
      tag_americas

      assert_equal 1, with_browse_minimum(1) { search_for("americ", limit: 1).to_a.size }
    end

    test "search reports the same ranked_count as the grid" do
      politics = categories(:books_politics_subject)
      grid = with_browse_minimum(1) { categories_for(type: "subject").find { |c| c.id == politics.id } }
      hit = with_browse_minimum(1) { search_for("politic").find { |c| c.id == politics.id } }

      assert_equal grid.ranked_count, hit.ranked_count
    end

    private

    def search_for(query, **options)
      Books::BrowseQuery.search(ranking_configuration: @rc, query: query, **options)
    end

    def tag(category, book = books_books(:war_and_peace))
      CategoryItem.create!(category: category, item: book)
    end

    def ranked_books
      [books_books(:war_and_peace), books_books(:got), books_books(:of_mice_and_men)]
    end

    def tag_americas
      tag(categories(:books_americana_genre))
      tag(categories(:books_american_location))
      tag(categories(:books_american_history_subject))
    end

    def with_browse_minimum(value)
      original = Rails.configuration.x.books.browse_min_category_books
      Rails.configuration.x.books.browse_min_category_books = value
      yield
    ensure
      Rails.configuration.x.books.browse_min_category_books = original
    end
  end
end
