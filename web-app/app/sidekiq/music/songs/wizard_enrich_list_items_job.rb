# frozen_string_literal: true

# Song-specific wizard enrich job.
# Inherits shared enrichment logic from BaseWizardEnrichListItemsJob.
#
class Music::Songs::WizardEnrichListItemsJob < Music::BaseWizardEnrichListItemsJob
  private

  def list_class
    Music::Songs::List
  end

  def enricher_class
    Services::Lists::Music::Songs::ListItemEnricher
  end

  def enrichment_keys
    %w[song_id song_name opensearch_match opensearch_score opensearch_artist_names
      mb_recording_id mb_recording_name mb_artist_ids mb_artist_names musicbrainz_match]
  end
end
