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

        top_list = nil
        overflow_list = nil

        ::List.transaction do
          top_list = write_list(:year_top, top_items)
          overflow_list = write_list(:year_honorable_mention, overflow_items)
          @config.update!(
            primary_mapped_list_id: top_list.id,
            secondary_mapped_list_id: overflow_list.id
          )
        end

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
        @config.ranked_lists.joins(:list).where(lists: {status: :active}).count
      end
    end
  end
end
