module Services
  module Ai
    module Tasks
      module Books
        # One structured call for one book of the Goodreads rebuild: the export
        # names these authors for the book; which of the book's current authors
        # is each of them? "Kurt Vonnegut" and "Kurt Vonnegut Jr." are one
        # person, "Roy Heath" and "Chip Heath" are not, and a name alone proves
        # neither, so each current author is described by AuthorProfile#line
        # plus a few of their other books. Only a "high" answer counts as the
        # same person in code (MatchAuthors).
        class MatchExportAuthorsTask < BaseTask
          VALID_CONFIDENCE = %w[high medium low].freeze
          OTHER_BOOKS = 5

          attr_reader :title, :year, :export_names, :authors, :book_id

          def initialize(title:, year:, export_names:, authors:, book_id: nil, parent: nil, provider: nil, model: nil)
            @title = title
            @year = year
            @export_names = export_names
            @authors = authors
            @book_id = book_id
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
              You are checking the authors of one book in a catalog. A reading-site export names the authors of the book;
              the catalog currently credits the numbered authors. For each exported name, say which current author is the same person, or none.
              - Judge by the person's books and dates. Matching names alone prove nothing.
              - A middle initial, "Jr." or a fuller given name can be the same person ("Daniel Dennett" and "Daniel C. Dennett").
              - A different given name is a different person unless their books connect them ("Roy Heath" is not "Chip Heath").
              - A current author whose other books are clearly by someone else is NOT the same person, even if the name looks close.
              - A surname alone is never enough.
              For each name give confidence: "high" when the books or dates make it unambiguous, "medium" when it is likely, "low" when you are guessing.
              Use a null author_number when no current author is that person.
            SYSTEM
          end

          def user_prompt
            lines = ["Book: #{title}#{" (#{year})" if year.present?}", "", "Names in the export:"]
            export_names.each { |name| lines << "- #{name}" }
            lines << ""
            lines << "Current authors of the book:"
            authors.each_with_index { |author, index| lines << "#{index + 1}. #{describe(author)}" }
            lines << ""
            lines << "Answer with one match per exported name (author_number, or null, and a confidence) and reasoning."
            lines.join("\n")
          end

          def describe(author)
            line = ::Services::Books::Authors::AuthorProfile.new(author).line
            others = author.books.where.not(id: book_id).order(:id).limit(OTHER_BOOKS).pluck(:title)
            others.any? ? "#{line} | other books: #{others.join("; ")}" : line
          end

          def response_format = {type: "json_object"}

          def response_schema
            ResponseSchema
          end

          def process_and_persist(provider_response)
            data = provider_response[:parsed]
            matches = Array(data[:matches])
            invalid = matches.map { |match| value(match, :confidence) }.reject { |confidence| VALID_CONFIDENCE.include?(confidence) }
            return failure("Unexpected confidence value: #{invalid.first.inspect}") if invalid.any?

            Services::Ai::Result.new(success: true, data: {matches: clean(matches), reasoning: data[:reasoning].to_s}, ai_chat: chat)
          end

          # Only the names we asked about; a number outside the list is no answer.
          def clean(matches)
            matches.filter_map do |match|
              name = value(match, :export_name)
              next unless export_names.include?(name)

              number = value(match, :author_number)
              number = nil unless number.is_a?(Integer) && number.between?(1, authors.size)
              {export_name: name, author_number: number, confidence: value(match, :confidence)}
            end
          end

          def value(match, key)
            match.respond_to?(key) ? match.public_send(key) : (match[key] || match[key.to_s])
          end

          def failure(message)
            Services::Ai::Result.new(success: false, error: message, ai_chat: chat)
          end

          class Match < OpenAI::BaseModel
            required :export_name, String, doc: "The exported name, exactly as given"
            required :author_number, Integer, nil?: true, doc: "Number of the current author who is the same person, or null"
            required :confidence, String, doc: "high, medium or low"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :matches, OpenAI::ArrayOf[Match], doc: "One entry per exported name"
            required :reasoning, String, doc: "One or two sentences"
          end
        end
      end
    end
  end
end
