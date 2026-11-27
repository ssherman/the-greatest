# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # GET  /api/v1/admin/book_submissions               -- the review queue; status and review_status filters, counts in meta
        # POST /api/v1/admin/book_submissions               -- {method, goodreads_url|amazon_url|isbn|title+authors, list_id, position, confirmed_new}: ask for a book
        # GET  /api/v1/admin/book_submissions/:id           -- one submission with its lookups, finder decision and book
        # POST /api/v1/admin/book_submissions/claims        -- {limit}: lease a batch of submissions to decide
        # POST /api/v1/admin/book_submissions/:id/details   -- {lease_token, title, author_names, identifiers, note}: a request with no book
        # POST /api/v1/admin/book_submissions/:id/skip      -- {lease_token, reason}: hand it to a person
        # POST /api/v1/admin/book_submissions/:id/approve   -- {lease_token, note, sources}: the book becomes public
        # POST /api/v1/admin/book_submissions/:id/merge     -- {lease_token, target_id, note, sources, dry_run}: PERMANENT
        # POST /api/v1/admin/book_submissions/:id/reject    -- {lease_token, note, sources, dry_run}: deletes the book, PERMANENT
        #
        # The agent side of the books users ask for that the catalogue lacks. Every rule lives in
        # Services::Books::BookSubmissions, shared with the admin page; this controller parses, authorizes and maps
        # Results: :conflict (a lost lease, a row already decided) is a 409, :invalid a 422. A body field of the
        # wrong type is a 400, and keys it does not know are ignored (a request for a new book, `create`, is the
        # exception: an unknown key is a 422 naming the accepted ones). Root-anchor every ::Books:: reference in this
        # namespace.
        class BookSubmissionsController < BaseController
          include ::Api::V1::Admin::StrictIds
          include EnrichmentQueueSupport
          include MergeFlow

          require_scopes index: "books:admin:read", show: "books:admin:read", create: "books:admin:write",
            claim: "books:admin:write", details: "books:admin:write", skip: "books:admin:write",
            approve: "books:admin:merge", merge: "books:admin:merge", reject: "books:admin:merge"

          Submissions = ::Services::Books::BookSubmissions
          REQUEST_FIELDS = %w[method goodreads_url amazon_url isbn title authors list_id position confirmed_new].freeze
          STATUSES = ::Books::BookSubmission.statuses.keys.freeze
          REVIEW_STATUSES = ::Books::BookSubmission.review_statuses.keys.freeze

          def index
            status = enum_param!(:status, STATUSES)
            review_status = enum_param!(:review_status, REVIEW_STATUSES)
            rows = (status || review_status) ? ::Books::BookSubmission.all : ::Books::BookSubmission.reviewable
            rows = rows.where(status: status) if status
            rows = rows.where(review_status: review_status) if review_status

            render_page(rows.order(:created_at, :id), path: "/api/v1/admin/book_submissions",
              query: {status: status, review_status: review_status}.compact, meta: queue_meta) do |page|
              BookSubmissionResource.collection(page)
            end
          end

          def show
            submission = find_submission
            return if performed?

            render json: {data: BookSubmissionResource.one(submission)}
          end

          # An admin agent asking for a book the site may lack, optionally onto a books list at a position.
          def create
            return unless may?(:update?, nil)

            body = required_body
            unknown = body.keys - REQUEST_FIELDS
            if unknown.any?
              return render_problem(::Api::Problem.new(:unprocessable,
                detail: "Unknown field#{"s" if unknown.size > 1}: #{unknown.join(", ")}. Accepted: #{REQUEST_FIELDS.join(", ")}."))
            end

            list_id = integer_field!(body, "list_id")
            position = integer_field!(body, "position")
            confirmed_new = body["confirmed_new"].nil? ? false : body["confirmed_new"]
            invalid!("confirmed_new must be true or false") unless [true, false].include?(confirmed_new)
            list = nil
            if list_id
              list = ::Books::List.find_by(id: list_id)
              return render_problem(::Api::Problem.new(:not_found, detail: "No books list #{list_id}.")) unless list
            end

            result = Submissions::AdminRequest.call(user: acting_user, params: body.slice(*REQUEST_FIELDS - %w[list_id position confirmed_new]),
              list: list, position: position, confirmed_new: confirmed_new)
            unless result.success?
              return render_problem(::Api::Problem.new(:unprocessable, detail: result.errors.to_sentence))
            end

            data = result.data
            log("request", "outcome=#{data[:outcome]}")
            if data[:outcome] == :hits
              render json: {data: {outcome: "hits", books: data[:books].map { |book| hit(book) }}}
            else
              render json: {data: {outcome: data[:outcome].to_s, submission: BookSubmissionResource.one(data[:submission])}},
                status: (data[:outcome] == :created) ? :created : :ok
            end
          end

          def claim
            return unless may?(:update?, nil)

            result = Submissions::Claim.call(user: acting_user, limit: claim_limit)
            return render_failure(result) unless result.success?

            data = result.data
            log("claim", "claimed=#{data[:items].size}")
            render json: {
              data: BookSubmissionResource.collection(data[:items]),
              meta: {lease_token: data[:lease_token], lease_expires_at: data[:lease_expires_at], remaining: data[:remaining]}
            }
          end

          def details
            submission = find_submission
            return if performed?
            return unless may?(:update?, nil)

            lease_token = string_field!("lease_token")
            title = string_field!("title")
            author_names = strings_field!("author_names")
            note = string_field!("note")
            identifiers = required_body["identifiers"]
            invalid!("identifiers must be a JSON object") unless identifiers.nil? || identifiers.is_a?(Hash)

            result = Submissions::SupplyDetails.call(submission: submission, title: title, author_names: author_names,
              identifiers: identifiers || {}, user: acting_user, via: VIA, note: note, lease_token: lease_token)
            render_submission(result, "details", submission)
          end

          def skip
            submission = find_submission
            return if performed?
            return unless may?(:update?, nil)

            lease_token = string_field!("lease_token")
            reason = string_field!("reason")

            result = Submissions::Skip.call(submission: submission, reason: reason, user: acting_user, via: VIA, lease_token: lease_token)
            render_submission(result, "skip", submission)
          end

          def approve
            submission = find_submission
            return if performed?
            return unless may?(:update?, submission.book)

            lease_token, note, sources = decision_fields

            result = Submissions::Approve.call(submission: submission, user: acting_user, via: VIA, lease_token: lease_token,
              note: note, sources: sources)
            render_submission(result, "approve", submission)
          end

          def merge
            submission = find_submission
            return if performed?
            return unless may?(:destroy?, submission.book)

            lease_token, note, sources = decision_fields
            target_id = parse_id(required_body["target_id"]) || invalid!("target_id must be a positive integer")
            dry_run = dry_run_field!
            target = ::Books::Book.find_by(id: target_id)
            return if target && !may?(:destroy?, target)

            # Captured before the merge: the source row does not exist afterwards.
            deleted = submission.book && book_merge_resource(submission.book)
            result = Submissions::Merge.call(submission: submission, target_id: target_id, user: acting_user, via: VIA,
              lease_token: lease_token, note: note, sources: sources, dry_run: dry_run)
            return render_failure(result) unless result.success?

            log("merge", "submission_id=#{submission.id} target_id=#{target_id}") unless dry_run
            render json: {
              data: {submission: BookSubmissionResource.one(dry_run ? submission.reload : result.data[:submission]),
                     survivor: book_merge_resource(target), deleted: deleted},
              meta: {dry_run: dry_run},
              warnings: result.data[:warnings] || []
            }
          end

          def reject
            submission = find_submission
            return if performed?
            return unless may?(:destroy?, submission.book)

            lease_token, note, sources = decision_fields
            dry_run = dry_run_field!

            result = Submissions::Reject.call(submission: submission, user: acting_user, via: VIA, lease_token: lease_token,
              note: note, sources: sources, dry_run: dry_run)
            return render_failure(result) unless result.success?

            data = result.data
            log("reject", "submission_id=#{submission.id} book_id=#{data[:book_id]}") unless dry_run
            render json: {
              data: {book_id: data[:book_id], author_ids: data[:author_ids], submission_ids: data[:submission_ids],
                     submission: BookSubmissionResource.one(dry_run ? submission.reload : data[:submission])},
              meta: {dry_run: dry_run}
            }
          end

          private

          def find_submission
            ::Books::BookSubmission.find_by(id: parse_id(params[:id])) ||
              render_problem(::Api::Problem.new(:not_found, detail: "No book submission #{params[:id]}."))
          end

          # The row counts per review state across the whole table, and how many an agent could claim now.
          def queue_meta
            counts = ::Books::BookSubmission.group(:review_status).count
            {review_counts: REVIEW_STATUSES.index_with { |state| counts.fetch(state, 0) }, claimable: ::Books::BookSubmission.claimable.count}
          end

          # The book the action changes, or nil when the row has none (the service then answers its own refusal).
          def may?(action, book)
            return true if ::Books::BookPolicy.new(acting_user, book || ::Books::Book.new).public_send(action)

            verb = (action == :destroy?) ? "delete" : "change"
            render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not #{verb} books"))
            false
          end

          def required_body = @required_body ||= json_body || invalid!("The body must be a JSON object.")

          # Absent or null is the default; anything but an integer in range is a 400.
          def claim_limit
            body = request.raw_post.blank? ? {} : required_body
            limit = body["limit"]
            return Submissions::Claim::DEFAULT_LIMIT if limit.nil?

            unless limit.is_a?(Integer) && (1..Submissions::Claim::MAX_LIMIT).cover?(limit)
              invalid!("limit must be an integer from 1 to #{Submissions::Claim::MAX_LIMIT}")
            end
            limit
          end

          # Absent or null is nil; anything else must be an integer.
          def integer_field!(body, key)
            value = body[key]
            return nil if value.nil?

            invalid!("#{key} must be an integer") unless value.is_a?(Integer)

            value
          end

          def hit(book)
            {id: book.id, title: book.title, authors: book.authors.map(&:name), first_published_year: book.first_published_year,
             provisional: book.provisional}
          end

          def string_field!(key)
            value = required_body[key]
            invalid!("#{key} must be a string") unless value.is_a?(String)

            value
          end

          def strings_field!(key)
            value = required_body[key]
            invalid!("#{key} must be an array of strings") unless value.is_a?(Array) && value.all?(String)

            value
          end

          # The three every decision carries, typed before anything is judged.
          def decision_fields = [string_field!("lease_token"), string_field!("note"), strings_field!("sources")]

          # Absent is false; anything but true or false is a 400.
          def dry_run_field!
            return false unless required_body.key?("dry_run")

            value = required_body["dry_run"]
            invalid!("dry_run must be true or false") unless [true, false].include?(value)

            value
          end

          def render_submission(result, action, submission)
            return render_failure(result) unless result.success?

            log(action, "submission_id=#{submission.id}")
            render json: {data: BookSubmissionResource.one(result.data[:submission])}
          end

          def render_failure(result)
            error = result.errors.first
            code = (error[:code] == :conflict) ? :conflict : :unprocessable
            render_problem(::Api::Problem.new(code, detail: error[:detail]))
          end

          def log(action, subject)
            Rails.logger.info("event=api_admin_book_submission_#{action} #{subject} user_id=#{acting_user.id} token_id=#{current_principal.token.id}")
          end
        end
      end
    end
  end
end
