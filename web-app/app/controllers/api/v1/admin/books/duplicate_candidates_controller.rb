# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET  /api/v1/admin/duplicate_candidates         -- the queue; status and item_type filter
        # GET  /api/v1/admin/duplicate_candidates/:id     -- one pair with detail, any status
        # POST /api/v1/admin/duplicate_candidates/:id/merge   -- keep target_id, PERMANENTLY delete the pair's other record
        # POST /api/v1/admin/duplicate_candidates/:id/dismiss -- mark the pair not a duplicate
        #
        # The same pairs the admin queue page shows, scoped to the books domain.
        # Root-anchor every ::Books:: reference in this namespace.
        class DuplicateCandidatesController < BaseController
          include ::Api::V1::Admin::StrictIds
          include MergeFlow

          require_scopes index: "books:admin:read", show: "books:admin:read",
            merge: "books:admin:merge", dismiss: "books:admin:write"

          ITEM_TYPES = {"book" => "Books::Book", "author" => "Books::Author"}.freeze
          STATUSES = ::DuplicateCandidate.statuses.keys.freeze
          NOTE_LIMIT = 1000
          CHANGED_PAIR = "These records are not this pair's (it changed after another merge); nothing was changed. Get the pair again."
          # Per item type: the model, its policy and the merge response's record shape.
          KINDS = {
            "Books::Book" => {model: ::Books::Book, policy: ::Books::BookPolicy, resource: :book_merge_resource},
            "Books::Author" => {model: ::Books::Author, policy: ::Books::AuthorPolicy, resource: :author_merge_resource}
          }.freeze

          def index
            status = enum_param!(:status, STATUSES) || "pending"
            item_type = enum_param!(:item_type, ITEM_TYPES.keys)
            # id is the tiebreaker: a bulk raise stamps many pairs with one created_at.
            pairs = domain_scope.where(status: status).includes(:resolved_by).newest_first.order(id: :desc)
            pairs = pairs.where(item_type: ITEM_TYPES.fetch(item_type)) if item_type

            render_page(pairs, path: "/api/v1/admin/duplicate_candidates",
              query: {status: status, item_type: item_type}.compact) do |rows|
              loaded = ::Services::DuplicateCandidates::PairRecords.call(rows)
              rows.map do |pair|
                DuplicateCandidateResource.new(pair, records: loaded.records, summaries: loaded.summaries).to_h
              end
            end
          end

          def show
            pair = find_pair
            return if performed?

            loaded = ::Services::DuplicateCandidates::PairRecords.call([pair])
            render json: {data: DuplicateCandidateResource.new(pair, records: loaded.records,
              summaries: loaded.summaries, detail: true).to_h}
          end

          def merge
            target_id = parse_id(params.require(:target_id))
            return render_problem(::Api::Problem.new(:invalid_parameter, detail: "target_id must be a positive integer")) if target_id.nil?

            source_id = parse_id(params.require(:source_id))
            return render_problem(::Api::Problem.new(:invalid_parameter, detail: "source_id must be a positive integer")) if source_id.nil?

            note = text_param!(:note, required: false, max_length: NOTE_LIMIT)
            dry_run = ActiveModel::Type::Boolean.new.cast(params[:dry_run]) || false
            pair = find_pair
            return if performed?
            return unless pending_pair?(pair)

            # A merge elsewhere re-keys pending pairs in place (same pair id), so
            # the ids the agent judged must still be exactly this pair's ids, or
            # the other side would be a record it never saw.
            unless source_id != target_id && [source_id, target_id].minmax == [pair.item_a_id, pair.item_b_id]
              return render_problem(::Api::Problem.new(:unprocessable, detail: CHANGED_PAIR))
            end

            kind = KINDS.fetch(pair.item_type)
            target = kind[:model].find_by(id: target_id)
            source = kind[:model].find_by(id: source_id)
            if target.nil? || source.nil?
              return render_problem(::Api::Problem.new(:unprocessable,
                detail: "One record of this pair no longer exists, so there is nothing to merge. Dismiss the pair or list the queue again."))
            end

            body = perform_merge(source:, target:, dry_run:, model_class: kind[:model], policy_class: kind[:policy],
              resource_for: method(kind[:resource]))
            return unless body

            fresh = ::DuplicateCandidate.find_by(id: pair.id) || pair
            # AdminMerge cannot run inside a transaction (the mergers refuse), so
            # the note is a second write. The merger already marked this very
            # (source, target) pair merged and stamped who and how; update_columns
            # because the merge cannot be undone, so a note must not be able to
            # turn a finished merge into an error.
            fresh.update_columns(resolution_note: note, updated_at: Time.current) if !dry_run && note && fresh.merged?
            outcome = if dry_run then "dry_run"
            elsif fresh.merged? then "succeeded"
            else "pair_not_marked_merged"
            end
            log_pair(action: "merge", outcome: outcome, pair: fresh)
            body[:data][:pair] = pair_hash(fresh.reload)
            render json: body
          end

          def dismiss
            ids = params.require(:record_ids)
            record_ids = (ids.is_a?(Array) && ids.size == 2) ? ids.map { |id| parse_id(id) } : nil
            if record_ids.nil? || record_ids.any?(&:nil?)
              return render_problem(::Api::Problem.new(:invalid_parameter, detail: "record_ids must be an array of exactly two positive integers"))
            end

            note = text_param!(:note, required: false, max_length: NOTE_LIMIT)
            pair = find_pair
            return if performed?
            return unless pending_pair?(pair)
            return render_problem(::Api::Problem.new(:unprocessable, detail: CHANGED_PAIR)) unless record_ids.minmax == [pair.item_a_id, pair.item_b_id]

            kind = KINDS.fetch(pair.item_type)
            # Dismissing needs write access to the pair's record type; the pair
            # may name a record that is gone, and the policies never read the record.
            unless kind[:policy].new(current_principal.user, kind[:model].new).update?
              return render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not change #{pair.item_type.demodulize.downcase}s"))
            end

            pair.update!(status: :not_duplicate, resolved_at: Time.current, resolved_by: current_principal.user,
              resolved_via: :api, resolution_note: note)
            log_pair(action: "dismiss", outcome: "succeeded", pair: pair)
            render json: {data: {pair: pair_hash(pair)}}
          end

          private

          def domain_scope
            ::DuplicateCandidate.where(item_type: ITEM_TYPES.values)
          end

          def find_pair
            domain_scope.includes(:match_decision, :resolved_by).find_by(id: params[:id]) || render_problem(
              ::Api::Problem.new(:not_found, detail: "No pending or resolved duplicate pair #{params[:id]}; it may have been folded into another pair by a merge. List the queue again.")
            )
          end

          def pair_hash(pair)
            loaded = ::Services::DuplicateCandidates::PairRecords.call([pair])
            DuplicateCandidateResource.new(pair, records: loaded.records, summaries: loaded.summaries).to_h
          end

          # True for a pending pair; otherwise renders the 422 and returns false.
          def pending_pair?(pair)
            return true if pair.pending?

            render_problem(::Api::Problem.new(:unprocessable,
              detail: "Pair #{pair.id} is already #{pair.status.humanize.downcase}. List the queue again."))
            false
          end

          def log_pair(action:, outcome:, pair:)
            Rails.logger.info("event=api_admin_duplicate action=#{action} outcome=#{outcome} pair_id=#{pair.id} " \
              "user_id=#{current_principal.user.id} token_id=#{current_principal.token.id}")
          end
        end
      end
    end
  end
end
