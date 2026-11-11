# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # What a merge does once it holds a source and a target: authorize
        # destroy? on BOTH, snapshot the source, merge, log. Shared by Mergeable
        # (the by-record-id endpoints) and DuplicateCandidatesController (the
        # by-pair endpoint), which pick the record type per request, so the
        # type's model, policy and resource builder are arguments.
        # Root-anchor every ::Books:: reference in this namespace.
        module MergeFlow
          extend ActiveSupport::Concern

          private

          # The response body hash, or nil after rendering a problem.
          def perform_merge(source:, target:, dry_run:, model_class:, policy_class:, resource_for:)
            noun = model_class.name.demodulize.downcase
            {"source" => source, "target" => target}.each do |role, record|
              next if policy_class.new(current_principal.user, record).destroy?

              render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not delete the #{role} #{noun}"))
              return nil
            end

            # Captured before the merge: the source row does not exist afterwards.
            deleted = resource_for.call(source)
            result = ::Services::Books::AdminMerge.call(source:, target:, dry_run:)
            unless result.success?
              log_merge(model_class:, source:, target:, outcome: "failed", errors: result.errors) unless dry_run
              render_problem(::Api::Problem.new(:unprocessable, detail: result.errors.join(", ")))
              return nil
            end

            log_merge(model_class:, source:, target:, outcome: "succeeded") unless dry_run
            {
              data: {survivor: resource_for.call(target), deleted: deleted},
              meta: {dry_run: dry_run},
              warnings: result.data[:warnings]
            }
          end

          # Re-read with the associations the resource renders, so the survivor
          # reflects the merge and the deleted record is captured whole.
          def book_merge_resource(book)
            BookResource.new(::Books::Book.includes(:authors, :primary_ranked_item).find(book.id)).to_h
          end

          def author_merge_resource(author)
            author = ::Books::Author.includes(:primary_ranked_item).find(author.id)
            counts = ::Books::BookAuthor.where(author_id: author.id).group(:author_id).count
            AuthorResource.new(author, params: {book_counts: counts}).to_h
          end

          def log_merge(model_class:, source:, target:, outcome:, errors: nil)
            line = "event=api_admin_merge outcome=#{outcome} token_id=#{current_principal.token.id} token_kind=#{current_principal.token_kind} " \
              "user_id=#{current_principal.user.id} record_type=#{model_class.name} " \
              "source_id=#{source.id} target_id=#{target.id}"
            line += " errors=#{Array(errors).join("; ").inspect}" if errors
            Rails.logger.info(line)
          end
        end
      end
    end
  end
end
