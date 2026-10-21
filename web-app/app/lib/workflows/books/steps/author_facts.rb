# frozen_string_literal: true

# The AI step of the author workflow: EnrichAuthor, with research on unless the
# run says otherwise (the backfill turns it off). A failed run raises, so the
# coordinator retries it as Books::Authors::EnrichJob's Sidekiq retries did.
module Workflows
  module Books
    module Steps
      class AuthorFacts
        def call(step:, run:, target:)
          result = ::Services::Books::Authors::EnrichAuthor.call(author: target, allow_research: run.options.fetch("allow_research", true))
          raise StandardError, "Author enrichment failed for author #{target.id}: #{result.errors.join("; ")}" unless result.success?

          Workflows::Outcome.succeeded("done")
        end
      end
    end
  end
end
