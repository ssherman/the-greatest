# frozen_string_literal: true

module Services
  module EnrichmentQueue
    # The interface one kind of queued enrichment implements. A type is a class
    # whose class methods describe what to find (candidates), what to hand an
    # agent (payload, reference, answer_schema) and how to apply an answer
    # (apply). The engine (fill, claim, submit) only ever calls these methods,
    # so a new kind of enrichment is a new subclass and an entry in the Registry.
    class Type
      SCOPES = %w[ranked all].freeze
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      class << self
        # "books.origin"
        def kind = raise(NotImplementedError, "#{name} must define kind")

        # "Book origin", shown on the admin page
        def label = raise(NotImplementedError, "#{name} must define label")

        def version = raise(NotImplementedError, "#{name} must define version")

        def target_class = raise(NotImplementedError, "#{name} must define target_class")

        # A relation on target_class; scope is "ranked" or "all".
        def candidates(scope:) = raise(NotImplementedError, "#{name} must define candidates")

        # SQL expression valid inside candidates, lower first.
        def priority_sql = raise(NotImplementedError, "#{name} must define priority_sql")

        # The priority this one record would get in candidates (the value
        # priority_sql gives it), whether or not candidates would offer it now.
        def priority_for(record) = raise(NotImplementedError, "#{name} must define priority_for")

        def still_needed?(record) = raise(NotImplementedError, "#{name} must define still_needed?")

        # JSON-able Hash for one item.
        def payload(record) = raise(NotImplementedError, "#{name} must define payload")

        # JSON-able Hash sent once per agent; includes "answer_schema".
        def reference = raise(NotImplementedError, "#{name} must define reference")

        def answer_schema = raise(NotImplementedError, "#{name} must define answer_schema")

        # Returns a Result with data: {enrichment:, outcome:}.
        def apply(request) = raise(NotImplementedError, "#{name} must define apply")

        # True when the type can be worked by the paid research worker
        # (Research), which runs the same forced path an importer would.
        def paid_research? = false

        # The paid research path for one claimed row: runs the type's own model
        # call with research forced and returns a Result with
        # data: {enrichment:, outcome:} (see ledger_result).
        def research(request) = raise(NotImplementedError, "#{name} must define research")

        # The Result for the ledger row a paid run ended on. A row that failed or
        # was skipped (disabled, no inputs, ...) is a failure for the queue row;
        # the row's mode is not checked: a forced origin run can still take the
        # Wikidata shortcut and end applied without a web search.
        def ledger_result(row)
          errors = if row.nil?
            ["no ledger row"]
          elsif row.failed?
            [row.error]
          elsif row.skipped?
            ["skipped: #{row.reason}"]
          end
          return Result.new(success?: false, data: nil, errors: errors) if errors

          Result.new(success?: true, data: {enrichment: row, outcome: row.outcome}, errors: [])
        end

        # Extra ERB locals for the Copy prompt.
        def prompt_locals = {}

        # The part of kind before the dot.
        def domain = kind.split(".", 2).first

        # The part of kind after the dot.
        def slug = kind.split(".", 2).last
      end
    end
  end
end
