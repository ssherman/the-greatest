# frozen_string_literal: true

# Music base class for wizard enrich jobs.
# Inherits shared enrichment logic from BaseWizardEnrichListItemsJob.
#
# Provides music-specific stats tracking (OpenSearch + MusicBrainz).
#
class Music::BaseWizardEnrichListItemsJob < ::BaseWizardEnrichListItemsJob
  private

  def default_stats
    {opensearch_matches: 0, musicbrainz_matches: 0, not_found: 0}
  end

  def update_stats(result)
    case result[:source]
    when :opensearch then @stats[:opensearch_matches] += 1
    when :musicbrainz then @stats[:musicbrainz_matches] += 1
    else @stats[:not_found] += 1
    end
  end
end
