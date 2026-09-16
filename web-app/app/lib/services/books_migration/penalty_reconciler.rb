module Services
  module BooksMigration
    # Repairs a database migrated before PenaltyResolver learned the honorable-
    # mention and weird-criteria aliases and the year-span -> num_years_covered
    # mapping. Merges each Books duplicate into its global (list_penalties,
    # penalty_applications and the LegacyIdMap "Penalty" rows repointed; MAX wins a
    # collision), gives every configuration that applied a year-span static the
    # dynamic global at MAX(value) -- user-owned clones included -- and destroys the
    # now-unused Books penalties. Everything is located by NAME with user_id nil:
    # ids differ between environments. Idempotent: on a database migrated with the
    # new resolver nothing matches and every count is zero. One transaction.
    #
    # Ordered after NumYearsCoveredMigrator in data_migration:all so the per-list
    # values exist before the statics (and their list_penalties) vanish. Before a
    # static goes, any list it tags that still has no num_years_covered gets the
    # legacy bucket, so the step is safe to run alone -- NumYearsCoveredMigrator's
    # reviewed values overwrite it on the next list_penalties run.
    class PenaltyReconciler
      MERGES = {
        "List: honorable mention" => "List: is a follow up/honorable mention to a different list",
        "List: only covers books with a weird criteria(books to help you survive the digital age, etc)" => "List: only covers items with a weird criteria"
      }.freeze

      COUNTS = %i[
        list_penalties_repointed list_penalties_dropped
        applications_repointed applications_merged
        dynamic_applications_upserted year_list_penalties_dropped
        num_years_covered_backfilled
        id_map_repointed penalties_destroyed
      ].freeze

      def self.call
        new.call
      end

      def initialize
        @counts = COUNTS.index_with { 0 }
      end

      def call
        Penalty.transaction do
          MERGES.each do |source_name, target_name|
            source = books_penalty(source_name)
            next if source.nil?

            merge(source, Global::Penalty.find_by!(name: target_name, user_id: nil))
          end

          sources = PenaltyResolver::YEAR_SPAN_BUCKETS.keys.filter_map { |name| books_penalty(name) }
          convert_year_statics(sources) if sources.any?
        end
        {success: true, data: @counts}
      rescue => e
        {success: false, error: e.message, data: COUNTS.index_with { 0 }}
      end

      private

      def books_penalty(name)
        ::Books::Penalty.find_by(name: name, user_id: nil)
      end

      def merge(source, target)
        source.list_penalties.find_each do |list_penalty|
          if ListPenalty.exists?(list_id: list_penalty.list_id, penalty_id: target.id)
            list_penalty.destroy!
            @counts[:list_penalties_dropped] += 1
          else
            list_penalty.update!(penalty: target)
            @counts[:list_penalties_repointed] += 1
          end
        end

        source.penalty_applications.find_each do |application|
          existing = PenaltyApplication.find_by(penalty_id: target.id, ranking_configuration_id: application.ranking_configuration_id)
          if existing
            existing.update!(value: application.value) if application.value > existing.value
            application.destroy!
            @counts[:applications_merged] += 1
          else
            application.update!(penalty: target)
            @counts[:applications_repointed] += 1
          end
        end

        repoint_id_map([source.id], target.id)
        source.reload.destroy!
        @counts[:penalties_destroyed] += 1
      end

      def convert_year_statics(sources)
        target = Global::Penalty.find_by(dynamic_type: :num_years_covered, user_id: nil)
        raise "no num_years_covered Global::Penalty seeded; run db:seed first" if target.nil?

        source_ids = sources.map(&:id)
        PenaltyApplication.where(penalty_id: source_ids).group(:ranking_configuration_id).maximum(:value).each do |rc_id, max_value|
          application = PenaltyApplication.find_or_initialize_by(penalty_id: target.id, ranking_configuration_id: rc_id)
          application.value = [application.value || 0, max_value].max
          application.save!
          @counts[:dynamic_applications_upserted] += 1
        end

        repoint_id_map(source_ids, target.id)
        sources.each do |source|
          bucket = PenaltyResolver::YEAR_SPAN_BUCKETS.fetch(source.name)
          tagged = source.list_penalties.select(:list_id)
          @counts[:num_years_covered_backfilled] += ::Books::List.where(id: tagged, num_years_covered: nil).update_all(num_years_covered: bucket)
          @counts[:year_list_penalties_dropped] += source.list_penalties.count
          source.destroy! # dependent: :destroy takes its list_penalties and applications
          @counts[:penalties_destroyed] += 1
        end
      end

      def repoint_id_map(source_ids, target_id)
        @counts[:id_map_repointed] += LegacyIdMap.where(model: "Penalty", new_id: source_ids).update_all(new_id: target_id)
      end
    end
  end
end
