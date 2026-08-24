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

      test "moves a description the target does not have" do
        description = Description.create!(
          describable: @source, kind: :summary, locale: "en",
          source: :other, source_name: "Wikipedia", content: "A pen name."
        )

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal @target.id, description.reload.describable_id
      end

      test "drops a source description that collides with the target's" do
        Description.create!(
          describable: @source, kind: :summary, locale: "en",
          source: :other, source_name: "Wikipedia", content: "From the duplicate."
        )
        Description.create!(
          describable: @target, kind: :summary, locale: "en",
          source: :other, source_name: "Wikipedia", content: "From the survivor."
        )

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        kept = Description.where(
          describable_type: "Books::Author", describable_id: @target.id,
          kind: :summary, locale: "en", source: :other, source_name: "Wikipedia"
        )
        assert_equal 1, kept.count
        assert_equal "From the survivor.", kept.first.content
      end

      test "demotes a moved description when the target already has a preferred one" do
        Description.create!(
          describable: @target, kind: :summary, locale: "en",
          source: :other, source_name: "Survivor Source", content: "Preferred.", rank: :preferred
        )
        moved = Description.create!(
          describable: @source, kind: :summary, locale: "en",
          source: :other, source_name: "Duplicate Source", content: "Also preferred.", rank: :preferred
        )

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        moved.reload
        assert_equal @target.id, moved.describable_id
        assert_equal "normal", moved.rank,
          "two preferred rows for the same kind+locale violate the partial unique index"
      end

      test "repoints the source's book links to the target" do
        link = ::Books::BookAuthor.create!(
          book: books_books(:war_and_peace), author: @source, position: 2, role: :author
        )

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal @target.id, link.reload.author_id
      end

      test "drops a book link the target already has" do
        # got_king already links :got to the target.
        ::Books::BookAuthor.create!(book: books_books(:got), author: @source, position: 2)

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal 1, ::Books::BookAuthor.where(
          book: books_books(:got), author: @target
        ).count
      end

      test "records every book the source authored, including one dropped as a duplicate" do
        ::Books::BookAuthor.create!(
          book: books_books(:war_and_peace), author: @source, position: 2
        )
        ::Books::BookAuthor.create!(book: books_books(:got), author: @source, position: 2)

        merger = ::Books::Author::Merger.new(source: @source, target: @target)
        merger.call

        assert_equal(
          [books_books(:war_and_peace).id, books_books(:got).id].sort,
          merger.affected_book_ids.sort,
          "a book whose duplicate link was dropped still changed authorship and must be reindexed"
        )
      end

      test "moves a credit the target does not have" do
        credit = ::Books::Credit.create!(
          author: @source, creditable: books_editions(:wp_maude), role: :illustrator
        )

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal @target.id, credit.reload.author_id
      end

      test "drops a credit the target already has for the same work and role" do
        ::Books::Credit.create!(
          author: @source, creditable: books_editions(:wp_maude), role: :translator
        )
        ::Books::Credit.create!(
          author: @target, creditable: books_editions(:wp_maude), role: :translator
        )

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal 1, ::Books::Credit.where(
          author: @target, creditable: books_editions(:wp_maude), role: :translator
        ).count
      end

      test "keeps a credit for the same work in a different role" do
        ::Books::Credit.create!(
          author: @source, creditable: books_editions(:wp_maude), role: :illustrator
        )
        ::Books::Credit.create!(
          author: @target, creditable: books_editions(:wp_maude), role: :translator
        )

        ::Books::Author::Merger.call(source: @source, target: @target)

        roles = ::Books::Credit.where(author: @target, creditable: books_editions(:wp_maude))
          .map(&:role).sort
        assert_equal %w[illustrator translator], roles,
          "role is part of the dedup key -- a different role is a different credit"
      end

      test "moves an outbound relationship to the target" do
        relationship = ::Books::AuthorRelationship.create!(
          from_author: @source, to_author: books_authors(:garnett), relation_type: :member_of
        )

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal @target.id, relationship.reload.from_author_id
      end

      test "drops an outbound relationship that would point at the target itself" do
        # The bachman_is_king fixture is exactly this: bachman -> king.
        relationship = books_author_relationships(:bachman_is_king)

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_not ::Books::AuthorRelationship.exists?(relationship.id),
          "repointing this would make the survivor a pseudonym of itself"
      end

      test "drops an outbound relationship the target already has" do
        ::Books::AuthorRelationship.create!(
          from_author: @source, to_author: books_authors(:garnett), relation_type: :member_of
        )
        ::Books::AuthorRelationship.create!(
          from_author: @target, to_author: books_authors(:garnett), relation_type: :member_of
        )

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal 1, ::Books::AuthorRelationship.where(
          from_author: @target, to_author: books_authors(:garnett), relation_type: :member_of
        ).count
      end

      test "moves an inbound relationship to the target" do
        relationship = ::Books::AuthorRelationship.create!(
          from_author: books_authors(:garnett), to_author: @source, relation_type: :member_of
        )

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal @target.id, relationship.reload.to_author_id
      end

      test "drops an inbound relationship that would come from the target itself" do
        relationship = ::Books::AuthorRelationship.create!(
          from_author: @target, to_author: @source, relation_type: :member_of
        )

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_not ::Books::AuthorRelationship.exists?(relationship.id),
          "repointing this would make the survivor a member of itself"
      end

      test "drops an inbound relationship the target already has" do
        ::Books::AuthorRelationship.create!(
          from_author: books_authors(:garnett), to_author: @source, relation_type: :member_of
        )
        ::Books::AuthorRelationship.create!(
          from_author: books_authors(:garnett), to_author: @target, relation_type: :member_of
        )

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal 1, ::Books::AuthorRelationship.where(
          from_author: books_authors(:garnett), to_author: @target, relation_type: :member_of
        ).count
      end

      test "fills a blank sort name from the source" do
        @source.update!(sort_name: "Bachman, Richard")

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal "Bachman, Richard", @target.reload.sort_name
      end

      test "never overwrites a field the target already has" do
        @source.update!(birth_year: 1900)

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal 1947, @target.reload.birth_year, "the survivor's own value always wins"
      end

      test "absorbs the source's name into the target's alternate names" do
        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_includes @target.reload.alternate_names, "Richard Bachman",
          "folding a pseudonym in should leave the deleted spelling searchable"
      end

      test "absorbs the source's own alternate names too" do
        @source.update!(alternate_names: ["R. Bachman"])

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_includes @target.reload.alternate_names, "R. Bachman"
      end

      test "does not duplicate an alternate name the target already has" do
        @target.update!(alternate_names: ["Richard Bachman"])

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal ["Richard Bachman"], @target.reload.alternate_names
      end

      test "never records the survivor's own name as one of its alternate names" do
        @source.update!(alternate_names: [@target.name])

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_not_includes @target.reload.alternate_names, @target.name
      end

      test "never lets the source's exclude_from_rankings overwrite the target's" do
        @source.update!(exclude_from_rankings: true)

        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_not @target.reload.exclude_from_rankings,
          "false.present? is false, so a naive blank-fill would flip the survivor's flag"
      end

      test "never lets the source's kind overwrite the target's" do
        ::Books::Author::Merger.call(source: @source, target: @target)

        assert_equal "person", @target.reload.kind,
          "the survivor must not become a pseudonym because the duplicate was one"
      end

      test "queues the target for reindexing" do
        neutralize_scalar_confound

        merger = ::Books::Author::Merger.new(source: @source, target: @target)
        result = merger.call

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_nil merger.stats[:post_commit_error]
        assert SearchIndexRequest.exists?(
          parent_type: "Books::Author", parent_id: @target.id, action: "index_item"
        )
      end

      test "does not queue indexing while migration suppression is on" do
        neutralize_scalar_confound
        Services::BooksMigration.stubs(:search_indexing_suppressed?).returns(true)

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_not SearchIndexRequest.exists?(
          parent_type: "Books::Author", parent_id: @target.id, action: "index_item"
        )
      end

      test "queues a reindex for every book the source authored" do
        ::Books::BookAuthor.create!(
          book: books_books(:war_and_peace), author: @source, position: 2
        )
        ::Books::BookAuthor.create!(book: books_books(:got), author: @source, position: 2)
        SearchIndexRequest.where(parent_type: "Books::Book").delete_all

        merger = ::Books::Author::Merger.new(source: @source, target: @target)
        merger.call

        assert_nil merger.stats[:post_commit_error]
        queued = SearchIndexRequest.where(
          parent_type: "Books::Book", action: "index_item"
        ).pluck(:parent_id).uniq.sort
        assert_equal(
          [books_books(:war_and_peace).id, books_books(:got).id].sort, queued,
          "a book's search document embeds author_names/author_ids, so both the moved " \
          "link and the dropped duplicate change what the book indexes"
        )
      end

      test "does not queue book reindexes while migration suppression is on" do
        ::Books::BookAuthor.create!(
          book: books_books(:war_and_peace), author: @source, position: 2
        )
        SearchIndexRequest.where(parent_type: "Books::Book").delete_all
        Services::BooksMigration.stubs(:search_indexing_suppressed?).returns(true)

        result = ::Books::Author::Merger.call(source: @source, target: @target)

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_equal 0, SearchIndexRequest.where(parent_type: "Books::Book").count
      end

      test "schedules the author ranking recalculation" do
        ::Books::CalculateAuthorRankingsJob.expects(:perform_async).once

        merger = ::Books::Author::Merger.new(source: @source, target: @target)
        result = merger.call

        assert result.success?, "merge must succeed, not roll back: #{result.errors.inspect}"
        assert_nil merger.stats[:post_commit_error],
          "a violated Mocha expectation in a post-commit step is swallowed into this key"
      end

      test "still reports success when scheduling the ranking job fails" do
        source_id = @source.id

        merger = ::Books::Author::Merger.new(source: @source, target: @target)
        merger.stubs(:schedule_ranking_recalculation).raises(StandardError.new("redis down"))

        result = merger.call

        assert result.success?,
          "a post-commit failure must not be reported as a failed merge: #{result.errors.inspect}"
        assert_not ::Books::Author.exists?(source_id), "the merge itself must still have committed"
        assert_equal "redis down", merger.stats[:post_commit_error]
      end

      test "still reports success when reindexing the target fails" do
        source_id = @source.id

        merger = ::Books::Author::Merger.new(source: @source, target: @target)
        merger.stubs(:reindex_target_author).raises(StandardError.new("opensearch down"))

        result = merger.call

        assert result.success?,
          "a post-commit failure must not be reported as a failed merge: #{result.errors.inspect}"
        assert_not ::Books::Author.exists?(source_id), "the merge itself must still have committed"
        assert_equal "opensearch down", merger.stats[:post_commit_error]
      end

      # SearchIndexable's after_commit fires as the transaction block exits -- i.e.
      # AFTER the commit -- and Rails 8 propagates exceptions raised there. They land
      # in call's own rescue ladder, which would otherwise report success?: false for
      # a merge whose source is already permanently deleted, sending the admin to a
      # retry that fails with "not found".
      test "still reports success when a commit callback fails after the merge committed" do
        source_id = @source.id
        SearchIndexRequest.stubs(:create!).raises(StandardError.new("index store down"))

        merger = ::Books::Author::Merger.new(source: @source, target: @target)
        result = merger.call

        assert result.success?,
          "a commit-callback failure must not be reported as a failed merge: #{result.errors.inspect}"
        assert_not ::Books::Author.exists?(source_id), "the merge itself must still have committed"
        assert_equal "index store down", merger.stats[:post_commit_error]
      end

      # The discriminator for "did it commit" is the source row's absence, so a merge
      # that never started because the source was already gone must NOT be mistaken
      # for a committed one.
      test "reports failure when the source disappears before it can be locked" do
        source_id = @source.id
        merger = ::Books::Author::Merger.new(source: @source, target: @target)
        merger.stubs(:lock_authors).raises(ActiveRecord::RecordNotFound.new("gone"))

        # Stand in for a concurrent merge that already consumed this source: it
        # would have moved the relationships off before deleting the row.
        ::Books::AuthorRelationship.where(from_author_id: source_id).delete_all
        ::Books::AuthorRelationship.where(to_author_id: source_id).delete_all
        ::Books::Author.where(id: source_id).delete_all

        result = merger.call

        assert_not result.success?, "a merge that never ran must not report success"
        assert_equal ["gone"], result.errors
      end

      test "locks both authors for update, in ascending id order, before moving anything" do
        locked = []
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
          sql = payload[:sql]
          next unless sql.include?("books_authors") && sql.include?("FOR UPDATE")

          # The id is a bind parameter ($1), not literal text in the SQL.
          binds = payload[:type_casted_binds]
          binds = binds.call if binds.respond_to?(:call)
          locked << Array(binds).first
        end

        begin
          result = ::Books::Author::Merger.call(source: @source, target: @target)
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end

        assert result.success?, "merge must succeed: #{result.errors.inspect}"
        assert_equal [@source.id, @target.id].sort, locked.compact,
          "both rows must be locked FOR UPDATE in ascending id order, or two merges " \
          "with swapped source and target can deadlock each other"
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

      # reconcile_scalars all but always dirties the target -- absorbing the source's
      # name into alternate_names alone does it -- and target_author.save! then fires
      # SearchIndexable's after_commit, creating the very index_item row the two
      # reindex tests are trying to attribute to reindex_target_author. Without this
      # they pass with that method stubbed empty. Pre-load the absorption result so
      # reconcile_scalars finds nothing to change, using update_columns to skip both
      # validations and callbacks.
      def neutralize_scalar_confound
        @target.update_columns(alternate_names: [@source.name])
        @target.reload
      end
    end
  end
end
