# frozen_string_literal: true

module Services
  module Lists
    # Aggregates every user's favorites list for one domain into a ranked tally.
    #
    # Each user's favorites list is one ballot worth sqrt(N) points in total,
    # where N is its item count. That is the whole point of this class: the
    # legacy implementation scored each item as (N - position + 1), so a ballot's
    # total was N(N+1)/2 and 26 of 3,370 books voters controlled 63% of the
    # outcome. sqrt(N) gives an engaged user roughly 5x the per-capita influence
    # of a drive-by, and lands within 3 books of pure one-person-one-vote.
    #
    # A ballot spends its mass evenly, or by position when the user actually
    # arranged the list. Both branches sum to the same total, so curating changes
    # WHERE a user's influence lands and never how much they get -- which is what
    # keeps curation from becoming a gaming vector.
    #
    # Pure: reads user lists, writes nothing.
    class UserFavoritesTally
      Entry = Struct.new(:listable_id, :score, :voter_count, keyword_init: true)
      Tally = Struct.new(:entries, :ballot_count, keyword_init: true)

      def self.call(user_list_class:, **options)
        new(user_list_class: user_list_class, **options).call
      end

      def initialize(user_list_class:, **options)
        @user_list_class = user_list_class
        @config = Rails.application.config.x.user_favorites_list.merge(options)
      end

      def call
        scores = Hash.new(0.0)
        voters = Hash.new { |hash, key| hash[key] = Set.new }
        ballots = load_ballots

        ballots.each_value do |ballot|
          listable_ids = ballot[:listable_ids]
          mass = Math.sqrt(listable_ids.size)

          shares(ballot).each_with_index do |share, index|
            listable_id = listable_ids[index]
            scores[listable_id] += mass * share
            voters[listable_id] << ballot[:user_id]
          end
        end

        Tally.new(entries: rank(scores, voters), ballot_count: ballots.size)
      end

      private

      # One row per favorited item, ordered so each ballot arrives in position
      # order -- sorting in SQL beats re-sorting 31k rows in Ruby.
      #
      # list_type is looked up through the subclass because the enum integers are
      # declared per subclass; every one of them happens to use 0 for :favorites,
      # but reading it from the class keeps that from being load-bearing.
      def load_ballots
        favorites = @user_list_class.list_types.fetch("favorites")

        rows = ::UserListItem
          .joins(:user_list)
          .where(user_lists: {type: @user_list_class.name, list_type: favorites})
          .order(Arel.sql("user_list_items.user_list_id, user_list_items.position, user_list_items.id"))
          .pluck(
            Arel.sql("user_list_items.user_list_id"),
            Arel.sql("user_lists.user_id"),
            Arel.sql("user_lists.manually_ordered"),
            Arel.sql("user_list_items.listable_id")
          )

        rows.each_with_object({}) do |(user_list_id, user_id, manually_ordered, listable_id), ballots|
          ballot = ballots[user_list_id] ||= {
            user_id: user_id, manually_ordered: manually_ordered, listable_ids: []
          }
          ballot[:listable_ids] << listable_id
        end
      end

      # How one ballot's mass divides across its items, in position order. Both
      # branches sum to 1.0.
      def shares(ballot)
        size = ballot[:listable_ids].size
        return Array.new(size, 1.0 / size) unless ballot[:manually_ordered]

        exponent = @config[:decay_exponent].to_f
        weights = Array.new(size) { |index| (size - index)**exponent }
        total = weights.sum
        weights.map { |weight| weight / total }
      end

      # Voters are counted as a set of user ids rather than a ballot count:
      # UserList's one-default-per-type-per-user validation has no backing index,
      # so two concurrent first-visit requests can leave a user holding two
      # favorites lists. Without the set that user would vote twice.
      def rank(scores, voters)
        scores
          .reject { |listable_id, _score| voters[listable_id].size < @config[:min_voters] }
          .sort_by { |listable_id, score| [-score, listable_id] }
          .first(@config[:max_items])
          .map do |listable_id, score|
            Entry.new(listable_id: listable_id, score: score, voter_count: voters[listable_id].size)
          end
      end
    end
  end
end
