require "test_helper"

module Books
  class RankedBooksQueryTest < ActiveSupport::TestCase
    setup do
      @rc = ranking_configurations(:books_global)
      @second = RankedItem.create!(item: books_books(:crime_and_punishment), ranking_configuration: @rc, rank: 2, score: 90)
      @first = RankedItem.create!(item: books_books(:war_and_peace), ranking_configuration: @rc, rank: 1, score: 100)
    end

    test "returns the configuration's ranked books ordered by rank" do
      assert_equal [@first, @second], Books::RankedBooksQuery.call(ranking_configuration: @rc).to_a
    end

    test "excludes items belonging to another ranking configuration" do
      other = ranking_configurations(:books_inherited)
      RankedItem.create!(item: books_books(:got), ranking_configuration: other, rank: 1, score: 50)

      results = Books::RankedBooksQuery.call(ranking_configuration: @rc)

      assert_equal 2, results.count
    end

    test "excludes ranked items with a null rank" do
      rankless = RankedItem.new(item: books_books(:got), ranking_configuration: @rc, rank: nil, score: 5)
      rankless.save!(validate: false)

      results = Books::RankedBooksQuery.call(ranking_configuration: @rc)

      refute_includes results.map(&:rank), nil
      refute_includes results.map(&:item_id), books_books(:got).id
    end

    test "excludes non-book ranked items" do
      RankedItem.new(item: music_albums(:dark_side_of_the_moon), ranking_configuration: @rc, rank: 3, score: 10).save!(validate: false)

      item_types = Books::RankedBooksQuery.call(ranking_configuration: @rc).map(&:item_type).uniq

      assert_equal ["Books::Book"], item_types
    end

    test "preloads authors and the primary image with its attachment so views do not N+1" do
      image = Image.new(parent: @first.item, primary: true)
      image.file.attach(io: StringIO.new("fake image data"), filename: "cover.jpg", content_type: "image/jpeg")
      image.save!

      relation = Books::RankedBooksQuery.call(ranking_configuration: @rc)

      assert_queries_count(7) do
        relation.to_a.each do |ri|
          ri.item.book_authors.map { |ba| ba.author.name }
          ri.item.primary_image&.file&.attached?
        end
      end
    end

    test "filters to books carrying a single category" do
      results = Books::RankedBooksQuery.call(
        ranking_configuration: @rc,
        categories: [categories(:books_novels_genre)]
      )

      assert_equal [@first], results.to_a
    end

    test "ANDs multiple categories" do
      both = Books::RankedBooksQuery.call(
        ranking_configuration: @rc,
        categories: [categories(:books_novels_genre), categories(:books_classics_genre)]
      )

      assert_equal [@first], both.to_a

      neither = Books::RankedBooksQuery.call(
        ranking_configuration: @rc,
        categories: [categories(:books_novels_genre), categories(:books_politics_subject)]
      )

      assert_empty neither.to_a
    end

    test "ORs multiple countries" do
      Books::BookCountry.create!(book: books_books(:crime_and_punishment), country: books_countries(:japanese))

      results = Books::RankedBooksQuery.call(
        ranking_configuration: @rc,
        countries: [books_countries(:french), books_countries(:japanese)]
      )

      assert_equal [@first, @second], results.to_a
    end

    test "filters to a single country" do
      results = Books::RankedBooksQuery.call(ranking_configuration: @rc, countries: [books_countries(:french)])

      assert_equal [@first], results.to_a
    end

    test "bounds the year range inclusively" do
      books_books(:war_and_peace).update!(first_published_year: 1869)
      books_books(:crime_and_punishment).update!(first_published_year: 1866)

      assert_equal [@first, @second], Books::RankedBooksQuery.call(ranking_configuration: @rc, year_start: "1866", year_end: "1869").to_a
      assert_equal [@first], Books::RankedBooksQuery.call(ranking_configuration: @rc, year_start: "1867").to_a
      assert_equal [@second], Books::RankedBooksQuery.call(ranking_configuration: @rc, year_end: "1868").to_a
    end

    test "excludes books with no published year when a year filter is active" do
      books_books(:war_and_peace).update!(first_published_year: 1869)
      books_books(:crime_and_punishment).update!(first_published_year: nil)

      results = Books::RankedBooksQuery.call(ranking_configuration: @rc, year_start: "1800", year_end: "1900")

      assert_equal [@first], results.to_a
    end

    test "combines category, country and year" do
      books_books(:war_and_peace).update!(first_published_year: 1869)

      results = Books::RankedBooksQuery.call(
        ranking_configuration: @rc,
        categories: [categories(:books_novels_genre)],
        countries: [books_countries(:french)],
        year_start: "1800",
        year_end: "1900"
      )

      assert_equal [@first], results.to_a
    end

    def collection(slug) = ::Collections::Registry.find(:books, slug)

    test "a country-label collection keeps only books from labelled countries" do
      # war_and_peace -> french (western); of_mice_and_men -> japanese (asian)
      RankedItem.create!(item: books_books(:of_mice_and_men), ranking_configuration: @rc, rank: 3, score: 80)

      results = Books::RankedBooksQuery.call(ranking_configuration: @rc, collection: collection("western"))

      assert_includes results.map(&:item_id), books_books(:war_and_peace).id
      refute_includes results.map(&:item_id), books_books(:of_mice_and_men).id
    end

    test "a negated country-label collection keeps only books outside the label" do
      RankedItem.create!(item: books_books(:of_mice_and_men), ranking_configuration: @rc, rank: 3, score: 80)

      results = Books::RankedBooksQuery.call(ranking_configuration: @rc, collection: collection("non-western"))

      assert_includes results.map(&:item_id), books_books(:of_mice_and_men).id
      refute_includes results.map(&:item_id), books_books(:war_and_peace).id
    end

    test "an asia collection keeps only books from asian-labelled countries" do
      # war_and_peace -> french (western); of_mice_and_men -> japanese (asian)
      RankedItem.create!(item: books_books(:of_mice_and_men), ranking_configuration: @rc, rank: 3, score: 80)

      results = Books::RankedBooksQuery.call(ranking_configuration: @rc, collection: collection("asia"))

      assert_equal [books_books(:of_mice_and_men).id], results.map(&:item_id)
    end

    test "a latin-america collection keeps only books from latin-american-labelled countries" do
      # got -> french (western); adding an argentine link makes it ALSO
      # latin-american, so it -- and only it -- should survive the filter.
      argentina = Books::Country.create!(name: "Argentine", labels: ["latin_american"])
      Books::BookCountry.create!(book: books_books(:got), country: argentina)
      RankedItem.create!(item: books_books(:got), ranking_configuration: @rc, rank: 3, score: 80)

      results = Books::RankedBooksQuery.call(ranking_configuration: @rc, collection: collection("latin-america"))

      assert_equal [books_books(:got).id], results.map(&:item_id)
    end

    test "an author-gender collection keeps books with any author of that gender" do
      books_authors(:garnett).update!(gender: :female)
      Books::BookAuthor.create!(book: books_books(:crime_and_punishment),
        author: books_authors(:garnett), position: 2, role: 0)

      results = Books::RankedBooksQuery.call(ranking_configuration: @rc, collection: collection("women"))

      assert_equal [books_books(:crime_and_punishment).id], results.map(&:item_id)
    end

    test "a collection composes with a year bound" do
      # got -> french (western, 1996); war_and_peace -> french (western, 1869, too early);
      # of_mice_and_men -> japanese (non-western, 1937, admitted by the year bound alone).
      # Only got satisfies both the collection AND the year bound.
      RankedItem.create!(item: books_books(:got), ranking_configuration: @rc, rank: 3, score: 80)
      RankedItem.create!(item: books_books(:of_mice_and_men), ranking_configuration: @rc, rank: 4, score: 70)

      results = Books::RankedBooksQuery.call(
        ranking_configuration: @rc, collection: collection("western"), year_start: "1900"
      )

      assert_equal [books_books(:got).id], results.map(&:item_id)
    end

    test "a nil collection narrows nothing" do
      assert_equal 2, Books::RankedBooksQuery.call(ranking_configuration: @rc, collection: nil).count
    end
  end
end
