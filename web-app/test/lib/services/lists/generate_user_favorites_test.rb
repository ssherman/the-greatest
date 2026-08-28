# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    class GenerateUserFavoritesTest < ActiveSupport::TestCase
      setup do
        ::UserListItem.where(user_list_id: ::Books::UserList.select(:id)).delete_all
        @next_user = 0
        # Not a fixture: adding one would shift the penalty counts other suites
        # assert on. Created here so the wiring tests have something to find, and
        # deliberately absent in the "missing penalty" test below.
        @penalty = ::Global::Penalty.create!(name: GenerateUserFavorites::STANDARD_PENALTY_NAME)
      end

      # User has after_create :create_default_user_lists, so the favorites list
      # already exists -- find it rather than creating a second one, which
      # one_default_per_type_per_user would reject.
      def build_ballot(books)
        @next_user += 1
        user = ::User.create!(email: "voter#{@next_user}@example.com")
        list = ::Books::UserList.find_by!(user: user, list_type: :favorites)
        books.each_with_index do |book, index|
          ::UserListItem.create!(user_list: list, listable: book, position: index + 1)
        end
        list
      end

      def generate(**options)
        GenerateUserFavorites.call(user_list_class: ::Books::UserList, min_voters: 1, **options)
      end

      test "creates the list active on first run" do
        build_ballot([books_books(:war_and_peace)])

        result = generate

        assert result.success?, result.errors.inspect
        list = result.data[:list]
        assert_equal "Our Users' Favorite Books of All Time", list.name
        assert_equal "active", list.status
        assert list.generated_user_favorites?
        assert_instance_of ::Books::List, list
      end

      test "joins a new list to the domain's primary ranking configuration" do
        build_ballot([books_books(:war_and_peace)])

        list = generate.data[:list]

        ranked = list.ranked_lists.sole
        assert_equal ::Books::RankingConfiguration.default_primary, ranked.ranking_configuration
      end

      test "attaches the standard non-expert-voter penalty to a new list" do
        build_ballot([books_books(:war_and_peace)])

        list = generate.data[:list]

        assert_equal [@penalty], list.penalties.to_a
      end

      # Without a PenaltyApplication carrying a value for this configuration the
      # penalty is worth nothing (WeightCalculatorV1 skips a penalty with no
      # application), so this asserts the wiring, not the resulting weight.
      test "queues a weight calculation for the configuration it joined" do
        rc = ::Books::RankingConfiguration.default_primary
        BulkCalculateWeightsJob.expects(:perform_async).with(rc.id).once
        build_ballot([books_books(:war_and_peace)])

        assert generate.success?
      end

      test "creates the list even when the domain has no primary ranking configuration" do
        ::Books::RankingConfiguration.stubs(:default_primary).returns(nil)
        build_ballot([books_books(:war_and_peace)])

        result = generate

        assert result.success?, result.errors.inspect
        assert_empty result.data[:list].ranked_lists
        assert_equal [@penalty], result.data[:list].penalties.to_a
      end

      test "creates the list even when the standard penalty is missing" do
        @penalty.destroy!
        build_ballot([books_books(:war_and_peace)])

        io = StringIO.new
        original_logger = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(io)
        begin
          result = generate
        ensure
          Rails.logger = original_logger
        end

        assert result.success?, result.errors.inspect
        assert_empty result.data[:list].penalties
        assert_equal 1, result.data[:list].ranked_lists.count
        assert_includes io.string, GenerateUserFavorites::STANDARD_PENALTY_NAME
      end

      # The RankedList and the penalty are INVARIANTS this class maintains, not
      # create-time decoration. Production already holds a generated books list
      # created before the wiring existed -- unapproved, unranked, unpenalised --
      # and only a re-run can repair it.
      test "wires an existing list that has neither a ranked list nor a penalty" do
        build_ballot([books_books(:war_and_peace)])
        list = generate.data[:list]
        list.ranked_lists.destroy_all
        list.list_penalties.destroy_all

        generate

        assert_equal ::Books::RankingConfiguration.default_primary, list.reload.ranked_lists.sole.ranking_configuration
        assert_equal [@penalty], list.penalties.to_a
      end

      test "repairs a list that has the penalty but no ranked list" do
        build_ballot([books_books(:war_and_peace)])
        list = generate.data[:list]
        list.ranked_lists.destroy_all

        generate

        assert_equal ::Books::RankingConfiguration.default_primary, list.reload.ranked_lists.sole.ranking_configuration
        assert_equal [@penalty], list.penalties.to_a
      end

      test "repairs a list that has the ranked list but no penalty" do
        build_ballot([books_books(:war_and_peace)])
        list = generate.data[:list]
        list.list_penalties.destroy_all

        generate

        assert_equal [@penalty], list.reload.penalties.to_a
        assert_equal 1, list.ranked_lists.count
      end

      test "does not duplicate the ranked list or the penalty on a rerun" do
        build_ballot([books_books(:war_and_peace)])
        list = generate.data[:list]

        assert_no_difference [-> { ::RankedList.count }, -> { ::ListPenalty.count }] do
          generate
          generate
        end
        assert_equal 1, list.reload.ranked_lists.count
        assert_equal 1, list.list_penalties.count
      end

      # The queue is a throughput bottleneck: only an actually-created RankedList
      # earns a weight calculation.
      test "does not requeue a weight calculation when the ranked list already exists" do
        build_ballot([books_books(:war_and_peace)])
        generate

        BulkCalculateWeightsJob.expects(:perform_async).never
        generate
      end

      # status is the admin's control surface -- ItemRankings::Calculator#prepare_lists
      # reads only `status: :active`, so deactivating IS how someone takes this list
      # out of the rankings, and that intent must survive the nightly run.
      test "does not change the status of an existing list" do
        build_ballot([books_books(:war_and_peace)])
        list = generate.data[:list]
        list.update!(status: :unapproved)

        generate

        assert_equal "unapproved", list.reload.status
      end

      test "does not reactivate a rejected list" do
        build_ballot([books_books(:war_and_peace)])
        list = generate.data[:list]
        list.update!(status: :rejected)

        generate

        assert_equal "rejected", list.reload.status
      end

      test "writes items in tally order with sequential positions" do
        loved = books_books(:war_and_peace)
        liked = books_books(:got)
        3.times { build_ballot([loved]) }
        build_ballot([liked])

        list = generate.data[:list]
        items = list.list_items.order(:position)

        assert_equal [loved.id, liked.id], items.map(&:listable_id)
        assert_equal [1, 2], items.map(&:position)
        assert_equal ["Books::Book", "Books::Book"], items.map(&:listable_type)
        assert items.all?(&:verified?)
      end

      test "records the real ballot count as number_of_voters" do
        2.times { build_ballot([books_books(:war_and_peace)]) }

        assert_equal 2, generate.data[:list].number_of_voters
      end

      test "replaces items on a second run rather than accumulating" do
        build_ballot([books_books(:war_and_peace)])
        list = generate.data[:list]
        assert_equal 1, list.list_items.count

        build_ballot([books_books(:got)])
        build_ballot([books_books(:got)])
        generate

        items = list.reload.list_items.order(:position)
        assert_equal 2, items.count
        assert_equal [books_books(:got).id, books_books(:war_and_peace).id], items.map(&:listable_id)
      end

      test "reuses the same list across runs" do
        build_ballot([books_books(:war_and_peace)])

        first = generate.data[:list]
        second = generate.data[:list]

        assert_equal first.id, second.id
        assert_equal 1, ::Books::List.where(auto_generated_kind: :user_favorites).count
      end

      test "empties the list when every ballot disappears" do
        ballot = build_ballot([books_books(:war_and_peace)])
        list = generate.data[:list]
        assert_equal 1, list.list_items.count

        ballot.user_list_items.delete_all
        result = generate

        assert result.success?, result.errors.inspect
        assert_equal 0, list.reload.list_items.count
        assert_equal 0, result.data[:ballot_count]
      end

      test "returns a failure Result rather than raising" do
        UserFavoritesTally.stubs(:call).raises(ActiveRecord::StatementInvalid, "boom")

        result = generate

        refute result.success?
        assert_includes result.errors.first, "boom"
      end

      test "leaves the list untouched when the write fails partway" do
        build_ballot([books_books(:war_and_peace)])
        list = generate.data[:list]

        ::ListItem.stubs(:insert_all).raises(ActiveRecord::StatementInvalid, "boom")
        result = generate

        refute result.success?
        assert_equal 1, list.reload.list_items.count
      end

      # The Result carries only the message, and the nightly job re-raises a
      # RuntimeError of its own -- so Sidekiq records that backtrace and the real
      # one is gone unless it is written down here.
      test "logs the original exception, class and backtrace included" do
        UserFavoritesTally.stubs(:call).raises(ArgumentError, "boom")

        io = StringIO.new
        original_logger = Rails.logger
        Rails.logger = ActiveSupport::Logger.new(io)

        begin
          result = generate
        ensure
          Rails.logger = original_logger
        end

        refute result.success?
        assert_includes io.string, "ArgumentError"
        assert_includes io.string, "boom"
        # full_message, not just message: the backtrace has to survive.
        assert_includes io.string, "generate_user_favorites.rb"
      end
    end
  end
end
