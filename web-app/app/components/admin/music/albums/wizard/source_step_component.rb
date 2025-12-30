# frozen_string_literal: true

# Album-specific source step component.
# Inherits shared logic from BaseSourceStepComponent.
#
class Admin::Music::Albums::Wizard::SourceStepComponent < Admin::Music::Wizard::BaseSourceStepComponent
  # MusicBrainz Series import is not yet implemented for albums.
  # Unlike songs, there is no DataImporters::Music::Lists::ImportAlbumsFromMusicbrainzSeries.
  # Disable until a proper bulk series importer is implemented.
  def musicbrainz_available?
    false
  end

  def musicbrainz_unavailable_message
    "Not available - series import is not yet implemented for albums"
  end

  private

  def advance_step_path
    helpers.advance_step_admin_albums_list_wizard_path(list_id: list.id, step: "source")
  end

  def entity_name
    "album"
  end
end
