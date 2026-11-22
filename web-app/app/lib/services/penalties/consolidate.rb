# frozen_string_literal: true

module Services
  module Penalties
    # Folds the books geography penalties into the `location_specific` flag plus
    # one add-on (46), merges 32 into 44, and deletes 21 and 27. See
    # docs/launch-todo.md section 19. One transaction; a dry run runs the same
    # code and rolls it back, so the report is exactly what an apply would do.
    #
    # The id -> name map is a constant, not an injectable, because the ids ARE the
    # decision (production ids); tests create penalty rows with those explicit
    # ids. Like LoadGuidance, every id is checked against its expected name (old
    # or already-new) and a mismatch refuses the whole run before any write.
    #
    # Idempotent: a deleted id is simply absent, a renamed penalty (name no longer
    # the old one) is left alone so a later admin edit to its text survives, and
    # the new name, a flagged list needs no write. Configuration values are only
    # recomputed while there is something to derive them from (a legacy geography
    # application, a missing #15 application, or the not-yet-renamed #46), so a
    # re-run never overwrites a value edited after the first apply.
    class Consolidate
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      LOCATION_FLAG = 15
      MIX = 44
      MIX_OLD = 32
      SMALL_AREA = 46
      COUNTRY = 37
      LEGACY_GEOGRAPHY = [31, 36, 37, 38, 39, 42].freeze
      GEOGRAPHY = (LEGACY_GEOGRAPHY + [SMALL_AREA]).freeze
      MOVE_TO_SMALL_AREA = [39, 42].freeze
      DELETED = [21, 27, 31, 32, 36, 37, 38, 39, 42].freeze

      LOCATION_BASE_VALUE = 20
      SMALL_AREA_VALUE = 15

      NAMES = {
        15 => ["List: only covers 1 specific location"],
        21 => ["Voters: specific voter details are lacking"],
        27 => ["List: only covers genre fiction(multiple genres)"],
        31 => ["List: only partially covers 1 specific country"],
        32 => ["Voters: half the voters are not critics, authors, or experts"],
        36 => ["List: only covers 1 specific continent"],
        37 => ["List: only covers 1 specific country"],
        38 => ["List: only covers 1 specific large geographical region (Asia, Latin America, etc)"],
        39 => ["List: only covers 1 specific state of a country"],
        42 => ["List: only covers 1 specific city"],
        44 => ["Voters: not critics, authors, or experts, but the books on the list were curated by critics/experts",
          "Voters: a mix of experts and the public"],
        46 => ["List: only covers 1 specific small geographical region (Southern United States, etc)",
          "List: only covers an area smaller than a country (a state, city or region)"]
      }.freeze

      RENAMES = {
        44 => {name: "Voters: a mix of experts and the public",
               category: :voter_expertise,
               description: "Experts and general readers both shaped the list: a panel that mixed the two, or a public vote from a shortlist experts chose."},
        46 => {name: "List: only covers an area smaller than a country (a state, city or region)",
               category: :list_subject_scope,
               description: "Restricted to an area smaller than a country, such as a state, a city or the American South, so the pool to pick from is very small."}
      }.freeze

      def self.call(dry_run:)
        new(dry_run: dry_run).call
      end

      def initialize(dry_run:)
        @dry_run = dry_run
      end

      def call
        @penalties = ::Penalty.where(id: NAMES.keys).index_by(&:id)
        errors = refusals
        return Result.new(success?: false, data: {}, errors: errors) if errors.any?

        @data = {lists_flagged: [], attachments_moved: [], applications_set: [], penalties_deleted: [], penalties_renamed: []}
        ::ActiveRecord::Base.transaction do
          # Counted up front: moving 32 to 44 empties 32 before it is deleted.
          @list_counts = ::ListPenalty.where(penalty_id: DELETED).group(:penalty_id).count
          flag_lists
          move_attachments
          set_applications
          delete_penalties
          rename_penalties
          raise ::ActiveRecord::Rollback if @dry_run
        end
        @data[:nothing_to_do] = @data.values.all?(&:empty?)

        Result.new(success?: true, data: @data, errors: [])
      end

      private

      def refusals
        errors = @penalties.filter_map do |id, penalty|
          next if NAMES[id].include?(penalty.name)
          "Penalty #{id} is named #{penalty.name.inspect}, expected #{NAMES[id].map(&:inspect).join(" or ")}. This is not the database the consolidation was written for."
        end
        [LOCATION_FLAG, MIX, SMALL_AREA].each do |id|
          errors << "Penalty #{id} does not exist; the consolidation needs it." unless @penalties[id]
        end
        errors
      end

      def present_ids(ids)
        ids.select { |id| @penalties[id] }
      end

      def attachments(ids)
        ::ListPenalty.where(penalty_id: ids)
      end

      def flag_lists
        list_ids = attachments(present_ids(GEOGRAPHY)).pluck(:list_id)
        unflagged = ::Books::List.where(id: list_ids).where("location_specific IS NOT TRUE").order(:id).pluck(:id, :name)
        return if unflagged.empty?

        ::Books::List.where(id: unflagged.map(&:first)).update_all(location_specific: true, updated_at: Time.current)
        @data[:lists_flagged].concat(unflagged.map { |id, name| {id: id, name: name} })
      end

      def move_attachments
        move(MOVE_TO_SMALL_AREA, SMALL_AREA)
        move([MIX_OLD], MIX)
      end

      # Re-points a list's attachment at the target; a list that already has the
      # target keeps its own row and the old attachment goes with the penalty.
      def move(from_ids, to_id)
        attachments(present_ids(from_ids)).order(:id).each do |attachment|
          next if ::ListPenalty.exists?(list_id: attachment.list_id, penalty_id: to_id)

          attachment.update!(penalty_id: to_id)
          @data[:attachments_moved] << {list_id: attachment.list_id, list: attachment.list.name, from: attachment.penalty_id_before_last_save, to: to_id}
        end
      end

      def set_applications
        pre_rename = @penalties[SMALL_AREA].name == NAMES[SMALL_AREA].first
        configs = ::Books::RankingConfiguration.order(:id).pluck(:id)
        apps = ::PenaltyApplication.where(ranking_configuration_id: configs).group_by(&:ranking_configuration_id)

        configs.each do |config_id|
          by_penalty = (apps[config_id] || []).index_by(&:penalty_id)
          legacy = LEGACY_GEOGRAPHY.select { |id| by_penalty[id] }

          if legacy.any? || by_penalty[LOCATION_FLAG].nil?
            target = by_penalty[COUNTRY]&.value || LOCATION_BASE_VALUE
            set_value(config_id, LOCATION_FLAG, target, by_penalty[LOCATION_FLAG])
          end

          if legacy.any? || (pre_rename && by_penalty[SMALL_AREA])
            set_value(config_id, SMALL_AREA, SMALL_AREA_VALUE, by_penalty[SMALL_AREA])
          end
        end
      end

      def set_value(config_id, penalty_id, target, existing)
        return if existing && existing.value == target

        if existing
          existing.update!(value: target)
        else
          ::PenaltyApplication.create!(ranking_configuration_id: config_id, penalty_id: penalty_id, value: target)
        end
        @data[:applications_set] << {ranking_configuration_id: config_id, penalty_id: penalty_id, from: existing&.value_before_last_save, to: target}
      end

      def delete_penalties
        DELETED.each do |id|
          penalty = @penalties[id]
          next unless penalty

          @data[:penalties_deleted] << {id: id, name: penalty.name, lists: @list_counts.fetch(id, 0), applications: penalty.penalty_applications.count}
          penalty.destroy!
        end
      end

      def rename_penalties
        RENAMES.each do |id, attrs|
          penalty = @penalties[id]
          next if penalty.name != NAMES[id].first

          @data[:penalties_renamed] << {id: id, from: penalty.name, to: attrs[:name]}
          penalty.update!(attrs)
        end
      end
    end
  end
end
