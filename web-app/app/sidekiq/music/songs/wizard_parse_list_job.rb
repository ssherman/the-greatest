# frozen_string_literal: true

# Song-specific wizard parse job.
# Inherits shared parsing logic from BaseWizardParseListJob.
#
class Music::Songs::WizardParseListJob < Music::BaseWizardParseListJob
  private

  def list_class
    Music::Songs::List
  end

  def parser_task_class
    Services::Ai::Tasks::Lists::Music::SongsRawParserTask
  end

  def data_key
    :songs
  end

  def listable_type
    "Music::Song"
  end

  def build_metadata(item)
    {
      "rank" => item[:rank],
      "title" => item[:title],
      "artists" => item[:artists],
      "album" => item[:album],
      "release_year" => item[:release_year]
    }
  end
end
