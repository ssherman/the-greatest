# frozen_string_literal: true

# Games-specific wizard parse job.
# Inherits shared parsing logic from BaseWizardParseListJob.
#
class Games::WizardParseListJob < ::BaseWizardParseListJob
  private

  def list_class
    Games::List
  end

  def parser_task_class
    Services::Ai::Tasks::Lists::Games::RawParserTask
  end

  def data_key
    :games
  end

  def listable_type
    "Games::Game"
  end

  def build_metadata(item)
    {
      "rank" => item[:rank],
      "title" => item[:title],
      "developers" => item[:developers],
      "release_year" => item[:release_year]
    }
  end
end
