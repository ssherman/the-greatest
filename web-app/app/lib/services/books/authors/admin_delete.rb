# frozen_string_literal: true

module Services
  module Books
    module Authors
      # Deletes an author that nothing uses any more: no book credits it (book_authors) and no edition or book
      # credits it as translator, editor and the like (credits). A merge or a split of mixed records leaves such
      # records behind. Anyone still credited is refused: folding a real person into another record is
      # merge_author's job, which keeps a redirect from the old page. The author's own rows (identifiers,
      # descriptions, images, categories) go with it, and the model's after_destroy records the delete in
      # record_redirects, so the weekly legacy sync does not bring a legacy-origin author back.
      #
      # Failures carry code :unprocessable. data[:author] is the author (destroyed after a real delete).
      class AdminDelete
        Result = Struct.new(:success?, :data, :errors, :code, keyword_init: true)

        def self.call(author:, dry_run: false)
          new(author, dry_run).call
        end

        def initialize(author, dry_run)
          @author = author
          @dry_run = dry_run
        end

        def call
          reason = refusal
          return refused(reason) if reason
          return success if @dry_run

          ::Books::Author.transaction do
            # Re-read under the lock: a book may have been linked since the check above.
            @author.lock!
            reason = refusal
            raise ActiveRecord::Rollback if reason

            @author.destroy!
          end
          reason ? refused(reason) : success
        end

        private

        def refusal
          books = ::Books::BookAuthor.where(author_id: @author.id).count
          if books.positive?
            return "Author #{@author.id} is credited on #{books} book#{"s" unless books == 1}. Only an author with no books " \
              "and no credits can be deleted; to fold a duplicate into the right person, use merge_author."
          end

          credits = ::Books::Credit.where(author_id: @author.id).count
          return unless credits.positive?

          "Author #{@author.id} holds #{credits} credit#{"s" unless credits == 1} (translator, editor and the like). Only an " \
            "author with no books and no credits can be deleted; to fold a duplicate into the right person, use merge_author."
        end

        def success = Result.new(success?: true, data: {author: @author}, errors: [])

        def refused(reason) = Result.new(success?: false, data: {author: @author}, errors: [reason], code: :unprocessable)
      end
    end
  end
end
