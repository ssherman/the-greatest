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

      Target = Struct.new(:kind, :name, :weak, keyword_init: true)

      def initialize(data)
        @genres = Array(data["genres"])
        @audiences = Array(data["audiences"])
        @terms = data["terms"] || {}
      end

      attr_reader :genres, :audiences

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

      # Every genre or audience a term supports, primary first
      # (docs/superpowers/specs/2026-10-17-books-genre-cleanup-design.md §7).
      def targets_for(term)
        entry = @terms[term]
        return [] unless entry

        primary = case entry["verdict"]
        when "genre" then Target.new(kind: :genre, name: entry["genre"], weak: false)
        when "audience" then Target.new(kind: :audience, name: entry["audience"], weak: entry["weak"] == true)
        end
        return [] unless primary

        [primary] + Array(entry["also"]).map { |name| Target.new(kind: @audiences.include?(name) ? :audience : :genre, name: name, weak: false) }
      end

      def terms_by_audience
        @terms.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(term, entry), out|
          out[entry["audience"]] << term if entry["verdict"] == "audience"
        end.transform_values(&:sort).sort.to_h
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
