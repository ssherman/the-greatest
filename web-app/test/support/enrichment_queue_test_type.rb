# frozen_string_literal: true

# A queue type for the engine's tests. Tests stub
# Services::EnrichmentQueue::Registry.types to return [EnrichmentQueueTestType]
# and set candidate_ids, needed and apply_result per test.
class EnrichmentQueueTestType < Services::EnrichmentQueue::Type
  class << self
    attr_accessor :candidate_ids, :needed, :apply_result

    def reset!
      self.candidate_ids = []
      self.needed = true
      self.apply_result = Services::EnrichmentQueue::Type::Result.new(
        success?: true, data: {enrichment: nil, outcome: "applied"}, errors: []
      )
    end

    def kind = "books.test_type"

    def label = "Test type"

    def version = 1

    def target_class = ::Books::Book

    def candidates(scope:) = ::Books::Book.where(id: candidate_ids)

    def priority_sql = "books_books.id"

    def priority_for(record) = record.id

    def still_needed?(record) = needed

    def payload(record) = {"book_id" => record.id}

    def reference = {"answer_schema" => answer_schema}

    def answer_schema
      {"type" => "object", "required" => ["value"], "properties" => {"value" => {"type" => "string"}}, "additionalProperties" => false}
    end

    def apply(request) = apply_result
  end

  reset!
end
