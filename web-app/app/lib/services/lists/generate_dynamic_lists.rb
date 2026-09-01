# frozen_string_literal: true

module Services
  module Lists
    # Writes a year-scoped ranking configuration's results into two generated
    # Lists -- a top-N and an overflow -- which then feed the domain's primary
    # configuration like any other list.
    #
    # Modelled on GenerateUserFavorites: the lists are found by
    # (type, auto_generated_kind, auto_generated_year) rather than by name, so a
    # rename cannot orphan one, and everything that affects their weight is
    # re-asserted on every run rather than set once by hand.
    class GenerateDynamicLists
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      # Global, so it works in all four domains. Applied in every primary
      # configuration today: books 50, games 40, albums 50, songs 50.
      HONORABLE_MENTION_PENALTY_NAME = "List: is a follow up/honorable mention to a different list"

      def self.call(ranking_configuration:, recalculate_primary: true)
        new(ranking_configuration: ranking_configuration,
          recalculate_primary: recalculate_primary).call
      end

      def initialize(ranking_configuration:, recalculate_primary: true)
        @config = ranking_configuration
        @recalculate_primary = recalculate_primary
      end

      def call
        failure = guard_failure
        return Result.new(success?: false, data: nil, errors: [failure]) if failure

        refresh_year_rankings

        top_list = nil
        overflow_list = nil

        ::List.transaction do
          top_list = write_list(:year_top, top_items)
          overflow_list = write_list(:year_honorable_mention, overflow_items)
          assert_fields(top_list)
          assert_fields(overflow_list)
          assert_penalties(top_list, overflow_list)
          ensure_ranked_list(top_list)
          ensure_ranked_list(overflow_list)
          @config.update!(
            primary_mapped_list_id: top_list.id,
            secondary_mapped_list_id: overflow_list.id
          )
        end

        recalculate_primary([top_list, overflow_list])

        Result.new(
          success?: true,
          data: {
            top_list: top_list,
            overflow_list: overflow_list,
            top_count: top_list.list_items.count,
            overflow_count: overflow_list.list_items.count,
            source_list_count: source_list_count
          },
          errors: []
        )
      rescue => error
        # full_message, not message: the Result carries only the message, and
        # GenerateDynamicListsJob raises one of its own, so Sidekiq records that
        # job's backtrace and the original is gone unless written down here.
        Rails.logger.error {
          "#{self.class.name} failed for configuration #{@config.id}: " \
            "#{error.full_message(highlight: false, order: :top)}"
        }
        Result.new(success?: false, data: nil, errors: [error.message])
      end

      private

      def guard_failure
        return "#{@config.name} has no year set" if @config.year.blank?
        unless @config.supports_year_rollups?
          return "#{@config.class.name} does not support year rollups"
        end
        if @config.default_primary?
          # The domain's primary configuration must stay the all-time ranking
          # that everything else feeds INTO. Generating against it would write
          # its own top-N output back into itself as a mapped list -- a
          # self-referential loop, and one whose output lists are undeletable
          # through admin (List#prevent_destroy_when_auto_generated).
          return "#{@config.name} is the primary configuration for #{@config.class.name} " \
            "and cannot be used to generate dynamic lists"
        end
        if @config.primary_mapped_list_cutoff_limit.blank?
          # Legacy dumped every ranked item into the primary list in this case,
          # which is never what anyone wants and is silent when it happens.
          return "#{@config.name} has no primary cutoff limit set"
        end
        nil
      end

      def top_items
        @config.ranked_items.order(:rank).limit(@config.primary_mapped_list_cutoff_limit)
      end

      def overflow_items
        scope = @config.ranked_items.order(:rank).offset(@config.primary_mapped_list_cutoff_limit)
        limit = @config.secondary_mapped_list_cutoff_limit
        limit.present? ? scope.limit(limit) : scope
      end

      def write_list(kind, ranked_items)
        list = find_or_create_list(kind)

        # delete_all / insert_all skip the ListItem callbacks and validations on
        # purpose: the guards there exist to stop humans editing generated rows,
        # and this class is the generator they defer to.
        list.list_items.delete_all
        rows = item_rows(list, ranked_items.to_a)
        ::ListItem.insert_all(rows) if rows.any?

        list
      end

      def find_or_create_list(kind)
        # STI scopes find_or_create_by! to the domain's own List subclass via the
        # type column, which is what makes the unique index on
        # (type, auto_generated_kind, auto_generated_year) mean what it says.
        @config.generated_list_class.find_or_create_by!(
          auto_generated_kind: kind,
          auto_generated_year: @config.year
        ) do |list|
          list.name = default_name(kind)
          list.description = default_description(kind)
          list.source = "The Greatest"
          # Active from birth. A configuration with no rankings yet produces an
          # EMPTY list, which contributes nothing whatever its status, so there
          # is nothing to protect against by starting it switched off.
          list.status = :active
        end
      end

      def default_name(kind)
        noun = @config.generated_list_noun
        if kind == :year_top
          "The #{@config.primary_mapped_list_cutoff_limit} Greatest #{noun} of #{@config.year}"
        else
          "The Greatest #{noun} of #{@config.year} - Honorable Mention"
        end
      end

      def default_description(kind)
        noun = @config.generated_list_noun.downcase
        if kind == :year_top
          "The best #{noun} of #{@config.year}, aggregated from every #{@config.year} " \
            "year-end list on the site."
        else
          "The best #{noun} of #{@config.year} beyond the top " \
            "#{@config.primary_mapped_list_cutoff_limit}, aggregated from every " \
            "#{@config.year} year-end list on the site."
        end
      end

      def item_rows(list, ranked_items)
        now = Time.current

        ranked_items.each_with_index.map do |ranked_item, index|
          {
            list_id: list.id,
            listable_id: ranked_item.item_id,
            listable_type: ranked_item.item_type,
            position: index + 1,
            verified: true,
            metadata: {source_rank: ranked_item.rank, source_score: ranked_item.score.to_f},
            created_at: now,
            updated_at: now
          }
        end
      end

      # Only active lists, matching ItemRankings::Calculator#prepare_lists, which
      # reads `status: :active` -- so deactivating a source self-corrects this on
      # the next run.
      def source_list_count
        @source_list_count ||= @config.ranked_lists.joins(:list).where(lists: {status: :active}).count
      end

      # Every field here changes the list's weight in the primary configuration.
      # Re-asserted on every run rather than set once by hand: the two lists this
      # replaces were hand-created a year apart and drifted, leaving 2023's and
      # 2024's overflow lists at weight 0 with 1,837 items between them.
      #
      # assign_attributes + save!(validate: false), not update!: this method owns
      # a fixed set of known-valid fields -- booleans, an integer, and the
      # configuration's year -- and asserts only those on every run. `update!`
      # validates the ENTIRE record, so a pre-existing invalid value on a column
      # this method never touches would still block it. It does on real data: 50
      # books lists carry a `url` with a leading space (" https://...") that
      # fails List's format validation, which is what surfaced this. Not
      # update_columns: that skips callbacks too and leaves updated_at
      # unchanged, and the admin show page renders `time_ago_in_words(list.
      # updated_at)` as the "generated N ago" indicator.
      def assert_fields(list)
        list.assign_attributes(
          num_years_covered: 1,
          number_of_voters: source_list_count,
          voter_count_unknown: false,
          voter_count_estimated: false,
          # The contributing publications are known, but not enumerated as named
          # voters. Costs 5% and is true.
          voter_names_unknown: true,
          high_quality_source: true,
          year_published: @config.year,
          category_specific: false,
          location_specific: false,
          creator_specific: false
        )
        list.save!(validate: false)
      end

      # Attaches tags only. The value of a tag is a per-configuration editorial
      # judgement, so this never creates a PenaltyApplication -- the same division
      # of labour GenerateUserFavorites settled on.
      def assert_penalties(top_list, overflow_list)
        one_year = one_year_penalty
        if one_year
          [top_list, overflow_list].each do |list|
            list.list_penalties.find_or_create_by!(penalty: one_year)
          end
        end

        honorable_mention = ::Global::Penalty.find_by(name: HONORABLE_MENTION_PENALTY_NAME)
        if honorable_mention
          overflow_list.list_penalties.find_or_create_by!(penalty: honorable_mention)
        else
          Rails.logger.warn {
            "#{self.class.name}: no Global::Penalty named " \
              "#{HONORABLE_MENTION_PENALTY_NAME.inspect}; list #{overflow_list.id} " \
              "will not be penalised as an honorable mention"
          }
        end
      end

      def one_year_penalty
        name = @config.one_year_penalty_name
        # Games, albums and songs penalise time scope with the dynamic
        # Global::Penalty "List: number of years covered", which fires off the
        # num_years_covered value assert_fields sets. No tag needed, and no warning.
        return nil if name.blank?

        penalty = ::Penalty.find_by(name: name)
        if penalty.nil?
          Rails.logger.warn {
            "#{self.class.name}: no Penalty named #{name.inspect}; the #{@config.year} " \
              "#{@config.generated_list_noun} rollups will not carry a one-year penalty"
          }
        end
        penalty
      end

      def ensure_ranked_list(list)
        main = @config.class.default_primary
        # A domain with no primary configuration is not set up for ranking yet.
        # Legitimate, and not this class's problem to fix.
        return if main.nil?

        ::RankedList.find_or_create_by!(list: list, ranking_configuration: main)
      end

      # Order is load-bearing. The generator reads ranked_items, so both the
      # weights and the rankings behind them must be current first, and
      # calculate_rankings runs synchronously for exactly that reason. Measured on
      # real data: 0.3-0.6s for a 43-60 list year configuration.
      def refresh_year_rankings
        ::Rankings::BulkWeightCalculator.new(@config).call

        result = @config.calculate_rankings
        return if result.success?

        raise "Ranking calculation failed for #{@config.name}: #{result.errors.join(", ")}"
      end

      # Only the two rows this run touched, not the primary's whole corpus -- for
      # books that is 623 lists, and the two generated lists are the only ones
      # whose weight inputs changed.
      #
      # The ranking recalculation is safe as perform_async because the lists are
      # fully written and re-weighted by the time it is enqueued. It is the same
      # job the Refresh Rankings button queues, so this adds no new load to a
      # queue that is already a throughput bottleneck.
      def recalculate_primary(lists)
        main = @config.class.default_primary
        return if main.nil?

        ranked_list_ids = ::RankedList.where(ranking_configuration: main, list: lists).pluck(:id)
        ::Rankings::BulkWeightCalculator.new(main).call_for_ids(ranked_list_ids) if ranked_list_ids.any?

        ::CalculateRankingsJob.perform_async(main.id) if @recalculate_primary
      end
    end
  end
end
