# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Books
        # Judges whether each alternate title of one book names the same work
        # (spec 2026-10-23, Part 2). Numbered titles in, one verdict per number
        # out, keyed by its number so a dropped or reordered row is detected.
        class AlternateTitlesReviewTask < BaseTask
          Entry = Struct.new(:key, :title, keyword_init: true)

          VERDICT_CATEGORIES = {
            "same_work" => %w[translation variant fuller_title short_title],
            "not_same_work" => %w[other_work volume_or_part combined_edition junk]
          }.freeze

          attr_reader :entries, :accepted

          def initialize(parent:, entries:, accepted: [], provider: nil, model: nil)
            @entries = entries
            @accepted = Array(accepted)
            super(parent: parent, provider: provider, model: model)
          end

          private

          def task_provider = :openai

          def task_role = :fast

          def chat_type = :analysis

          def response_format = {type: "json_object"}

          def response_schema = ResponseSchema

          def system_message
            <<~SYSTEM
              A book catalog keeps a list of alternate titles for each book. Many entries are wrong: they are the titles of other works. For each numbered title, decide whether it names the same work as the book described, and say why.

              Verdict "same_work", with one category:
              - translation: a translation or transliteration of the same work
              - variant: a spelling or punctuation variant, or the title of another edition of the same text
              - fuller_title: the same title with a subtitle or series added
              - short_title: a shortened form of the title

              Verdict "not_same_work", with one category:
              - other_work: a sequel, prequel, companion, a different book by the same author, or an unrelated work
              - volume_or_part: one volume, part or book of a multi-volume work, or a chapter (for example "My Struggle: Book 1", or "Capítulo 22", which is "Chapter 22")
              - combined_edition: the book bundled with other works
              - junk: not a title at all, such as a description, an ISBN or garbage

              Give a confidence from 0 to 1 for how sure you are the verdict is right. When you are unsure, use a lower confidence rather than guessing. Give a one-sentence reason.
            SYSTEM
          end

          def user_prompt
            lines = ["Book: #{parent.title.inspect}"]
            lines << "Subtitle: #{parent.subtitle}" if parent.subtitle.present?
            names = parent.authors.map(&:name)
            lines << "Author#{"s" if names.size > 1}: #{names.join(", ")}" if names.any?
            lines << "First published: #{parent.first_published_year}" if parent.first_published_year.present?
            lines << "Already accepted alternate titles: #{accepted.map(&:inspect).join(", ")}" if accepted.any?
            lines << ""
            lines << "Alternate titles to judge:"
            entries.each { |entry| lines << "[#{entry.key}] #{entry.title.inspect}" }
            lines << ""
            lines << "Return exactly one result per number, with the number in \"key\"."
            lines.join("\n")
          end

          # to_h is shallow on OpenAI::BaseModel: each element of :results stays
          # a model instance, so read through `value`.
          def process_and_persist(provider_response)
            keys = entries.map(&:key).to_set
            results = Array(value(provider_response[:parsed], :results)).each_with_object({}) do |raw, by_key|
              parsed = normalize(raw)
              next if parsed.nil? || !keys.include?(parsed[:key]) || by_key.key?(parsed[:key])

              by_key[parsed[:key]] = parsed.except(:key)
            end
            Services::Ai::Result.new(success: true, data: {results: results}, ai_chat: chat)
          end

          def normalize(raw)
            verdict = string(raw, :verdict)
            category = string(raw, :category)
            confidence = value(raw, :confidence)
            return nil unless VERDICT_CATEGORIES.fetch(verdict, []).include?(category)
            return nil unless confidence.is_a?(Numeric) && confidence.between?(0, 1)

            {key: string(raw, :key), verdict: verdict, category: category,
             confidence: confidence.to_f, reason: string(raw, :reason)}
          end

          # Hash first: Hash#key exists, so respond_to?(:key) is true for a Hash.
          def value(raw, key)
            return raw[key].nil? ? raw[key.to_s] : raw[key] if raw.is_a?(Hash)

            raw.public_send(key)
          end

          def string(raw, key) = value(raw, key).to_s.strip

          class TitleResult < OpenAI::BaseModel
            required :key, String, doc: "The title's number"
            required :verdict, String, doc: "same_work or not_same_work"
            required :category, String, doc: "One category that belongs to the verdict"
            required :confidence, Float, doc: "0 to 1: how sure the verdict is right"
            required :reason, String, doc: "One sentence"
          end

          class ResponseSchema < OpenAI::BaseModel
            required :results, OpenAI::ArrayOf[TitleResult], doc: "One per title"
          end
        end
      end
    end
  end
end
