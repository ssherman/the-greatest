module Services
  module Ai
    module Tasks
      module Books
        # The Goodreads re-import's double-check: the finder proposed some
        # candidate books for one Goodreads edition; which of them, if any, is
        # the work that edition belongs to (spec 4.2)? The answer is a number
        # into the prompt's list, mapped back to a book id here, so the model
        # never has to echo an id. Only the caller decides what confidence is
        # enough to apply a match.
        class SameWorkTask < BaseTask
          VALID_CONFIDENCE = %w[high medium low].freeze
          EDITION_TITLES = 3

          attr_reader :facts, :books

          def initialize(facts:, books:, parent: nil, provider: nil, model: nil)
            @facts = facts
            @books = books
            super(parent: parent, provider: provider, model: model)
          end

          private

          def validate_parent!
          end

          def task_provider = :openai

          def task_role = :fast

          def temperature = 1.0

          def chat_type = :analysis

          def system_message
            <<~SYSTEM
              You are checking a book catalog. A reader's Goodreads export names one edition of a book. Decide which of the numbered candidate books, if any, is the work that edition belongs to.
              - A translation of the work is the same work as the original. When several candidates are the same work, pick the English book over a non-English one.
              - A combo, omnibus or collection is only itself: it is not the same work as any single book it contains, and a single book is not the combo that contains it.
              - A different volume or part of a series, an adaptation (graphic novel, abridgement, film tie-in rewrite), a study guide, a summary or a box set is a different book, even when the title and author are nearly identical.
              - The first name under "Authors" is the credited author. Any further names may be co-authors, translators or illustrators; do not require a candidate to list them.
              - Judge by the title in full, the authors and the years. Do not decide by which candidate looks most popular.
              - A different year alone does not make a different work: a catalog year can be wrong, or be the year of an earlier form of the work (a serial, or a story later expanded into a novel under the same title).
              Give confidence: "high" when the title, author and work are unambiguous, "medium" when it is likely, "low" when you are guessing.
              Use a null candidate_number when no candidate is the same work.
            SYSTEM
          end

          def user_prompt
            lines = ["Goodreads edition:", "Title: #{facts.full_title}", "Authors: #{Array(facts.author_names).join("; ")}"]
            lines << "Original publication year: #{facts.year}" if facts.year.present?
            lines << "ISBN13: #{facts.isbn13}" if facts.isbn13.present?
            lines << "Series: #{facts.series_name}#{" ##{facts.series_number}" if facts.series_number.present?}" if facts.series_name.present?
            lines << ""
            lines << "Candidate books:"
            books.each_with_index { |book, index| lines << "#{index + 1}. #{describe(book)}" }
            lines << ""
            lines << "Answer with the number of the candidate that is the same work (or null), a confidence and a short reason."
            lines.join("\n")
          end

          def describe(book)
            title = [book.title, book.subtitle.presence].compact.join(": ")
            parts = [title, "by #{book.authors.map(&:name).join("; ").presence || "unknown"}"]
            parts << "first published #{book.first_published_year}" if book.first_published_year
            editions = book.editions.order(:id).limit(EDITION_TITLES).pluck(:title).compact_blank
            parts << "editions: #{editions.join("; ")}" if editions.any?
            parts.join(" | ")
          end

          def response_format = {type: "json_object"}

          def response_schema
            ResponseSchema
          end

          def process_and_persist(provider_response)
            data = provider_response[:parsed]
            confidence = data[:confidence]
            return failure("Unexpected confidence value: #{confidence.inspect}") unless VALID_CONFIDENCE.include?(confidence)

            number = data[:candidate_number]
            in_range = number.is_a?(Integer) && number.between?(1, books.size)
            return failure("Candidate number #{number.inspect} is outside 1..#{books.size}") unless number.nil? || in_range

            book_id = number && books[number - 1].id
            Services::Ai::Result.new(success: true, data: {book_id: book_id, confidence: confidence, reason: data[:reason].to_s}, ai_chat: chat)
          end

          def failure(message)
            Services::Ai::Result.new(success: false, error: message, ai_chat: chat)
          end

          class ResponseSchema < OpenAI::BaseModel
            required :candidate_number, Integer, nil?: true, doc: "Number of the candidate that is the same work, or null if none is"
            required :confidence, String, doc: "Exactly one of: high, medium, low"
            required :reason, String, doc: "One or two sentences"
          end
        end
      end
    end
  end
end
