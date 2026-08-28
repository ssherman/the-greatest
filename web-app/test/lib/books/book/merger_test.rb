require "test_helper"

module Books
  class Book
    class MergerTest < ActiveSupport::TestCase
      def setup
        @source = books_books(:crime_and_punishment)
        @target = books_books(:war_and_peace)
      end

      test "merges successfully and returns the target book" do
        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_equal @target, result.data
        assert_equal [], result.errors
      end

      test "destroys the source book" do
        source_id = @source.id

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not ::Books::Book.exists?(source_id)
      end

      test "refuses to merge a book with itself" do
        result = ::Books::Book::Merger.call(source: @source, target: @source)

        assert_not result.success?
        assert_nil result.data
        assert_equal ["Cannot merge a book with itself"], result.errors
        assert ::Books::Book.exists?(@source.id)
      end

      test "rolls the whole merge back when a step raises" do
        ::Books::Book::Merger.any_instance.stubs(:merge_all_associations)
          .raises(StandardError.new("boom"))

        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not result.success?
        assert_nil result.data
        assert_equal ["boom"], result.errors
        assert ::Books::Book.exists?(@source.id), "source must survive a failed merge"
      end

      test "rolls back writes already made when a later step raises" do
        identifier = Identifier.create!(
          identifiable: @source, identifier_type: :books_work_isbn10, value: "0140449132"
        )
        ::Books::Book::Merger.any_instance.stubs(:reconcile_scalars)
          .raises(StandardError.new("boom"))

        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not result.success?
        assert_equal @source.id, identifier.reload.identifiable_id,
          "the identifier move must have rolled back"
        assert ::Books::Book.exists?(@source.id)
      end

      test "moves editions to the target" do
        edition = ::Books::Edition.create!(book: @source, title: "Pevear translation")

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, edition.reload.book_id
      end

      test "moves external links to the target" do
        link = ExternalLink.create!(
          parent: @source, name: "Wikipedia", url: "https://example.com/cp", source: :wikipedia
        )

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, link.reload.parent_id
      end

      test "moves ai chats to the target" do
        chat = AiChat.create!(parent: @source, chat_type: :general, model: "gpt-4", provider: :openai)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, chat.reload.parent_id
      end

      test "moves images to the target" do
        image = attach_image(@source, primary: false)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, image.reload.parent_id
      end

      test "demotes a moved primary image when the target already has one" do
        attach_image(@target, primary: true)
        moved = attach_image(@source, primary: true)

        ::Books::Book::Merger.call(source: @source, target: @target)

        moved.reload
        assert_equal @target.id, moved.parent_id
        assert_not moved.primary, "two primary images on one book is the bug this prevents"
      end

      test "keeps a moved primary image when the target has none" do
        moved = attach_image(@source, primary: true)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert moved.reload.primary
      end

      test "moves an identifier the target does not already have" do
        identifier = Identifier.create!(
          identifiable: @source, identifier_type: :books_work_isbn10, value: "0140449132"
        )

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, identifier.reload.identifiable_id
      end

      test "drops a source identifier the target already has" do
        Identifier.create!(
          identifiable: @target, identifier_type: :books_work_isbn10, value: "0140449132"
        )
        duplicate = Identifier.create!(
          identifiable: @source, identifier_type: :books_work_isbn10, value: "0140449132"
        )

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not Identifier.exists?(duplicate.id)
        assert_equal 1, Identifier.where(
          identifiable_type: "Books::Book", identifiable_id: @target.id,
          identifier_type: "books_work_isbn10", value: "0140449132"
        ).count
      end

      test "moves a country the target does not already have" do
        link = ::Books::BookCountry.create!(book: @source, country: books_countries(:japanese))

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, link.reload.book_id
      end

      test "drops a source country the target already has and keeps the counter honest" do
        country = books_countries(:french) # war_and_peace already links to this
        duplicate = ::Books::BookCountry.create!(book: @source, country: country)
        before = country.reload.book_count

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not ::Books::BookCountry.exists?(duplicate.id)
        assert_equal before - 1, country.reload.book_count,
          "the drop must go through destroy! so the counter_cache decrements"
      end

      test "moves a series link the target does not already have" do
        link = books_series_books(:asoiaf_novella) # belongs to crime_and_punishment

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, link.reload.book_id
      end

      test "drops a source series link the target already has" do
        series = books_series(:asoiaf)
        ::Books::SeriesBook.create!(series: series, book: @target, position: 9)
        duplicate = books_series_books(:asoiaf_novella)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not ::Books::SeriesBook.exists?(duplicate.id)
        assert_equal 1, ::Books::SeriesBook.where(series: series, book: @target).count
      end

      test "copies a category the target does not already have" do
        category = ::Books::Category.create!(name: "Russian Realism", category_type: :genre)
        CategoryItem.create!(category: category, item: @source)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert CategoryItem.exists?(category_id: category.id, item: @target)
      end

      test "does not duplicate a category the target already has" do
        category = ::Books::Category.create!(name: "Russian Realism", category_type: :genre)
        CategoryItem.create!(category: category, item: @target)
        CategoryItem.create!(category: category, item: @source)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal 1, CategoryItem.where(category_id: category.id, item_type: "Books::Book",
          item_id: @target.id).count
      end

      test "moves a description the target does not already have" do
        description = Description.create!(
          describable: @source, kind: :blurb, locale: "en", source: :ai_generated, content: "A summary."
        )

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, description.reload.describable_id
      end

      test "drops a source description that collides on kind, locale, source and source_name" do
        Description.create!(
          describable: @target, kind: :blurb, locale: "en", source: :ai_generated, content: "Target's."
        )
        duplicate = Description.create!(
          describable: @source, kind: :blurb, locale: "en", source: :ai_generated, content: "Source's."
        )

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not Description.exists?(duplicate.id)
      end

      test "demotes a moved preferred description when the target already has one for that key" do
        Description.create!(
          describable: @target, kind: :blurb, locale: "en", source: :ai_generated,
          content: "Target's.", rank: :preferred
        )
        moved = Description.create!(
          describable: @source, kind: :blurb, locale: "en", source: :manual,
          content: "Source's.", rank: :preferred
        )

        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        moved.reload
        assert_equal @target.id, moved.describable_id
        assert_not moved.preferred?, "two preferred rows for one kind+locale violates the index"
      end

      private

      def attach_image(book, primary:)
        book.images.create!(primary: primary) do |image|
          image.file.attach(
            io: StringIO.new("fake image data"),
            filename: "cover.jpg",
            content_type: "image/jpeg"
          )
        end
      end
    end
  end
end
