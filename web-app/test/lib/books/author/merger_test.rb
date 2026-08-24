require "test_helper"

module Books
  class Author
    class MergerTest < ActiveSupport::TestCase
      def setup
        @source = books_authors(:bachman)
        @target = books_authors(:king)

        # Sidekiq test mode is :inline, and the merger fires this job
        # unconditionally (author rankings recalculate globally, so there are no
        # configuration ids to gate on). Left unstubbed it runs a real ranking
        # calculation on every test in this file. The scheduling test in Task 8
        # re-declares this with `expects`, which Mocha checks ahead of this stub.
        ::Books::CalculateAuthorRankingsJob.stubs(:perform_async)
      end

      test "merges successfully and returns the target author" do
        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_equal @target, result.data
        assert_equal [], result.errors
      end

      test "destroys the source author" do
        source_id = @source.id

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_not ::Books::Author.exists?(source_id)
      end

      test "refuses to merge an author with itself" do
        result = ::Books::Author::Merger.call(source: @source, target: @source)

        assert_not result.success?
        assert_nil result.data
        assert_equal ["Cannot merge an author with itself"], result.errors
        assert ::Books::Author.exists?(@source.id)
      end

      test "rolls the whole merge back when a step raises" do
        ::Books::Author::Merger.any_instance.stubs(:merge_all_associations)
          .raises(StandardError.new("boom"))

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert_not result.success?
        assert_nil result.data
        assert_equal ["boom"], result.errors
        assert ::Books::Author.exists?(@source.id), "source must survive a failed merge"
      end

      test "rolls back writes already made when a later step raises" do
        identifier = Identifier.create!(
          identifiable: @source, identifier_type: :books_author_viaf, value: "333"
        )
        ::Books::Author::Merger.any_instance.stubs(:reconcile_scalars)
          .raises(StandardError.new("boom"))

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert_not result.success?
        assert_equal @source.id, identifier.reload.identifiable_id,
          "the identifier move must have rolled back"
        assert ::Books::Author.exists?(@source.id)
      end

      test "moves identifiers the target does not already have" do
        identifier = Identifier.create!(
          identifiable: @source, identifier_type: :books_author_viaf, value: "111"
        )

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal @target.id, identifier.reload.identifiable_id
      end

      test "drops a source identifier the target already has" do
        Identifier.create!(identifiable: @source, identifier_type: :books_author_viaf, value: "222")
        Identifier.create!(identifiable: @target, identifier_type: :books_author_viaf, value: "222")

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal 1, Identifier.where(
          identifiable: @target, identifier_type: :books_author_viaf, value: "222"
        ).count
      end

      test "moves external links" do
        link = ExternalLink.create!(
          parent: @source,
          name: "Wikipedia",
          url: "https://example.com/bachman",
          source: :wikipedia,
          link_category: :information
        )

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal @target.id, link.reload.parent_id
      end

      test "moves AI chats" do
        chat = AiChat.create!(parent: @source, chat_type: :general, model: "gpt-4", provider: :openai)

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal @target.id, chat.reload.parent_id
      end

      test "demotes a moved image when the target already has a primary" do
        attach_image(@target, primary: true)
        source_image = attach_image(@source, primary: true)

        ::Books::Author::Merger.call(source: @source, target: @target)

        source_image.reload
        assert_equal @target.id, source_image.parent_id
        assert_not source_image.primary, "a second primary image would break primary_image"
      end

      test "keeps a moved image primary when the target has none" do
        source_image = attach_image(@source, primary: true)

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert source_image.reload.primary
      end

      test "copies source categories the target lacks" do
        category = categories(:books_fiction_genre)
        CategoryItem.create!(category: category, item: @source)

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_includes @target.reload.category_items.map(&:category_id), category.id
      end

      test "does not duplicate a category both authors share" do
        category = categories(:books_fiction_genre)
        CategoryItem.create!(category: category, item: @source)
        CategoryItem.create!(category: category, item: @target)

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal 1, CategoryItem.where(category: category, item: @target).count
      end

      def attach_image(author, primary:)
        author.images.create!(primary: primary) do |image|
          image.file.attach(
            io: StringIO.new("fake image data"),
            filename: "portrait.jpg",
            content_type: "image/jpeg"
          )
        end
      end
    end
  end
end
