# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class NormalizeStoredNamesTest < ActiveSupport::TestCase
      NNBSP = " "

      # Rows are written past the normalizing callbacks with update_columns,
      # the way the migration-era rows in production were.
      def raw_author(name)
        author = ::Books::Author.create!(name: "placeholder #{SecureRandom.hex(4)}")
        author.update_columns(name: name)
        author.reload
      end

      def raw_book(title, authors: [])
        book = ::Books::Book.create!(title: "placeholder #{SecureRandom.hex(4)}")
        book.update_columns(title: title)
        authors.each_with_index { |author, i| ::Books::BookAuthor.create!(book: book, author: author, position: i + 1) }
        book.reload
      end

      test "the report counts whitespace-only and NFKC changes per model and touches nothing" do
        raw_author("Kathleen#{NNBSP}Alcott")
        raw_author("Honorée Jeffers")
        raw_book("House Of X   Powers Of X")

        result = NormalizeStoredNames.call(apply: false)

        assert result.success?
        data = result.data
        assert_equal [1, 1, 2], data[:authors].values_at(:whitespace, :nfkc, :changed)
        assert_equal [1, 0, 1], data[:books].values_at(:whitespace, :nfkc, :changed)
        assert_not data[:applied]
        assert_equal "Kathleen#{NNBSP}Alcott", ::Books::Author.find_by("name LIKE 'Kathleen%'").name
        assert_includes data[:authors][:samples].map { |s| s[:after] }, "Kathleen Alcott"
      end

      test "apply rewrites the changed rows in place through the model callbacks" do
        author = raw_author("Kathleen#{NNBSP}Alcott")
        book = raw_book("Dune   Messiah")

        result = NormalizeStoredNames.call(apply: true)

        assert result.success?
        assert result.data[:applied]
        assert_equal "Kathleen Alcott", author.reload.name
        assert_equal "Dune Messiah", book.reload.title
      end

      test "apply normalizes alternate names and alternate titles too" do
        author = raw_author("Plain Name")
        author.update_columns(alternate_names: ["Plain#{NNBSP}Name", "P. Name"])
        book = raw_book("Plain Title")
        book.update_columns(alternate_titles: ["Plain#{NNBSP}Title"])

        NormalizeStoredNames.call(apply: true)

        assert_equal ["Plain Name", "P. Name"], author.reload.alternate_names
        assert_equal ["Plain Title"], book.reload.alternate_titles
      end

      test "apply flags an author whose normalized name now equals another author's, as a bulk_verify pair" do
        existing = ::Books::Author.create!(name: "Kathleen Alcott")
        stray = raw_author("Kathleen#{NNBSP}Alcott")

        result = NormalizeStoredNames.call(apply: true)

        pair = DuplicateCandidate.find_by(item_type: "Books::Author", item_a_id: [existing.id, stray.id].min, item_b_id: [existing.id, stray.id].max)
        assert pair.raised_by_bulk_verify?
        assert_match(/normaliz/, pair.evidence["reason"])
        assert_equal 1, result.data[:pairs_flagged]
      end

      test "apply flags two books with the same normalized title and a shared author name, and leaves unrelated same titles alone" do
        author_a = ::Books::Author.create!(name: "Kathleen Alcott")
        author_b = raw_author("Kathleen#{NNBSP}Alcott")
        kept = ::Books::Book.create!(title: "The Secret Lives")
        ::Books::BookAuthor.create!(book: kept, author: author_a, position: 1)
        stray = raw_book("The Secret#{NNBSP}Lives", authors: [author_b])
        other_author = ::Books::Author.create!(name: "Someone Else")
        unrelated = raw_book("The Secret#{NNBSP}Lives", authors: [other_author])

        NormalizeStoredNames.call(apply: true)

        assert DuplicateCandidate.exists?(item_type: "Books::Book", item_a_id: [kept.id, stray.id].min, item_b_id: [kept.id, stray.id].max)
        assert_not DuplicateCandidate.exists?(item_type: "Books::Book", item_a_id: [kept.id, unrelated.id].min, item_b_id: [kept.id, unrelated.id].max)
      end

      test "a row the normalizer would not change is not saved" do
        author = books_authors(:tolstoy)
        ::Books::Author.any_instance.expects(:save!).never

        NormalizeStoredNames.call(apply: true)

        assert_equal "Leo Tolstoy", author.reload.name
      end
    end
  end
end
