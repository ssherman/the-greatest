# frozen_string_literal: true

module Services
  module Books
    module GenrePlan
      # The reviewed genre cleanup plan, config/books/genre_plan.yml
      # (docs/superpowers/specs/2026-10-17-books-genre-cleanup-design.md §4).
      # AI drafts it in development, the owner edits it, production applies it
      # unchanged.
      class PlanFile
        DEFAULT_PATH = Rails.root.join("config", "books", "genre_plan.yml")
        VERSION = 1
        AUDIENCES = {
          "Children's" => "Written for readers up to about age 8.",
          "Middle Grade" => "Written for readers about 8 to 12.",
          "Young Adult" => "Written for readers about 12 to 18."
        }.freeze
        HEADER = "# Books genre cleanup plan (docs/superpowers/specs/2026-10-17-books-genre-cleanup-design.md).\n" \
                 "# Drafted by `bin/rails categories:genres:draft` and `map`; reviewed and edited by hand.\n"

        attr_reader :data, :path

        def self.load(path = DEFAULT_PATH)
          path = Pathname(path)
          new(path.exist? ? YAML.safe_load_file(path) : {}, path: path, exists: path.exist?)
        end

        def initialize(data, path: DEFAULT_PATH, exists: true)
          data ||= {}
          @data = data.merge("decisions" => (data["decisions"] || {}).transform_keys(&:to_i))
          @path = Pathname(path)
          @exists = exists
        end

        def exists? = @exists

        def run = data["run"].to_s

        def genres = Array(data["genres"])

        def genre_names = genres.map { |g| g["name"] }

        def audiences = Array(data["audiences"])

        def audience_names = audiences.map { |a| a["name"] }

        def decisions = data["decisions"]

        def write(path = @path)
          path = Pathname(path)
          path.dirname.mkpath
          ordered = {"version" => VERSION, "run" => run, "genres" => genres, "audiences" => audiences,
                     "decisions" => decisions.sort.to_h}
          path.write(HEADER + ordered.to_yaml)
          @exists = true
        end
      end
    end
  end
end
