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

      test "moves a list item to the target" do
        list = lists(:basic_list)
        item = ListItem.create!(list: list, listable: @source, position: 3)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, item.reload.listable_id
      end

      test "promotes verified when the target is already on the list unverified" do
        list = lists(:basic_list)
        survivor = ListItem.create!(list: list, listable: @target, position: 1, verified: false)
        dropped = ListItem.create!(list: list, listable: @source, position: 2, verified: true)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert survivor.reload.verified, "verified must survive the collision"
        assert_not ListItem.exists?(dropped.id)
      end

      # merge_list_items writes through update!/create!, which the ListItem
      # validation rejects once the list is auto_generated. Without the skip this
      # is a 500 in production admin the first time a merged book happens to sit
      # on that list.
      test "merges a book that sits on an auto-generated list without touching that list" do
        list = lists(:basic_list)
        item = ListItem.create!(list: list, listable: @source, position: 3)
        list.update!(auto_generated_kind: :user_favorites)

        # This test hand-crafts the auto-generated-list scenario without going
        # through the real generator; stub the merger's own regeneration call so a
        # real rebuild from live user_list_items can't blow away this row.
        GenerateUserFavoritesListsJob.stubs(:perform_async)

        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        # The row was left where it was and died with the source's cascade; the
        # merger never wrote a row of its own onto the generated list.
        assert_not ListItem.exists?(item.id)
        assert_nil ListItem.find_by(list: list, listable: @target)
      end

      test "does not promote verified on an auto-generated list" do
        list = lists(:basic_list)
        ListItem.create!(list: list, listable: @target, position: 1, verified: false)
        ListItem.create!(list: list, listable: @source, position: 2, verified: true)
        list.update!(auto_generated_kind: :user_favorites)

        GenerateUserFavoritesListsJob.stubs(:perform_async)

        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        survivor = ListItem.find_by(list: list, listable: @target)
        assert_not survivor.verified, "the generator owns this row; the merger must not edit it"
      end

      test "moves a personal list entry to the target" do
        user_list = user_lists(:regular_user_books_favorites)
        # This fixture row already links the list to @target; clear it so this test
        # exercises the no-collision branch, which repoints rather than drops.
        user_list_items(:regular_user_books_item_1).destroy!
        entry = UserListItem.create!(user_list: user_list, listable: @source, position: 5)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, entry.reload.listable_id
      end

      test "drops a personal list entry when the target is already in that list" do
        user_list = user_lists(:regular_user_books_favorites)
        # user_list_items(:regular_user_books_item_1) already links this list to @target.
        duplicate = UserListItem.create!(user_list: user_list, listable: @source, position: 2)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not UserListItem.exists?(duplicate.id)
        assert_equal 1, UserListItem.where(user_list: user_list, listable: @target).count
      end

      test "moves a review to the target" do
        # password_user reviews NEITHER fixture book, so this genuinely exercises the
        # repoint branch. regular_user reviews both, which would exercise the drop.
        review = Review.create!(user: users(:password_user), reviewable: @source, rating: 4)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, review.reload.reviewable_id
      end

      test "drops a source review when the same user already reviewed the target" do
        # The fixtures already ARE this scenario: regular_user reviews both books.
        kept = reviews(:regular_user_war_and_peace)
        dropped = reviews(:regular_user_crime_and_punishment)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not Review.exists?(dropped.id)
        assert Review.exists?(kept.id)
        assert_equal 1, Review.where(user: users(:regular_user), reviewable: @target).count
      end

      test "recalculates the target's review summary after moving reviews" do
        Services::Reviews::SummaryRecalculator.expects(:recalculate)
          .with("Books::Book", @target.id)
          .at_least_once

        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
      end

      # DELIBERATE, not an oversight. Books::Book includes Correctable, whose
      # dependent: :destroy lets the duplicate's corrections die with it, and the
      # merger adds no code to move them. A correction on a duplicate is very often
      # "this is a dupe of X" -- the merge IS the resolution -- and repointing would
      # leave stale duplicate reports in the pending admin queue for a book that is
      # no longer a duplicate of anything. The owner decided this explicitly.
      # This test exists so the decision cannot be silently reversed, and so a
      # reviewer who spots the missing merge_corrections finds the reasoning here.
      # See docs/superpowers/specs/2026-08-23-record-merge-design.md.
      test "lets the source's corrections die with it rather than moving them" do
        source_correction_ids = Correction.where(correctable: @source).pluck(:id)
        target_count_before = Correction.where(correctable: @target).count
        assert_operator source_correction_ids.size, :>, 0,
          "fixture precondition: the source must carry corrections for this test to mean anything"

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_empty Correction.where(id: source_correction_ids),
          "the duplicate's corrections must die with it"
        assert_equal target_count_before, Correction.where(correctable: @target).count,
          "the survivor's own corrections must be untouched, and none moved onto it"
      end

      test "moves a book relationship to the target" do
        relationship = ::Books::BookRelationship.create!(
          book: @source, related_book: books_books(:got), relation_type: :related_to
        )

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, relationship.reload.book_id
      end

      test "drops a relationship that would make the target relate to itself" do
        relationship = ::Books::BookRelationship.create!(
          book: @source, related_book: @target, relation_type: :related_to
        )

        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert result.success?, "a self-relation must be dropped, not roll the merge back"
        assert_not ::Books::BookRelationship.exists?(relationship.id)
      end

      test "drops a relationship the target already holds" do
        other = books_books(:got)
        ::Books::BookRelationship.create!(
          book: @target, related_book: other, relation_type: :related_to
        )
        duplicate = ::Books::BookRelationship.create!(
          book: @source, related_book: other, relation_type: :related_to
        )

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not ::Books::BookRelationship.exists?(duplicate.id)
      end

      test "moves an inverse book relationship to the target" do
        relationship = ::Books::BookRelationship.create!(
          book: books_books(:got), related_book: @source, relation_type: :related_to
        )

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, relationship.reload.related_book_id
      end

      test "drops an inverse relationship that would make the target relate to itself" do
        relationship = ::Books::BookRelationship.create!(
          book: @target, related_book: @source, relation_type: :related_to
        )

        result = ::Books::Book::Merger.call(source: @source, target: @target)

        assert result.success?, "a self-relation must be dropped, not roll the merge back"
        assert_not ::Books::BookRelationship.exists?(relationship.id)
      end

      test "drops an inverse relationship the target already holds" do
        other = books_books(:got)
        ::Books::BookRelationship.create!(
          book: other, related_book: @target, relation_type: :related_to
        )
        duplicate = ::Books::BookRelationship.create!(
          book: other, related_book: @source, relation_type: :related_to
        )

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not ::Books::BookRelationship.exists?(duplicate.id)
      end

      # books_series.representative_book_id is on_delete: nullify. Without an
      # explicit repoint the merge silently blanks the series' representative
      # instead of pointing it at the survivor.
      test "repoints a series whose representative book was the source" do
        series = books_series(:asoiaf)
        series.update!(representative_book: @source)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal @target.id, series.reload.representative_book_id
      end

      test "transfers authors when the target has none, renumbering position from 1" do
        target = books_books(:crime_and_punishment) # has no authors
        source = books_books(:got)                  # has king at position 1
        ::Books::BookAuthor.create!(
          book: source, author: books_authors(:tolstoy), position: 7
        )

        result = ::Books::Book::Merger.call(source: source, target: target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        positions = target.reload.book_authors.order(:position).pluck(:position)
        assert_equal [1, 2], positions, "positions must be renumbered 1..n"
        assert_equal 2, target.authors.count
      end

      test "does not transfer authors when the target already has one" do
        # @target (war_and_peace) already has tolstoy.
        ::Books::BookAuthor.create!(
          book: @source, author: books_authors(:king), position: 1
        )

        merger = ::Books::Book::Merger.new(source: @source, target: @target)
        result = merger.call

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_equal [books_authors(:tolstoy)], @target.reload.authors.to_a
        assert_equal 1, merger.stats[:book_authors_not_transferred]
      end

      test "transfers credits when the target has none" do
        target = books_books(:crime_and_punishment)
        source = books_books(:got)
        credit = ::Books::Credit.create!(
          author: books_authors(:garnett), creditable: source, role: :translator
        )

        result = ::Books::Book::Merger.call(source: source, target: target)

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_equal target.id, credit.reload.creditable_id
      end

      test "does not transfer credits when the target already has one" do
        ::Books::Credit.create!(
          author: books_authors(:garnett), creditable: @target, role: :translator
        )
        ::Books::Credit.create!(
          author: books_authors(:tolstoy), creditable: @source, role: :editor
        )

        merger = ::Books::Book::Merger.new(source: @source, target: @target)
        result = merger.call

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_equal 1, @target.reload.credits.count
        assert_equal 1, merger.stats[:credits_not_transferred]
      end

      test "gates authors and credits independently" do
        # Target has an author but no credits: authors stay, credits move.
        credit = ::Books::Credit.create!(
          author: books_authors(:garnett), creditable: @source, role: :translator
        )
        ::Books::BookAuthor.create!(book: @source, author: books_authors(:king), position: 1)

        merger = ::Books::Book::Merger.new(source: @source, target: @target)
        result = merger.call

        assert result.success?, "Merger failed: #{result.errors.inspect}"
        assert_equal 1, merger.stats[:book_authors_not_transferred]
        assert_equal @target.id, credit.reload.creditable_id
      end

      test "fills a blank field on the target from the source" do
        @source.update!(subtitle: "A Novel in Six Parts")

        merger = ::Books::Book::Merger.new(source: @source, target: @target)
        merger.call

        assert_equal "A Novel in Six Parts", @target.reload.subtitle
        assert_includes merger.stats[:filled_fields], :subtitle
      end

      test "never overwrites a non-blank field on the target" do
        @target.update!(subtitle: "The survivor's own subtitle")
        @source.update!(subtitle: "The duplicate's subtitle")

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal "The survivor's own subtitle", @target.reload.subtitle
      end

      test "takes the earlier first_published_year" do
        # crime_and_punishment is 1866, war_and_peace is 1869.
        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal 1866, @target.reload.first_published_year
      end

      test "keeps the target's year when the source's is later" do
        @source.update!(first_published_year: 1999)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal 1869, @target.reload.first_published_year
      end

      test "keeps the target's year when the source has none" do
        @source.update!(first_published_year: nil)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_equal 1869, @target.reload.first_published_year
      end

      test "absorbs the source title and its alternates into the target's alternate titles" do
        @source.update!(alternate_titles: ["Prestuplenie i nakazanie"])

        ::Books::Book::Merger.call(source: @source, target: @target)

        titles = @target.reload.alternate_titles
        assert_includes titles, "Crime and Punishment"
        assert_includes titles, "Prestuplenie i nakazanie"
        assert_includes titles, "Voyna i mir", "the target's own alternates must survive"
      end

      test "never lists the target's own title among its alternate titles" do
        @source.update!(title: "War and Peace", slug: "war-and-peace-duplicate")

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_not_includes @target.reload.alternate_titles, "War and Peace"
      end

      test "does not blank-fill amazon_enriched_at" do
        @source.update!(amazon_enriched_at: Time.current)

        ::Books::Book::Merger.call(source: @source, target: @target)

        assert_nil @target.reload.amazon_enriched_at,
          "filling this would let the enrichment sweep skip a book carrying " \
          "newly absorbed editions Amazon has never seen"
      end

      test "fills default_edition_id only after the source's editions have moved" do
        edition = ::Books::Edition.create!(book: @source, title: "Pevear translation")
        @source.update!(default_edition: edition)
        @target.update!(default_edition: nil)

        ::Books::Book::Merger.call(source: @source, target: @target)

        @target.reload
        assert_equal edition.id, @target.default_edition_id
        assert_equal @target.id, edition.reload.book_id,
          "the default edition must belong to the survivor, not to a deleted book"
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
