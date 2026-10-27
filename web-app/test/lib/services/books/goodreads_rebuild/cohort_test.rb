# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsRebuild
      class CohortTest < ActiveSupport::TestCase
        setup do
          @real_list = lists(:basic_list)
          @favorites = ::Books::List.create!(name: "Our Users' Favorite Books of All Time", status: :active,
            auto_generated_kind: :user_favorites)
          @on_real = book(20_001)
          @unlisted = book(20_002)
          @only_favorites = book(20_003)
          @both = book(20_004)
          list(@real_list, @on_real)
          list(@real_list, @both)
          favorite(@only_favorites)
          favorite(@both)
        end

        test "a pre-import book is trusted" do
          assert Cohort.trusted?(::Services::Books::Verification::Cohort::FIRST_POST_IMPORT_ID - 1)
        end

        test "a post-import book on a real list is trusted" do
          assert Cohort.trusted?(@on_real.id)
          assert_includes Cohort.trusted_post_import, @on_real
        end

        test "a post-import book on no list is derived" do
          refute Cohort.trusted?(@unlisted.id)
          assert_includes Cohort.derived, @unlisted
        end

        test "a post-import book only on the user favorites list is derived" do
          refute Cohort.trusted?(@only_favorites.id)
          assert_includes Cohort.derived, @only_favorites
        end

        test "a post-import book on the favorites list and a real list is trusted" do
          assert Cohort.trusted?(@both.id)
          refute_includes Cohort.derived, @both
        end

        test "derived is one query" do
          assert_kind_of ActiveRecord::Relation, Cohort.derived
          assert_queries_count(1) { Cohort.derived.ids }
        end

        test "counts tallies post-import books" do
          counts = Cohort.counts
          trusted = ::Books::Book.where(id: Cohort.post_import_range).count - counts["derived"]

          assert_equal trusted, counts["trusted"]
          assert_operator counts["trusted"], :>=, 2
          assert_operator counts["derived"], :>=, 2
          assert_equal 1, counts["only_on_user_favorites"]
          assert_equal [@unlisted.id, @only_favorites.id].sort, (Cohort.derived.ids & [@unlisted.id, @only_favorites.id, @on_real.id, @both.id]).sort
        end

        private

        def book(id) = ::Books::Book.create!(id: id, title: "Book #{id}")

        def list(list, book) = ListItem.create!(list: list, listable: book, position: 1)

        # The generated list refuses hand edits, so its items go in without callbacks.
        def favorite(book)
          ListItem.insert_all([{list_id: @favorites.id, listable_type: "Books::Book", listable_id: book.id, position: 1,
                                created_at: Time.current, updated_at: Time.current}])
        end
      end
    end
  end
end
