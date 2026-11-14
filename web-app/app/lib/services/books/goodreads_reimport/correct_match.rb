# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      # A reviewer's answer to a reimport_match verdict the AI got wrong: this book, or create a new one. Approve and
      # reject alone left no way to say which book is right, and a rejected match is final (MatchEdition never matches
      # it again, DecideRow leaves its rows and their legacy book's other rows waiting), so a wrong pick stranded
      # readers. The correction becomes the verdict's answer, approved by the reviewer; apply and decide then treat it
      # like any approved match. The AI's own answer stays in payload["ai"], and what the verdict said before is kept
      # in payload["corrected"].
      #
      # Only an unapplied, current match can be corrected: once apply has written it (or created its book), readers
      # may already be deciding against it. A rejected one can, which is how its waiting rows get moving again.
      class CorrectMatch
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(verdict:, user:, book_id: nil, create: false, via: "admin_ui")
          new(verdict: verdict, user: user, book_id: book_id, create: create, via: via).call
        end

        def initialize(verdict:, user:, book_id:, create:, via:)
          @verdict = verdict
          @via = via
          @user = user
          @book_id = book_id.presence&.to_i
          @create = ActiveModel::Type::Boolean.new.cast(create) || false
        end

        def call
          return failure("Give either a book id or create a new book, not both or neither") if @book_id.nil? == !@create

          book = nil
          unless @create
            book = GoodreadsReplay::Apply::MergedBook.call(@book_id)
            return failure("There is no book ##{@book_id}") unless book
          end

          @verdict.with_lock do
            reason = refusal
            next failure(reason) if reason

            payload = @verdict.payload.merge(
              "outcome" => @create ? "create" : "matched", "book_id" => book&.id,
              "corrected" => {"outcome" => @verdict.payload["outcome"], "book_id" => @verdict.payload["book_id"], "status" => @verdict.status,
                              "by_user_id" => @user.id, "at" => Time.current.iso8601}
            )
            @verdict.update!(payload: payload, status: :approved, reviewed_at: Time.current, decided_by_user_id: @user.id,
              reviewed_via: @via)
            Result.new(success?: true, data: {verdict: @verdict}, errors: [])
          end
        end

        private

        def refusal
          return "Only a re-import match can be corrected" unless @verdict.reimport_match?
          return "This match was replaced by a newer one" if @verdict.superseded_at.present?
          return "This match was already applied" if @verdict.applied_at.present? || @verdict.payload["created_book_id"].present?
          # Apply::Match writes edition_before under the same lock as it starts: from then on it is applying the old answer.
          return "This match is being applied; it cannot be corrected now" if @verdict.payload.key?("edition_before")

          nil
        end

        def failure(message) = Result.new(success?: false, data: {}, errors: [message])
      end
    end
  end
end
