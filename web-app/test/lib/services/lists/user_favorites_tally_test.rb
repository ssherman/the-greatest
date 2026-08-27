# frozen_string_literal: true

require "test_helper"

module Services
  module Lists
    class UserFavoritesTallyTest < ActiveSupport::TestCase
      # Fixtures ship one books favorites ballot (regular_user, two items). These
      # tests assert exact scores, so they need to own the whole population.
      # The deletion is transaction-scoped and reverted after each test.
      setup do
        ::UserListItem.where(user_list_id: ::Books::UserList.select(:id)).delete_all
        @next_user = 0
      end

      # Each ballot needs its own user: UserList validates one default list per
      # type per user, and the tally counts distinct voters.
      #
      # User has after_create :create_default_user_lists, so the favorites list
      # already exists by the time create! returns -- find it, never create a
      # second one, which one_default_per_type_per_user would reject. (Fixture
      # users skip that callback; only User.create! fires it.)
      def build_ballot(books, manually_ordered: false)
        @next_user += 1
        user = ::User.create!(email: "voter#{@next_user}@example.com")
        list = ::Books::UserList.find_by!(user: user, list_type: :favorites)
        list.update!(manually_ordered: manually_ordered)
        books.each_with_index do |book, index|
          ::UserListItem.create!(user_list: list, listable: book, position: index + 1)
        end
        list
      end

      def filler_books(count)
        Array.new(count) { |i| ::Books::Book.create!(title: "Filler Book #{i}") }
      end

      def tally(**options)
        UserFavoritesTally.call(user_list_class: ::Books::UserList, min_voters: 1, **options)
      end

      def score_for(result, book)
        result.entries.find { |entry| entry.listable_id == book.id }&.score
      end

      test "an unordered ballot splits its mass evenly" do
        a = books_books(:war_and_peace)
        b = books_books(:got)
        c = books_books(:clash)
        build_ballot([a, b, c])

        result = tally

        # Mass is sqrt(3); three items share it equally.
        expected = Math.sqrt(3) / 3
        assert_in_delta expected, score_for(result, a), 0.0001
        assert_in_delta expected, score_for(result, b), 0.0001
        assert_in_delta expected, score_for(result, c), 0.0001
      end

      test "a curated ballot splits its mass by position" do
        a = books_books(:war_and_peace)
        b = books_books(:got)
        c = books_books(:clash)
        build_ballot([a, b, c], manually_ordered: true)

        result = tally(decay_exponent: 2.0)

        # Weights are 3^2, 2^2, 1^2 = 9, 4, 1 over a total of 14.
        mass = Math.sqrt(3)
        assert_in_delta mass * 9 / 14.0, score_for(result, a), 0.0001
        assert_in_delta mass * 4 / 14.0, score_for(result, b), 0.0001
        assert_in_delta mass * 1 / 14.0, score_for(result, c), 0.0001
      end

      test "both ballot shapes spend exactly the same total mass" do
        flat = build_ballot(filler_books(6))
        curated = build_ballot(filler_books(6), manually_ordered: true)

        result = tally

        flat_ids = flat.user_list_items.pluck(:listable_id)
        curated_ids = curated.user_list_items.pluck(:listable_id)
        total = ->(ids) { result.entries.select { |e| ids.include?(e.listable_id) }.sum(&:score) }

        assert_in_delta Math.sqrt(6), total.call(flat_ids), 0.0001
        assert_in_delta Math.sqrt(6), total.call(curated_ids), 0.0001
      end

      test "ballot mass grows as the square root of list size, not linearly" do
        one = books_books(:war_and_peace)
        build_ballot([one])
        nine = filler_books(9)
        build_ballot(nine)

        result = tally

        # A 9-item ballot is worth 3x a 1-item ballot in total, not 9x.
        nine_total = result.entries.select { |e| nine.map(&:id).include?(e.listable_id) }.sum(&:score)
        assert_in_delta 1.0, score_for(result, one), 0.0001
        assert_in_delta 3.0, nine_total, 0.0001
      end

      # THE test -- the whole reason this class exists. The numbers are chosen so
      # it fails under BOTH rejected models, which is what makes it worth having:
      #
      #   position-1 share of a curated 10-item ballot = 10^2 / sum(1..10 squared)
      #                                                = 100 / 385 = 0.2597
      #
      #   sqrt mass (ours):  favourite = sqrt(10) * 0.2597 = 0.82   popular = 2.00  -> popular wins
      #   linear mass:       favourite = 10       * 0.2597 = 2.60   popular = 2.00  -> favourite wins
      #   legacy N-p+1:      favourite = 10                         popular = 2.00  -> favourite wins
      test "one large ballot cannot outvote several small ones" do
        favourite = books_books(:war_and_peace)
        popular = books_books(:got)

        build_ballot([favourite] + filler_books(9), manually_ordered: true)
        2.times { build_ballot([popular]) }

        result = tally

        assert_operator score_for(result, popular), :>, score_for(result, favourite),
          "two single-item ballots must outweigh one 10-item ballot's top pick"
      end

      test "an item below the voter floor is excluded" do
        lonely = books_books(:war_and_peace)
        shared = books_books(:got)
        build_ballot([lonely, shared])
        build_ballot([shared])

        result = UserFavoritesTally.call(user_list_class: ::Books::UserList, min_voters: 2)

        assert_nil score_for(result, lonely)
        refute_nil score_for(result, shared)
      end

      test "reports the voter count for each item" do
        shared = books_books(:got)
        2.times { build_ballot([shared]) }

        result = tally

        assert_equal 2, result.entries.first.voter_count
      end

      test "caps the result at max_items, keeping the highest scores" do
        books = filler_books(5)
        build_ballot(books, manually_ordered: true)

        result = tally(max_items: 2)

        assert_equal 2, result.entries.size
        assert_equal [books[0].id, books[1].id], result.entries.map(&:listable_id)
      end

      test "orders entries best first" do
        loved = books_books(:war_and_peace)
        liked = books_books(:got)
        3.times { build_ballot([loved]) }
        build_ballot([liked])

        result = tally

        assert_equal [loved.id, liked.id], result.entries.map(&:listable_id)
      end

      test "reports how many ballots were counted and ignores empty lists" do
        build_ballot([books_books(:war_and_peace)])
        build_ballot([books_books(:got)])
        # This user gets an empty favorites list from the after_create callback
        # and casts no ballot.
        ::User.create!(email: "empty@example.com")

        assert_equal 2, tally.ballot_count
      end

      test "ignores lists that are not favorites" do
        user = ::User.create!(email: "reader@example.com")
        read = ::Books::UserList.find_by!(user: user, list_type: :read)
        ::UserListItem.create!(user_list: read, listable: books_books(:war_and_peace), position: 1)

        result = tally

        assert_empty result.entries
        assert_equal 0, result.ballot_count
      end

      test "ignores other domains" do
        user = ::User.create!(email: "listener@example.com")
        albums = ::Music::Albums::UserList.find_by!(user: user, list_type: :favorites)
        ::UserListItem.create!(
          user_list: albums, listable: music_albums(:dark_side_of_the_moon), position: 1
        )

        result = tally

        assert_empty result.entries
        assert_equal 0, result.ballot_count
      end

      test "returns an empty tally when there are no ballots at all" do
        result = tally

        assert_equal [], result.entries
        assert_equal 0, result.ballot_count
      end
    end
  end
end
