# frozen_string_literal: true

# Regenerates one year configuration's two rollup lists, in the order that makes
# the result correct. Queued by Actions::Admin::GenerateDynamicLists and by the
# dynamic_lists rake tasks.
#
# Deliberately has no cron entry. Regeneration reshuffles the primary
# configuration, and that stays a deliberate act.
class GenerateDynamicListsJob
  include Sidekiq::Job

  def perform(ranking_configuration_id, recalculate_primary = true)
    ranking_configuration = RankingConfiguration.find(ranking_configuration_id)

    result = Services::Lists::GenerateDynamicLists.call(
      ranking_configuration: ranking_configuration,
      recalculate_primary: recalculate_primary
    )

    unless result.success?
      raise "Dynamic list generation failed for configuration " \
        "#{ranking_configuration_id}: #{result.errors.join(", ")}"
    end

    Rails.logger.info {
      "Generated dynamic lists for #{ranking_configuration.name}: " \
        "#{result.data[:top_count]} top items, #{result.data[:overflow_count]} overflow items, " \
        "from #{result.data[:source_list_count]} source lists"
    }

    result
  end
end
