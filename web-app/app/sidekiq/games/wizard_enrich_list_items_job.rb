# frozen_string_literal: true

# Games-specific wizard enrich job.
# Inherits shared enrichment logic from BaseWizardEnrichListItemsJob.
#
class Games::WizardEnrichListItemsJob < ::BaseWizardEnrichListItemsJob
  private

  def list_class
    Games::List
  end

  def enricher_class
    Services::Lists::Games::ListItemEnricher
  end

  def enrichment_keys
    %w[game_id game_name opensearch_match opensearch_score
      igdb_id igdb_name igdb_developer_names igdb_match
      ai_match_confidence ai_match_reasoning]
  end

  def default_stats
    {opensearch_matches: 0, igdb_matches: 0, not_found: 0}
  end

  def update_stats(result)
    case result[:source]
    when :opensearch then @stats[:opensearch_matches] += 1
    when :igdb then @stats[:igdb_matches] += 1
    else @stats[:not_found] += 1
    end
  end
end
