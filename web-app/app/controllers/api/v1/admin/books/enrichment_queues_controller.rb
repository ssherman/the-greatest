# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET  /api/v1/admin/enrichment_queues               -- every queue type with its status counts
        # GET  /api/v1/admin/enrichment_queues/:type         -- one queue: counts, outcomes and the answer reference
        # POST /api/v1/admin/enrichment_queues/:type/claims  -- {limit}: lease a batch of pending items
        #
        # The agent-facing side of the enrichment queues. Root-anchor every ::Books:: reference in this namespace.
        class EnrichmentQueuesController < BaseController
          include EnrichmentQueueSupport

          require_scopes index: "books:admin:read", show: "books:admin:read", claim: "books:admin:write"

          Registry = ::Services::EnrichmentQueue::Registry
          Claim = ::Services::EnrichmentQueue::Claim

          def index
            render json: {data: Registry.for_domain(DOMAIN).map { |type| EnrichmentQueueResource.new(type).to_h }}
          end

          def show
            type = find_type
            return if performed?

            render json: {data: EnrichmentQueueResource.new(type, detail: true).to_h}
          end

          def claim
            type = find_type
            return if performed?
            return unless may_change_books?

            result = Claim.call(kind: type.kind, limit: claim_limit, user: acting_user)
            return render_problem(::Api::Problem.new(:unprocessable, detail: result.errors.to_sentence)) unless result.success?

            data = result.data
            log_enrichment("claim", "type=#{type.slug} claimed=#{data[:items].size}")
            render json: {
              data: data[:items].map { |row| EnrichmentItemResource.new(row, type).to_h },
              meta: {lease_token: data[:lease_token], lease_expires_at: data[:lease_expires_at], remaining: data[:remaining]}
            }
          end

          private

          def find_type
            Registry.find(domain: DOMAIN, slug: params[:type]) ||
              render_problem(::Api::Problem.new(:not_found, detail: "No enrichment queue #{params[:type]}."))
          end

          # Absent or null is the default; anything but an integer in range is a 400.
          def claim_limit
            body = request.raw_post.blank? ? {} : json_body
            invalid!("The body must be a JSON object.") if body.nil?
            limit = body["limit"]
            return Claim::DEFAULT_LIMIT if limit.nil?

            unless limit.is_a?(Integer) && (1..Claim::MAX_LIMIT).cover?(limit)
              invalid!("limit must be an integer from 1 to #{Claim::MAX_LIMIT}")
            end
            limit
          end
        end
      end
    end
  end
end
