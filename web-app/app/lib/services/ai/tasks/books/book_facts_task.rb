module Services
  module Ai
    module Tasks
      module Books
        # Facts and a description for one Books::Book in a single call. Both
        # depend on whether the model knows the book, and `recognized`
        # governs both. Applied by Services::Books::ApplyBookFacts.
        class BookFactsTask < EnrichmentTask
          IDENTIFIER_LABELS = {
            "books_work_isbn13" => "ISBN-13",
            "books_work_openlibrary_id" => "Open Library work key"
          }.freeze

          def initialize(parent:, mode: :knowledge, author_names: nil, provider: nil, model: nil)
            @author_names = Array(author_names).map(&:to_s).reject(&:blank?)
            super(parent: parent, mode: mode, provider: provider, model: model)
          end

          private

          def task_provider = :openai

          def author_names
            @author_names.presence || parent.authors.map(&:name)
          end

          def system_message
            <<~SYSTEM_MESSAGE
              You are a bibliographic researcher for a book catalog. You report facts about one book and write one short description of it.#{research_instruction}

              Facts. For every fact give a value and a confidence of high, medium or low. Use null (or an empty list) when you do not know; never guess. Set "recognized" to false if you do not know this specific book, and give an overall "confidence" for how well you know it. first_published_year is the year the work was first published in any language; set first_published_year_estimated when the year is approximate. original_language is the language the work was written in, as an ISO 639-1 code such as "en" or "ru". word_count is the approximate length of the full text. page_range is a typical page count for a standard edition, as "300" or "250-350". alternate_titles are other titles the same work has been published under, including translated titles. origin_countries are the nationalities of the work or its author, as English nationality adjectives such as "French" or "Japanese". book_type is one of fiction, nonfiction, poetry, religious. series_name and series_number are set only when the book is part of a series.

              Description rules.
              - Spoiler-free. Describe the premise, the setting, and the situation the book opens on. Never reveal twists, deaths, endings, or how the central question resolves. For nonfiction, describe the subject and the argument, not the conclusions.
              - One paragraph, 60 to 110 words, sentences of varied length. Do not name the title or the author; the page shows both.
              - No em dashes or double hyphens, no semicolons, no lists, no emoji, no quotation marks around titles.
              - No marketing or judgment: no acclaimed, bestselling, masterpiece, unforgettable, must-read, no awards, no sales figures.
              - No meta narration such as "This novel" or "Readers will". Open on the subject.
              - Plain words. Do not use: delve, tapestry, testament, poignant, seminal, groundbreaking, timeless, gripping, compelling, journey, navigate, resonate, profound, haunting, luminous, or "explores themes of".
              - No "not X but Y" constructions. No ornamental triads of adjectives.
              - Only what you are sure of. Say less rather than guess. If you do not know the book well enough to describe its premise, set description to null.
              - No citations, URLs, footnotes, or bracketed references inside any text field.

              Output only the JSON object described by the schema.
            SYSTEM_MESSAGE
          end

          def research_instruction
            return "" unless research?

            " Use web search to verify every fact before reporting it; prefer publisher, library and encyclopedia sources. Report what the sources say, not what you remember."
          end

          def user_prompt
            lines = ["Book: \"#{parent.title}\""]
            lines << "Subtitle: #{parent.subtitle}" if parent.subtitle.present?
            lines << "Author(s): #{author_names.join(", ")}" if author_names.any?
            lines << "First published (our record): #{parent.first_published_year}" if parent.first_published_year.present?
            identifier_lines.each { |line| lines << line }

            existing = parent.primary_description&.content
            if existing.present?
              lines << "Our current description, for context only; do not copy or extend it: #{existing}"
            end

            lines << ""
            lines << "Report the facts and write the description as JSON matching the schema."
            lines.join("\n")
          end

          def identifier_lines
            parent.identifiers
              .where(identifier_type: IDENTIFIER_LABELS.keys)
              .order(:identifier_type, :value)
              .limit(5)
              .pluck(:identifier_type, :value)
              .map { |type, value| "#{IDENTIFIER_LABELS.fetch(type)}: #{value}" }
          end

          def response_schema = ResponseSchema

          class ResponseSchema < OpenAI::BaseModel
            required :recognized, OpenAI::Boolean, doc: "false if you do not know this specific book"
            required :confidence, String, doc: "high, medium or low: how well you know this specific book"
            required :first_published_year, EnrichmentTask::IntegerFact
            required :first_published_year_estimated, OpenAI::Boolean, doc: "true when the year is approximate"
            required :original_language, EnrichmentTask::StringFact, doc: "ISO 639-1 code"
            required :word_count, EnrichmentTask::IntegerFact
            required :page_range, EnrichmentTask::StringFact, doc: "\"300\" or \"250-350\""
            required :subtitle, EnrichmentTask::StringFact
            required :alternate_titles, EnrichmentTask::StringListFact
            required :origin_countries, EnrichmentTask::StringListFact, doc: "English nationality adjectives"
            required :book_type, EnrichmentTask::StringFact, doc: "fiction, nonfiction, poetry or religious"
            required :series_name, EnrichmentTask::StringFact
            required :series_number, EnrichmentTask::IntegerFact
            required :description, EnrichmentTask::StringFact, doc: "One spoiler-free paragraph following the rules"
          end
        end
      end
    end
  end
end
