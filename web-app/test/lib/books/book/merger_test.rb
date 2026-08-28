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
