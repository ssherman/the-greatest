# Resolves a stored workflow name (WorkflowRun#workflow) to its definition
# class. Built-in definitions are named by string so this file never holds a
# class that a code reload has replaced; tests add and remove their own through
# register/unregister. Registering validates the definition; the built-in ones
# are covered by the definition test.
module Workflows
  module Registry
    DEFINITIONS = {
      "books.author_enrichment" => "Workflows::Books::AuthorEnrichment",
      "books.book_enrichment" => "Workflows::Books::BookEnrichment"
    }.freeze

    @registered = {}

    class << self
      # Raises KeyError for a name that is neither built in nor registered.
      def fetch(workflow_name)
        entry = @registered.fetch(workflow_name) { DEFINITIONS.fetch(workflow_name) }
        entry.is_a?(String) ? entry.constantize : entry
      end

      def register(workflow_name, klass)
        klass.validate!
        @registered[workflow_name] = klass
      end

      def unregister(workflow_name)
        @registered.delete(workflow_name)
      end
    end
  end
end
