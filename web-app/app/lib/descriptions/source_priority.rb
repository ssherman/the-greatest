module Descriptions
  module SourcePriority
    ORDER = %w[
      manual
      ai_generated
      goodreads
      wikipedia
      openlibrary
      publisher
      musicbrainz
      igdb
      other
    ].freeze
  end
end
