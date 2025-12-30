# frozen_string_literal: true

# Album-specific wizard parse job.
# Inherits shared parsing logic from BaseWizardParseListJob.
#
class Music::Albums::WizardParseListJob < Music::BaseWizardParseListJob
  private

  def list_class
    Music::Albums::List
  end

  def parser_task_class
    Services::Ai::Tasks::Lists::Music::AlbumsRawParserTask
  end

  def data_key
    :albums
  end

  def listable_type
    "Music::Album"
  end

  def build_metadata(item)
    {
      "rank" => item[:rank],
      "title" => item[:title],
      "artists" => item[:artists],
      "release_year" => item[:release_year]
    }
  end
end
