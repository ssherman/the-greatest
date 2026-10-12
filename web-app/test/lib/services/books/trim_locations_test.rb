require "test_helper"

module Services
  module Books
    class TrimLocationsTest < ActiveSupport::TestCase
      TrimTask = ::Services::Ai::Tasks::Books::LocationTrimTask

      setup do
        Rails.configuration.x.categories_cleanup.stubs(:max_direct_locations).returns(2)
        @book = books_books(:war_and_peace)
        @book.category_items.destroy_all
        @russia = ::Books::Category.create!(name: "Russia", category_type: :location)
        @moscow = ::Books::Category.create!(name: "Moscow", category_type: :location, parent: @russia)
        @peru = ::Books::Category.create!(name: "Peru", category_type: :location)
        @chile = ::Books::Category.create!(name: "Chile", category_type: :location)
        CategoryItem.create!(category: @moscow, item: @book)
        CategoryItem.create!(category: @peru, item: @book)
        CategoryItem.create!(category: @chile, item: @book, source: :admin)
        ::Categories::AncestorReconciler.call(item_ids: [@book.id])
      end

      def stub_keep(ids)
        TrimTask.any_instance.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: {keep_ids: ids, reason: "Set in Moscow."}))
      end

      test "removes the legacy links the model did not keep, never admin links, and keeps inherited ones right" do
        stub_keep([@moscow.id])

        result = TrimLocations.call(book: @book)

        assert result.success?
        refute CategoryItem.exists?(category: @peru, item: @book)
        assert CategoryItem.exists?(category: @chile, item: @book)
        assert CategoryItem.exists?(category: @russia, item: @book, source: :inherited)
        assert_equal [@peru.id], result.data[:removed]
      end

      test "writes one ledger row and does not trim the same book twice unless forced" do
        stub_keep([@moscow.id])
        TrimLocations.call(book: @book)

        assert_equal 1, @book.enrichments.for_kind(TrimLocations::KIND).count
        assert_equal "already trimmed", TrimLocations.call(book: @book).data[:skipped]
      end

      test "a dry run writes nothing" do
        stub_keep([@moscow.id])

        result = TrimLocations.call(book: @book, dry_run: true)

        assert_equal [@peru.id], result.data[:removed]
        assert CategoryItem.exists?(category: @peru, item: @book)
        assert @book.enrichments.for_kind(TrimLocations::KIND).none?
      end

      test "a book at or under the limit is skipped without calling the AI" do
        CategoryItem.where(category: @peru, item: @book).destroy_all
        TrimTask.any_instance.expects(:call).never

        assert_equal "not over the limit", TrimLocations.call(book: @book).data[:skipped]
      end

      test "a failed AI call changes nothing" do
        TrimTask.any_instance.stubs(:call).returns(::Services::Ai::Result.new(success: false, error: "timeout"))

        result = TrimLocations.call(book: @book)

        refute result.success?
        assert CategoryItem.exists?(category: @peru, item: @book)
      end

      test "candidate_ids lists books over the limit that were not trimmed yet" do
        assert_includes TrimLocations.candidate_ids, @book.id

        stub_keep([@moscow.id])
        TrimLocations.call(book: @book)

        refute_includes TrimLocations.candidate_ids, @book.id
      end

      test "candidate_ids with force still lists a trimmed book that is over the limit, and call(force) re-trims it" do
        stub_keep([@moscow.id])
        TrimLocations.call(book: @book)
        CategoryItem.create!(category: @peru, item: @book)

        refute_includes TrimLocations.candidate_ids, @book.id
        assert_includes TrimLocations.candidate_ids(force: true), @book.id

        result = TrimLocations.call(book: @book, force: true)

        assert_equal [@peru.id], result.data[:removed]
        assert_equal 2, @book.enrichments.for_kind(TrimLocations::KIND).count
      end

      test "an answer with no offered ids fails and writes nothing" do
        TrimTask.any_instance.stubs(:call).returns(::Services::Ai::Result.new(success: true, data: {keep_ids: [], raw_count: 2, reason: "x"}))

        result = TrimLocations.call(book: @book)

        refute result.success?
        assert_equal ["model returned no offered ids"], result.errors
        assert CategoryItem.exists?(category: @peru, item: @book)
        assert @book.enrichments.for_kind(TrimLocations::KIND).none?
      end

      test "an empty keep on a book not marked nonfiction needs review and writes nothing" do
        stub_keep([])

        result = TrimLocations.call(book: @book)

        assert result.success?
        assert_equal "needs review: empty keep on a book not marked nonfiction", result.data[:skipped]
        assert CategoryItem.exists?(category: @peru, item: @book)
        assert @book.enrichments.for_kind(TrimLocations::KIND).none?
      end

      test "an empty keep on a nonfiction book still trims" do
        nonfiction = ::Books::Category.create!(name: "Nonfiction Type", category_type: :genre)
        CategoryItem.create!(category: nonfiction, item: @book, source: :admin)
        ::Books::BookType.stubs(:category_id).with(1).returns(nonfiction.id)
        stub_keep([])

        result = TrimLocations.call(book: @book)

        assert_equal [@moscow.id, @peru.id].sort, result.data[:removed].sort
        refute CategoryItem.exists?(category: @peru, item: @book)
      end

      test "a failed AI call writes no ledger row" do
        TrimTask.any_instance.stubs(:call).returns(::Services::Ai::Result.new(success: false, error: "timeout"))
        TrimLocations.call(book: @book)

        assert @book.enrichments.for_kind(TrimLocations::KIND).none?
      end

      test "a run that removes nothing records nothing_to_apply" do
        stub_keep([@moscow.id, @peru.id])

        TrimLocations.call(book: @book)

        assert_equal ["nothing_to_apply"], @book.enrichments.for_kind(TrimLocations::KIND).pluck(:outcome)
      end

      test "music categories are untouched" do
        music = ::Music::Category.create!(name: "Rock", category_type: :genre)
        stub_keep([@moscow.id])

        TrimLocations.call(book: @book)

        assert ::Music::Category.exists?(music.id)
        assert_equal [], TrimLocations.direct_location_links.where(category_id: music.id).to_a
      end

      test "the offer carries the full chain with its root and marks admin links fixed" do
        offered = nil
        TrimTask.stubs(:new).with { |book:, locations:| offered = locations }.returns(stub(call: ::Services::Ai::Result.new(success: true, data: {keep_ids: [@moscow.id], raw_count: 1, reason: "x"})))

        TrimLocations.call(book: @book)

        by_id = offered.index_by(&:id)
        assert_equal "Moscow, Russia", by_id[@moscow.id].trail
        assert by_id[@chile.id].fixed
        refute by_id[@peru.id].fixed
      end
    end
  end
end
