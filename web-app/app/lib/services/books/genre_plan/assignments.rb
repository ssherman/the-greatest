# frozen_string_literal: true

require "csv"

module Services
  module Books
    module GenrePlan
      # Per-book answers for split genres, config/books/genre_split_assignments.csv
      # (spec §4, "Combined genres"). One row per book per split genre; targets
      # are names joined with "|", or "unknown" when the model did not know the book.
      class Assignments
        DEFAULT_PATH = Rails.root.join("config", "books", "genre_split_assignments.csv")
        HEADERS = %w[book_id category_id targets].freeze
        UNKNOWN = "unknown"

        def self.load(path = DEFAULT_PATH)
          path = Pathname(path)
          rows = path.exist? ? CSV.read(path, headers: true).map { |r| [r["book_id"].to_i, r["category_id"].to_i, parse(r["targets"])] } : []
          new(rows, path: path)
        end

        def self.parse(value) = (value == UNKNOWN) ? :unknown : value.to_s.split("|")

        def initialize(rows, path: DEFAULT_PATH)
          @rows = rows
          @answered = rows.map { |book_id, category_id, _| [category_id, book_id] }.to_set
          @path = Pathname(path)
        end

        def for(category_id)
          @rows.each_with_object({}) { |(book_id, cat, targets), out| out[book_id] = targets if cat == category_id }
        end

        def answered?(category_id, book_id) = @answered.include?([category_id, book_id])

        def category_ids = @rows.map { |_, c, _| c }.uniq

        def each(&) = @rows.each(&)

        def append(rows, path = @path)
          path = Pathname(path)
          path.dirname.mkpath
          new_file = !path.exist?
          CSV.open(path, "a") do |csv|
            csv << HEADERS if new_file
            rows.each { |book_id, category_id, targets| csv << [book_id, category_id, (targets == :unknown) ? UNKNOWN : targets.join("|")] }
          end
          @rows.concat(rows)
          rows.each { |book_id, category_id, _| @answered << [category_id, book_id] }
        end
      end
    end
  end
end
