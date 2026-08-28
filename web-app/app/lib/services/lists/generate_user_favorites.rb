# frozen_string_literal: true

module Services
  module Lists
    # Persists a domain's UserFavoritesTally into its generated List.
    #
    # The list is found by (type, auto_generated_kind), never by name -- the
    # legacy implementation looked its lists up by name and could not survive a
    # rename.
    #
    # Items are written with delete_all / insert_all, which skip the ListItem
    # callbacks and validations. That is deliberate on both counts: the guard
    # added in ListItem exists to stop humans editing generated rows, and it
    # needs no escape hatch for this class.
    class GenerateUserFavorites
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      # The global penalty every users'-vote list carries. Looked up by name
      # rather than id so it survives a reseed: the id differs per environment.
      #
      # Load-bearing, not cosmetic. Without it the list computes at roughly
      # weight 100, which would make a list of user favorites one of the
      # heaviest in a corpus of critic-authored lists. With it -- and with the
      # matching PenaltyApplication, an editorial value this class deliberately
      # does NOT create -- it lands near 40.
      STANDARD_PENALTY_NAME = "Voters: not critics, authors, or experts"

      def self.call(user_list_class:, **options)
        new(user_list_class: user_list_class, **options).call
      end

      def initialize(user_list_class:, **options)
        @user_list_class = user_list_class
        @options = options
      end

      def call
        tally = UserFavoritesTally.call(user_list_class: @user_list_class, **@options)
        list = find_or_create_list

        ::List.transaction do
          list.list_items.delete_all
          ::ListItem.insert_all(item_rows(list, tally.entries)) if tally.entries.any?
          list.update!(number_of_voters: tally.ballot_count)
        end

        Result.new(
          success?: true,
          data: {list: list, item_count: tally.entries.size, ballot_count: tally.ballot_count},
          errors: []
        )
      rescue => error
        # full_message, not just error.message: the Result carries only the
        # message, and GenerateUserFavoritesListsJob re-raises a RuntimeError of
        # its own -- so Sidekiq records that job's backtrace and the original is
        # gone unless it is written down here.
        Rails.logger.error {
          "#{self.class.name} failed for #{@user_list_class}: " \
            "#{error.full_message(highlight: false, order: :top)}"
        }
        Result.new(success?: false, data: nil, errors: [error.message])
      end

      private

      def find_or_create_list
        klass = @user_list_class.generated_list_class

        # STI scopes this to the domain's own List subclass via the type column,
        # so the partial unique index on (type, auto_generated_kind) is what makes
        # "one generated list per domain" true.
        list = klass.find_or_create_by!(auto_generated_kind: :user_favorites) do |new_list|
          new_list.name = @user_list_class.generated_list_name
          new_list.description = @user_list_class.generated_list_description
          new_list.source = "The Greatest Users"
          # Active from birth, in every domain. A domain with no favorites data
          # produces an EMPTY list, which contributes nothing to rankings whatever
          # its status -- so there is nothing to protect against by starting it
          # switched off, and requiring a manual flip meant re-flipping after
          # every environment rebuild.
          new_list.status = :active
        end

        # Wiring runs on CREATE ONLY, never on the nightly rerun. An admin who
        # deliberately detaches this list from a configuration, or drops its
        # penalty, must not have that undone every night.
        wire_new_list(list) if list.previously_new_record?

        list
      end

      # Everything a hand-created list would be given in the admin UI, so a fresh
      # database is correct with no follow-up commands. Each step degrades to a
      # no-op rather than raising: a half-wired list that exists beats no list at
      # all, and both gaps are legitimate states.
      def wire_new_list(list)
        attach_standard_penalty(list)
        join_primary_ranking_configuration(list)
      end

      def attach_standard_penalty(list)
        penalty = ::Global::Penalty.find_by(name: STANDARD_PENALTY_NAME)

        if penalty.nil?
          Rails.logger.warn {
            "#{self.class.name}: no Global::Penalty named #{STANDARD_PENALTY_NAME.inspect}; " \
              "created #{list.class} #{list.id} without it, so it will weigh ~100 instead of ~40 " \
              "until the penalty is attached by hand"
          }
          return
        end

        list.list_penalties.create!(penalty: penalty)
      end

      def join_primary_ranking_configuration(list)
        # Runs AFTER the penalty is attached, so the weight calculation below sees it.
        ranking_configuration = @user_list_class.ranking_configuration_class&.default_primary
        # A domain with no primary configuration is not yet set up for ranking.
        # Legitimate, and not this class's problem to fix.
        return if ranking_configuration.nil?

        ::RankedList.create!(list: list, ranking_configuration: ranking_configuration)

        # A new RankedList has no weight until a weight calculation runs, and this
        # is how one is normally triggered (Actions::Admin::BulkCalculateWeights and
        # the record mergers both do exactly this). Create-only, so the nightly run
        # never touches a queue that is already a throughput bottleneck.
        BulkCalculateWeightsJob.perform_async(ranking_configuration.id)
      end

      def item_rows(list, entries)
        now = Time.current
        listable_type = @user_list_class.listable_class.name

        entries.each_with_index.map do |entry, index|
          {
            list_id: list.id,
            listable_id: entry.listable_id,
            listable_type: listable_type,
            position: index + 1,
            verified: true,
            metadata: {voter_count: entry.voter_count, score: entry.score.round(6)},
            created_at: now,
            updated_at: now
          }
        end
      end
    end
  end
end
