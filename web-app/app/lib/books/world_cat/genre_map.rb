# frozen_string_literal: true

module Books
  module WorldCat
    # The reviewed mapping table, config/worldcat/genre_map.yml. Read fresh on
    # every load: the owner edits the file between backfill runs.
    class GenreMap
      DEFAULT_PATH = Rails.root.join("config", "worldcat", "genre_map.yml")

      def self.load(path = DEFAULT_PATH)
        path = Pathname(path)
        new(path.exist? ? YAML.safe_load_file(path) : {})
      end

      def initialize(data)
        @genres = Array(data["genres"])
        @terms = data["terms"] || {}
      end

      attr_reader :genres

      def size = @terms.size

      def verdict(term) = @terms[term]

      def genre_for(term)
        entry = @terms[term]
        entry["genre"] if entry && entry["verdict"] == "genre"
      end

      def subject_for(term)
        entry = @terms[term]
        entry["subject"] if entry && entry["verdict"] == "subject"
      end

      def terms_by_genre
        @terms.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(term, entry), out|
          out[entry["genre"]] << term if entry["verdict"] == "genre"
        end.transform_values(&:sort).sort.to_h
      end

      def each_term(&) = @terms.each(&)
    end
  end
end
