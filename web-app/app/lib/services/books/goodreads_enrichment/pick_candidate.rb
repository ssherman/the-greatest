# frozen_string_literal: true

module Services
  module Books
    module GoodreadsEnrichment
      # Asks the cheap model to pick the search row that is this book, or none
      # (spec §4.3). Only a "high" confidence pick counts: a wrong attachment
      # writes another book's facts onto ours, a miss only costs a retry.
      class PickCandidate
        TOP = 5
        GUIDANCE = "These are NOT the same book: an omnibus or box set, a study guide or summary, " \
          "a single volume of a multi-volume work, an abridged edition, or an adaptation such as a " \
          "graphic novel or screenplay. Select 0 when only such candidates remain."

        def self.call(book:, rows:)
          new(book: book, rows: rows).call
        end

        def initialize(book:, rows:)
          @book = book
          @rows = rows.first(TOP)
        end

        def call
          return nil if @rows.empty?

          result = ::Services::Ai::Tasks::Matching::SelectCandidateTask.new(
            entity_noun: "book", query_line: query_line, candidate_lines: @rows.map { |row| candidate_line(row) },
            parent: @book, guidance: GUIDANCE
          ).call
          unless result.success?
            Rails.logger.warn("#{self.class.name}: book #{@book.id}: #{result.error}")
            return nil
          end

          index = result.data[:selected_index]
          return nil unless index.is_a?(Integer) && index.between?(1, @rows.size) && result.data[:confidence] == "high"

          @rows[index - 1]
        end

        private

        def query_line
          year = @book.first_published_year
          "#{@book.title} by #{@book.authors.map(&:name).join(", ")}#{", first published #{year}" if year}"
        end

        def candidate_line(row)
          "#{row.title} by #{row.author_names.join(", ")}, year #{row.year || "unknown"}, " \
            "#{row.ratings_count.to_i} ratings, #{row.editions_count.to_i} editions"
        end
      end
    end
  end
end
