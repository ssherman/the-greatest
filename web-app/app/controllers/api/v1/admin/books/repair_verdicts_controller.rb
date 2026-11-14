# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET /api/v1/admin/repair_verdicts      -- the Goodreads repair-verdict review queue; kind, status, decided_by,
        #                                           confidence and guess filters
        # GET /api/v1/admin/repair_verdicts/:id  -- one verdict with its payload, books, candidates and source rows
        #
        # POST /api/v1/admin/repair_verdicts/:id/approve   -- approve a proposed verdict (never applies it)
        # POST /api/v1/admin/repair_verdicts/:id/reject     -- reject; an applied mark_provisional is reverted
        # POST /api/v1/admin/repair_verdicts/:id/correct    -- answer a reimport_match: {book_id} or {create: true}
        # POST /api/v1/admin/repair_verdicts/bulk_approve   -- {ids: [1..100]}: approve the proposed, current ones
        #
        # The same verdicts the admin page shows. Superseded verdicts never appear in the list. Root-anchor every
        # ::Books:: reference in this namespace.
        class RepairVerdictsController < BaseController
          include ::Api::V1::Admin::StrictIds

          require_scopes index: "books:admin:read", show: "books:admin:read",
            approve: "books:admin:merge", bulk_approve: "books:admin:merge",
            reject: "books:admin:write", correct: "books:admin:write"

          Filter = ::Services::Books::RepairVerdicts::Filter
          Review = ::Services::Books::RepairVerdicts::Review
          VIA = "api"
          MAX_BULK = 100

          def index
            filters = {
              kind: enum_param!(:kind, Filter::KINDS),
              status: enum_param!(:status, Filter::STATUSES) || "proposed",
              decided_by: enum_param!(:decided_by, Filter::DECIDED_BY),
              confidence: enum_param!(:confidence, Filter::CONFIDENCES),
              guess: enum_param!(:guess, %w[true])
            }
            verdicts = Filter.call(kind: filters[:kind], decided_by: filters[:decided_by],
              confidence: filters[:confidence], guess: filters[:guess])
              .where(status: filters[:status]).newest_first

            render_page(verdicts, path: "/api/v1/admin/repair_verdicts", query: filters.compact) do |rows|
              rows.map { |verdict| RepairVerdictResource.new(verdict).to_h }
            end
          end

          def show
            verdict = find_verdict
            return if performed?

            render json: {data: RepairVerdictDetailResource.new(verdict).to_h}
          end

          def approve
            verdict = find_current_verdict
            return if performed?

            result = Review.approve(verdict: verdict, user: acting_user, via: VIA)
            render_review(result, verdict, "approve")
          end

          def reject
            verdict = find_current_verdict
            return if performed?

            result = Review.reject(verdict: verdict, user: acting_user, via: VIA)
            render_review(result, verdict, "reject")
          end

          def correct
            book_id = params[:book_id]
            raise ::Api::Page::InvalidParameter, "book_id must be an integer" unless book_id.nil? || book_id.is_a?(Integer)
            create = params[:create]
            raise ::Api::Page::InvalidParameter, "create must be true or false" unless create.nil? || [true, false].include?(create)
            verdict = find_verdict
            return if performed?
            return unless may_change_books?

            result = ::Services::Books::GoodreadsReimport::CorrectMatch.call(
              verdict: verdict, user: acting_user, book_id: book_id, create: create || false, via: VIA
            )
            return render_problem(::Api::Problem.new(:unprocessable, detail: result.errors.to_sentence)) unless result.success?

            log("correct", verdict)
            render_detail(verdict)
          end

          def bulk_approve
            raw = params[:ids]
            unless raw.is_a?(Array) && raw.size.between?(1, MAX_BULK)
              raise ::Api::Page::InvalidParameter, "ids must be an array of 1 to #{MAX_BULK} ids"
            end
            ids = raw.map { |value| (value.is_a?(Integer) && value >= 1) ? value : nil }
            raise ::Api::Page::InvalidParameter, "ids must be positive integers" if ids.any?(&:nil?)
            return unless may_change_books?

            result = Review.bulk_approve(ids: ids, user: acting_user, via: VIA)
            Rails.logger.info("event=api_admin_repair_verdict_bulk_approve approved=#{result.data[:approved_ids].join(",")} " \
              "user_id=#{acting_user.id} token_id=#{current_principal.token.id}")
            render json: {data: {approved_ids: result.data[:approved_ids], skipped_ids: result.data[:skipped_ids]}}
          end

          private

          def acting_user = current_principal.user

          def may_change_books?
            return true if ::Books::BookPolicy.new(acting_user, ::Books::Book.new).update?

            render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not change books"))
            false
          end

          def find_verdict
            verdict = ::Books::RepairVerdict.find_by(id: parse_id(params[:id]))
            verdict || render_problem(::Api::Problem.new(:not_found, detail: "No repair verdict #{params[:id]}."))
          end

          # Review does not look at superseded_at (the admin page is unchanged), so approve and reject refuse here.
          def find_current_verdict
            verdict = find_verdict
            return if performed?
            return unless may_change_books?

            if verdict.superseded_at.present?
              render_problem(::Api::Problem.new(:unprocessable, detail: "Repair verdict #{verdict.id} was replaced by a newer one and cannot be reviewed."))
              return
            end
            verdict
          end

          def render_review(result, verdict, action)
            return render_problem(::Api::Problem.new(:unprocessable, detail: result.errors.to_sentence)) unless result.success?

            log(action, verdict)
            render_detail(verdict)
          end

          def render_detail(verdict) = render(json: {data: RepairVerdictDetailResource.new(verdict.reload).to_h})

          def log(action, verdict)
            Rails.logger.info("event=api_admin_repair_verdict_#{action} verdict_id=#{verdict.id} user_id=#{acting_user.id} " \
              "token_id=#{current_principal.token.id}")
          end
        end
      end
    end
  end
end
