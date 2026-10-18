# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Books
        # For each book on a combined genre, which of its halves fit
        # (spec §4, "Combined genres"; §5 step 4).
        class GenreSplitCheckTask < BaseTask
          Book = Struct.new(:key, :title, :authors, :year, :description, :genres, keyword_init: true)

          attr_reader :genre, :targets, :books

          def initialize(genre:, targets:, books:, parent: nil, provider: nil, model: nil)
            @genre = genre
            @targets = targets
            @books = books
            super(parent: parent, provider: provider, model: model)
          end

          private

          def validate_parent!
          end

          def task_provider = :openai

          def task_role = :standard

          def chat_type = :analysis

          def response_format = {type: "json_object"}

          def response_schema = ResponseSchema

          def system_message
            <<~SYSTEM
              A book website is splitting the combined genre "#{genre}" into: #{targets.join(", ")}.
              For each book below, list in "targets" every one of those that truly describes the book, using the names exactly. A book can fit one, several, or none (a physics book wrongly tagged "Science Fiction Fantasy" fits none).
              Use what you know about the book. If you do not recognise it and its details do not settle it, set "unknown" to true and leave "targets" empty.
            SYSTEM
          end

          def user_prompt
            lines = ["Books:"]
            books.each do |book|
              by = book.authors.any? ? " by #{book.authors.join(", ")}" : ""
              year = book.year ? " (#{book.year})" : ""
              lines << "[#{book.key}] #{book.title}#{by}#{year}"
              lines << "  Other genres: #{book.genres.join(", ")}" if book.genres.any?
              lines << "  Description: #{book.description.to_s.truncate(400)}" if book.description.present?
            end
            lines << "" << "Return exactly one result per book, with its number in \"key\"."
            lines.join("\n")
          end

          def process_and_persist(provider_response)
            keys = books.map(&:key)
            results = {}
            Array(value(provider_response[:parsed], :results)).each do |raw|
              key = value(raw, :key).to_s
              next if !keys.include?(key) || results.key?(key)

              names = Array(value(raw, :targets)).map(&:to_s)
              off = names - targets
              return failure("#{off.first.inspect} is not one of #{targets.join(", ")}") if off.any?

              results[key] = (value(raw, :unknown) == true) ? :unknown : names
            end
            missing = keys - results.keys
            return failure("No result for #{missing.join(", ")}") if missing.any?

            Services::Ai::Result.new(success: true, data: {results: results}, ai_chat: chat)
          end

          def value(raw, key)
            return raw[key].nil? ? raw[key.to_s] : raw[key] if raw.is_a?(Hash)

            raw.public_send(key)
          end

          def failure(message) = Services::Ai::Result.new(success: false, error: message, ai_chat: chat)

          class CheckResult < OpenAI::BaseModel
            required :key, String, doc: "The book's number"
            required :targets, OpenAI::ArrayOf[String], doc: "The halves that describe it, names exactly as given"
            required :unknown, OpenAI::Boolean, doc: "True when you do not know the book"
            required :reason, String, doc: "A few words"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :results, OpenAI::ArrayOf[CheckResult], doc: "One per book"
          end
        end
      end
    end
  end
end
