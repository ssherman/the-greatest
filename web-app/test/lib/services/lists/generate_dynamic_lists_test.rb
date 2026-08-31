# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    class GenerateDynamicListsTest < ActiveSupport::TestCase
      setup do
        @config = ranking_configurations(:books_year_2025)
        @books = [
          books_books(:war_and_peace),
          books_books(:crime_and_punishment),
          books_books(:combo_steinbeck),
          books_books(:got),
          books_books(:clash)
        ]
      end

      # Ranks the given books 1..N on the year configuration. The generator
      # reads ranked_items, so this stands in for a real ranking run.
      def rank(books)
        books.each_with_index do |book, index|
          ::RankedItem.create!(ranking_configuration: @config, item: book,
            rank: index + 1, score: (100 - index).to_d)
        end
      end

      def generate(**options)
        GenerateDynamicLists.call(ranking_configuration: @config,
          recalculate_primary: false, **options)
      end

      test "fails when the configuration has no year" do
        @config.update_column(:year, nil)

        result = generate

        assert_not result.success?
        assert_match(/no year/, result.errors.first)
      end

      test "fails when the domain does not support year rollups" do
        config = ranking_configurations(:books_authors_global)
        config.update_columns(year: 2025, primary_mapped_list_cutoff_limit: 10)

        result = GenerateDynamicLists.call(ranking_configuration: config,
          recalculate_primary: false)

        assert_not result.success?
        assert_match(/does not support year rollups/, result.errors.first)
      end

      test "fails when the primary cutoff is unset" do
        @config.update_column(:primary_mapped_list_cutoff_limit, nil)

        result = generate

        assert_not result.success?
        assert_match(/primary cutoff/, result.errors.first)
      end

      test "creates both lists active on first run, named from year and cutoff" do
        rank(@books)

        result = generate

        assert result.success?, result.errors.inspect
        top = result.data[:top_list]
        overflow = result.data[:overflow_list]

        assert_equal "The 2 Greatest Books of 2025", top.name
        assert_equal "The Greatest Books of 2025 - Honorable Mention", overflow.name
        assert_equal "active", top.status
        assert_equal "active", overflow.status
        assert top.generated_year_top?
        assert overflow.generated_year_honorable_mention?
        assert_equal 2025, top.auto_generated_year
        assert_instance_of ::Books::List, top
      end

      test "writes the top window in rank order starting at position 1" do
        rank(@books)

        top = generate.data[:top_list]

        items = top.list_items.order(:position)
        assert_equal [1, 2], items.map(&:position)
        assert_equal @books.first(2).map(&:id), items.map(&:listable_id)
        assert_equal ["Books::Book", "Books::Book"], items.map(&:listable_type)
        assert items.all?(&:verified?)
      end

      test "the overflow window starts after the primary cutoff and renumbers from 1" do
        rank(@books)

        overflow = generate.data[:overflow_list]

        items = overflow.list_items.order(:position)
        assert_equal [1, 2], items.map(&:position)
        assert_equal @books[2, 2].map(&:id), items.map(&:listable_id)
      end

      test "reads items by rank, not by insertion order" do
        # Insert in ascending-id (natural) order but rank in reverse, so
        # insertion order and rank order disagree. If .order(:rank) were ever
        # dropped from top_items/overflow_items, Postgres would still return
        # these rows in roughly insertion order and this test would catch it.
        @books.each_with_index do |book, index|
          ::RankedItem.create!(ranking_configuration: @config, item: book,
            rank: @books.size - index, score: (100 - index).to_d)
        end

        result = generate
        top = result.data[:top_list]
        overflow = result.data[:overflow_list]

        assert_equal [@books[4].id, @books[3].id],
          top.list_items.order(:position).map(&:listable_id)
        assert_equal [@books[2].id, @books[1].id],
          overflow.list_items.order(:position).map(&:listable_id)
      end

      test "the secondary cutoff drops the tail" do
        rank(@books)

        assert_equal 2, generate.data[:overflow_count]
        assert_equal 5, @config.ranked_items.count
      end

      test "a nil secondary cutoff means uncapped" do
        rank(@books)
        @config.update_column(:secondary_mapped_list_cutoff_limit, nil)

        assert_equal 3, generate.data[:overflow_count]
      end

      test "carries the source rank and score in item metadata" do
        rank(@books)

        item = generate.data[:top_list].list_items.order(:position).first

        assert_equal 1, item.metadata["source_rank"]
        assert_equal 100.0, item.metadata["source_score"]
      end

      test "rewrites items rather than appending on a second run" do
        rank(@books)
        generate

        ::RankedItem.where(ranking_configuration: @config).delete_all
        rank(@books.reverse)
        result = generate

        top = result.data[:top_list]
        assert_equal 2, top.list_items.count
        assert_equal @books.last(2).reverse.map(&:id),
          top.list_items.order(:position).map(&:listable_id)
      end

      test "finds the same lists on a second run rather than creating new ones" do
        rank(@books)
        first = generate.data[:top_list]

        second = generate.data[:top_list]

        assert_equal first.id, second.id
        assert_equal 1, ::Books::List.where(auto_generated_kind: :year_top,
          auto_generated_year: 2025).count
      end

      test "finds a renamed list by kind and year, not by name" do
        rank(@books)
        top = generate.data[:top_list]
        top.update!(name: "Something Else Entirely")

        assert_equal top.id, generate.data[:top_list].id
      end

      test "points the configuration at the lists it generated" do
        rank(@books)

        result = generate

        @config.reload
        assert_equal result.data[:top_list].id, @config.primary_mapped_list_id
        assert_equal result.data[:overflow_list].id, @config.secondary_mapped_list_id
      end

      test "leaves name and description alone on a second run" do
        rank(@books)
        top = generate.data[:top_list]
        top.update!(name: "Curated Name", description: "Curated description")

        generate

        top.reload
        assert_equal "Curated Name", top.name
        assert_equal "Curated description", top.description
      end

      test "leaves status alone on a second run" do
        rank(@books)
        top = generate.data[:top_list]
        top.update!(status: :unapproved)

        generate

        assert_equal "unapproved", top.reload.status
      end

      test "asserts every weight-affecting field on both lists" do
        rank(@books)

        result = generate

        [result.data[:top_list], result.data[:overflow_list]].each do |list|
          assert_equal 1, list.num_years_covered
          assert_equal 2025, list.year_published
          assert_equal false, list.voter_count_unknown
          assert_equal false, list.voter_count_estimated
          assert_equal true, list.voter_names_unknown
          assert_equal true, list.high_quality_source
          assert_equal false, list.category_specific
          assert_equal false, list.location_specific
          assert_equal false, list.creator_specific
        end
      end

      test "number_of_voters counts active source lists only" do
        rank(@books)
        active = lists(:basic_list)
        active.update!(status: :active)
        inactive = lists(:another_list)
        inactive.update!(status: :unapproved)
        ::RankedList.create!(list: active, ranking_configuration: @config)
        ::RankedList.create!(list: inactive, ranking_configuration: @config)

        result = generate

        assert_equal 1, result.data[:source_list_count]
        assert_equal 1, result.data[:top_list].number_of_voters
      end

      # This is the 2024/2023 shape from production: penalties totalled 190%, capped
      # at 100%, and the list weighed 0 while holding 1,114 items.
      test "repairs a list left with unknown voter count and no quality flag" do
        rank(@books)
        broken = ::Books::List.create!(
          name: "Hand-made overflow", status: :active,
          auto_generated_kind: :year_honorable_mention, auto_generated_year: 2025,
          voter_count_unknown: true, high_quality_source: false
        )

        generate

        broken.reload
        assert_equal false, broken.voter_count_unknown
        assert_equal true, broken.high_quality_source
      end

      test "tags both lists with the domain's one-year penalty" do
        rank(@books)
        penalty = penalties(:books_one_year_penalty)

        result = generate

        assert_includes result.data[:top_list].penalties, penalty
        assert_includes result.data[:overflow_list].penalties, penalty
      end

      test "tags only the overflow list as an honorable mention" do
        rank(@books)
        penalty = penalties(:honorable_mention_penalty)

        result = generate

        assert_includes result.data[:overflow_list].penalties, penalty
        assert_not_includes result.data[:top_list].penalties, penalty
      end

      test "does not duplicate penalty tags across runs" do
        rank(@books)
        generate

        overflow = generate.data[:overflow_list]

        assert_equal overflow.penalties.count, overflow.penalties.distinct.count
      end

      test "warns and continues when the domain's one-year penalty is missing" do
        rank(@books)
        penalties(:books_one_year_penalty).destroy!

        result = generate

        assert result.success?, result.errors.inspect
        assert_empty result.data[:top_list].penalties.where(type: "Books::Penalty")
      end

      # Attaching the tag is a fact about the list. Choosing what it is worth is an
      # editorial judgement, so the generator never creates a PenaltyApplication.
      test "never creates a penalty application" do
        rank(@books)
        before = ::PenaltyApplication.count

        generate

        assert_equal before, ::PenaltyApplication.count
      end

      test "joins both lists to the domain's primary configuration" do
        rank(@books)

        result = generate

        main = ::Books::RankingConfiguration.default_primary
        [result.data[:top_list], result.data[:overflow_list]].each do |list|
          assert_equal main, list.ranked_lists.sole.ranking_configuration
        end
      end

      test "repairs a missing ranked list on a later run" do
        rank(@books)
        top = generate.data[:top_list]
        top.ranked_lists.delete_all

        generate

        assert_equal 1, top.reload.ranked_lists.count
      end
    end
  end
end
