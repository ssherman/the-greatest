# frozen_string_literal: true

# Album-specific wizard enrich job.
# Inherits shared enrichment logic from BaseWizardEnrichListItemsJob.
#
class Music::Albums::WizardEnrichListItemsJob < Music::BaseWizardEnrichListItemsJob
  private

  def list_class
    Music::Albums::List
  end

  def enricher_class
    Services::Lists::Music::Albums::ListItemEnricher
  end

  def enrichment_keys
    %w[album_id album_name opensearch_match opensearch_score opensearch_artist_names
      mb_release_group_id mb_release_group_name mb_artist_ids mb_artist_names musicbrainz_match]
  end
end
