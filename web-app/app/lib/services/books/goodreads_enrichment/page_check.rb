# frozen_string_literal: true

module Services
  module Books
    module GoodreadsEnrichment
      # Re-checks the fetched Goodreads page before anything is written (spec
      # §4.4): the search row can look right and the page still be a study
      # guide, an omnibus or an adaptation.
      #
      # The title check is strict on purpose: the titles must agree (Amazon's
      # same_book? rule), not merely have one contain the other. A book with a
      # known Goodreads id skips PickCandidate, so this is the only gate between
      # a wrong id (a sequel by the same author, "Dune" vs "Dune Messiah") and
      # the write. CandidateFilter's loose containment stays for search rows,
      # where the AI pick and this check still follow.
      class PageCheck
        Verdict = Data.define(:ok, :reason)

        STUDY_AID_GENRE = /study (guide|aid)s?|summar(y|ies)/i
        POSITION_RANGE = /\d\s*[-–]\s*\d/

        def self.call(book:, page:)
          new(book: book, page: page).call
        end

        def initialize(book:, page:)
          @book = book
          @page = page
        end

        def call
          title = @page.title.to_s
          return reject(:author_mismatch) unless CandidateFilter.authors_agree?(@book, author_names)
          return reject(:title_mismatch) unless title_agrees?(title)
          return reject(:derivative) unless CandidateFilter.derivative_free?(@book, title)
          return reject(:study_aid) if Array(@page.genres).any? { |genre| genre.to_s.match?(STUDY_AID_GENRE) }
          return reject(:set) unless CandidateFilter.set_free?(@book, title)
          return reject(:set) if Array(@page.series).any? { |entry| entry["position"].to_s.match?(POSITION_RANGE) }

          Verdict.new(ok: true, reason: nil)
        end

        private

        def title_agrees?(title)
          listing = AmazonBookCheck::Listing.new(*AmazonBookCheck.split_title(title))
          Verification::EditionCheck.title_agrees?(@book, nil, listing)
        end

        # Creators only; a page whose contributors carry no role at all is
        # judged on everyone it lists rather than on nobody.
        def author_names
          contributors = @page.contributors
          creators = contributors.select(&:creator?)
          (creators.presence || contributors).map(&:name)
        end

        def reject(reason) = Verdict.new(ok: false, reason: reason.to_s)
      end
    end
  end
end
