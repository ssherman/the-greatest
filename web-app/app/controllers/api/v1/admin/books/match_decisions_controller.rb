# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET /api/v1/admin/match_decisions      -- the review queue; entity, outcome, confidence,
        #                                           decided_by, reviewed and verify filters
        # GET /api/v1/admin/match_decisions/:id  -- one decision with its query snapshot and candidates
        # POST /api/v1/admin/match_decisions/:id/review      -- mark reviewed, with an optional verdict and note
        # POST /api/v1/admin/match_decisions/:id/reject_link -- reject a Wikidata/VIAF link: PERMANENTLY removes
        #                                                      the identifier, reverts what it wrote, re-runs enrichment
        #
        # The same decisions the admin audit page shows, scoped to the books
        # finders in DataImporters::FinderRegistry. Root-anchor every ::Books::
        # reference in this namespace.
        class MatchDecisionsController < BaseController
          include ::Api::V1::Admin::StrictIds

          require_scopes index: "books:admin:read", show: "books:admin:read",
            review: "books:admin:write", reject_link: "books:admin:merge"

          Filter = ::Services::MatchDecisions::Filter
          NOTE_LIMIT = 1000
          VERDICTS = ::MatchDecision.verdicts.keys.freeze

          def index
            filters = {
              entity: enum_param!(:entity, entities.keys),
              outcome: enum_param!(:outcome, Filter::OUTCOMES),
              confidence: enum_param!(:confidence, Filter::CONFIDENCES),
              decided_by: enum_param!(:decided_by, Filter::DECIDED_BY),
              reviewed: enum_param!(:reviewed, Filter::REVIEWED) || "pending",
              verify: enum_param!(:verify, Filter::VERIFY) || "hide"
            }
            decisions = Filter.call(domain_scope, filters).includes(:record, :subject, :reviewed_by)
              .newest_first.order(id: :desc)

            render_page(decisions, path: "/api/v1/admin/match_decisions", query: filters.compact) do |rows|
              rows.map { |decision| MatchDecisionResource.new(decision).to_h }
            end
          end

          def show
            decision = find_decision
            return if performed?

            summaries = MatchDecisionResource.summaries_for([decision])
            render json: {data: MatchDecisionResource.new(decision, summaries: summaries, detail: true).to_h}
          end

          def review
            verdict = enum_param!(:verdict, VERDICTS)
            note = text_param!(:note, required: false, max_length: NOTE_LIMIT)
            decision = find_decision
            return if performed?

            user = current_principal.user
            unless ::Books::BookPolicy.new(user, ::Books::Book.new).update?
              return render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not change books"))
            end
            if decision.reviewed_at.present?
              return render_problem(::Api::Problem.new(:unprocessable, detail: "Match decision #{decision.id} is already reviewed."))
            end
            if verdict == "rejected" && decision.matched? && link_finder?(decision)
              return render_problem(::Api::Problem.new(:unprocessable,
                detail: "A matched Wikidata or VIAF link cannot be rejected by review: it leaves the identifier and what it wrote in place. Use reject_match_decision_link, which removes them."))
            end

            ::ActiveRecord::Base.transaction do
              decision.update!(verdict: verdict) if verdict
              decision.review!(by: user, note: note)
            end
            render_detail(decision)
          end

          def reject_link
            note = text_param!(:note, required: false, max_length: NOTE_LIMIT)
            decision = find_decision
            return if performed?

            user = current_principal.user
            author = decision.subject.is_a?(::Books::Author) ? decision.subject : ::Books::Author.new
            unless ::Books::AuthorPolicy.new(user, author).destroy?
              return render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not delete authors, so it may not reject their links."))
            end

            result = ::Services::Books::Authors::RejectExternalLink.call(decision: decision, user: user)
            unless result.success?
              return render_problem(::Api::Problem.new(:unprocessable, detail: result.errors.to_sentence))
            end

            # The service has stamped who and how; the agent's note rides after its own.
            decision.reload.update_columns(review_note: "#{decision.review_note} \u2014 #{note}") if note
            rejected = result.data[:decisions]
            Rails.logger.info("event=api_admin_reject_link decision_id=#{decision.id} rejected=#{rejected.map(&:id).join(",")} " \
              "user_id=#{user.id} token_id=#{current_principal.token.id}")
            render json: {data: {
              decision: MatchDecisionResource.new(decision.reload).to_h,
              rejected: rejected.map(&:id),
              reverted: result.data[:reverted],
              descriptions_deprecated: result.data[:descriptions_deprecated]
            }}
          end

          private

          def link_finder?(decision) = ::Services::Books::Authors::RejectedRecords::FINDERS.key?(decision.finder)

          def render_detail(decision)
            decision = find_decision_record(decision.id)
            summaries = MatchDecisionResource.summaries_for([decision])
            render json: {data: MatchDecisionResource.new(decision, summaries: summaries, detail: true).to_h}
          end

          def find_decision_record(id) = domain_scope.includes(:record, :subject, :reviewed_by).find(id)

          # label.parameterize => finder, for this domain's registered finders.
          def entities
            ::DataImporters::FinderRegistry.for_domain(:books).to_h { |entry| [entry.label.parameterize, entry.finder] }
          end

          def domain_scope
            ::MatchDecision.where(finder: ::DataImporters::FinderRegistry.for_domain(:books).map(&:finder))
          end

          def find_decision
            id = parse_id(params[:id])
            domain_scope.includes(:record, :subject, :reviewed_by).find_by(id: id) || render_problem(
              ::Api::Problem.new(:not_found, detail: "No match decision #{params[:id]} in the books queue.")
            )
          end
        end
      end
    end
  end
end
