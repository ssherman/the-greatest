# frozen_string_literal: true

module Services
  module Books
    module Authors
      # After the pre-launch re-migration an author row is re-created with
      # its id, and the Wikidata and VIAF ids earlier runs stamped are gone:
      # the migrator brings back only Open Library keys. Their decisions and
      # stored records survive (spec §14). Before a run resolves, this puts
      # back the id its step's latest decision chose, so the resolver's
      # held-id stage finds it and the stored record answers, with no search
      # and no AI selection.
      #
      # Only a decision a person would stand behind comes back: the step's
      # latest, older than the author row, matched, not rejected, and either
      # never flagged for review or reviewed since. An author already
      # holding an id of that type, an id rejected for this author, or one
      # another author holds gets nothing. Returns the ledger fact, or nil.
      class RestoreIdentifier
        TYPES = {
          "Services::Books::Authors::ResolveWikidata" => "books_author_wikidata_qid",
          "Services::Books::Authors::ResolveViaf" => "books_author_viaf"
        }.freeze

        def self.call(author:, finder:)
          new(author: author, finder: finder.to_s).call
        end

        def initialize(author:, finder:)
          @author = author
          @finder = finder
          @type = TYPES.fetch(finder)
        end

        def call
          return nil if @author.identifiers.any? { |identifier| identifier.identifier_type == @type }

          decision = ::MatchDecision.where(subject: @author, finder: @finder).order(created_at: :desc, id: :desc).first
          return nil unless carried_over?(decision)

          value = decision.selected_candidate&.dig("external_key").to_s
          return nil if value.blank? || RejectedRecords.new(@author).identifier?(@type, value)
          return nil if ::Identifier.where(identifiable_type: "Books::Author", identifier_type: @type, value: value).exists?

          @author.identifiers.create!(identifier_type: @type, value: value)
          {"value" => value, "applied" => true, "reason" => "earlier_decision", "decision_id" => decision.id}
        end

        private

        def carried_over?(decision)
          decision.present? && decision.matched? && !decision.verdict_rejected? &&
            decision.created_at < @author.created_at && (!decision.needs_review || decision.reviewed_at.present?)
        end
      end
    end
  end
end
