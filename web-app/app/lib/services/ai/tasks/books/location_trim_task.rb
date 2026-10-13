# frozen_string_literal: true

module Services
  module Ai
    module Tasks
      module Books
        # Spec §5: picks which of a book's existing direct locations to keep.
        # The answer is a subset of the ids offered; anything else is dropped
        # in code, so the model can remove but never add.
        class LocationTrimTask < BaseTask
          Location = Struct.new(:id, :trail, :fixed, keyword_init: true)

          attr_reader :book, :locations

          def initialize(book:, locations:, provider: nil, model: nil)
            @book = book
            @locations = locations
            super(parent: book, provider: provider, model: model)
          end

          private

          def task_provider = :openai

          def task_role = :standard

          def chat_type = :analysis

          def response_format = {type: "json_object"}

          def system_message
            <<~SYSTEM
              You are trimming the setting locations of one book. Old tagging attached every place a book mentions, sometimes hundreds; the book page should list only where the book is set.

              Return the ids of the locations to keep, chosen only from the list:
              - A novel, memoir or other narrative: the places where substantial parts of it take place, usually one to six.
              - Nonfiction that surveys many countries or the whole world: the continents or regions it covers, or an empty list when it is truly global.
              - Keep the most specific place that matters. Containing places are added automatically, so do not keep a country just because a city in it is kept.
              - If no continent or region is offered for a survey, keep its most central countries instead of returning an empty list.
              - Locations marked "fixed" were set by an editor and are kept regardless; you do not need to return them.
              - Never return an id that is not in the list.
            SYSTEM
          end

          def user_prompt
            lines = ["Book: #{book.title.inspect}"]
            authors = book.authors.map(&:name)
            lines << "Author(s): #{authors.join(", ")}" if authors.any?
            lines << "First published: #{::Services::Books::YearLabel.call(book.first_published_year)}" if book.first_published_year.present?
            description = book.primary_description&.content
            lines << "Description: #{description.truncate(1500)}" if description.present?
            lines << "" << "Current locations:"
            locations.each { |location| lines << "[#{location.id}] #{location.trail}#{" (fixed — always kept)" if location.fixed}" }
            lines << "" << "Answer with keep_ids and a one-sentence reason."
            lines.join("\n")
          end

          def response_schema = ResponseSchema

          # parsed is a symbol-keyed Hash at the top level (OpenaiStrategy).
          def process_and_persist(provider_response)
            data = provider_response[:parsed]
            offered = locations.map(&:id).to_set
            keep = Array(data[:keep_ids]).select { |id| id.is_a?(Integer) && offered.include?(id) }.uniq
            Services::Ai::Result.new(success: true, data: {keep_ids: keep, raw_count: Array(data[:keep_ids]).size, reason: data[:reason].to_s}, ai_chat: chat)
          end

          class ResponseSchema < OpenAI::BaseModel
            required :keep_ids, OpenAI::ArrayOf[Integer], doc: "Ids from the list to keep; empty when the book is truly global"
            required :reason, String, doc: "One sentence"
          end
        end
      end
    end
  end
end
