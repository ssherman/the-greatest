module Services
  module BooksMigration
    # Writes record_redirects (spec §4). Every book merge and delete gets a row,
    # whatever the id: a ranking archive stores book ids and resolves a merged or
    # deleted one through this table. An author gets a row only when it is
    # legacy-origin (id below its table's ceiling), since nothing else reads one.
    # Rows already pointing AT the departing record are repointed whatever its id,
    # so a legacy book merged into a new-app book still resolves after that book
    # is merged or deleted in turn.
    class RedirectRecorder
      TABLES = {"Books::Book" => "books_books", "Books::Author" => "books_authors"}.freeze

      # A merge overwrites any row already there: it is the more specific fate.
      def self.merged(item_type:, from_id:, to_id:)
        repoint(item_type, from_id, to_id)
        # The survivor is alive by definition. A row naming it as its own target
        # (it had been merged away, then came back with a weekly :all) would read
        # as a cycle on every sync.
        RecordRedirect.where(item_type: item_type, from_id: to_id).delete_all
        return unless recordable?(item_type, from_id)

        RecordRedirect.upsert({item_type: item_type, from_id: from_id, to_id: to_id}, unique_by: [:item_type, :from_id])
      end

      # ON CONFLICT DO NOTHING: a merger records its row before destroying the
      # source, and the destroy that follows must not turn it into a delete.
      def self.deleted(item_type:, from_id:)
        repoint(item_type, from_id, nil)
        return unless recordable?(item_type, from_id)

        RecordRedirect.insert({item_type: item_type, from_id: from_id, to_id: nil}, unique_by: [:item_type, :from_id])
      end

      def self.legacy_origin?(item_type, id)
        id.to_i < RESERVED_CEILINGS.fetch(TABLES.fetch(item_type))
      end

      def self.repoint(item_type, from_id, to_id)
        RecordRedirect.where(item_type: item_type, to_id: from_id).update_all(to_id: to_id, updated_at: Time.current)
      end

      def self.recordable?(item_type, id)
        item_type == "Books::Book" || legacy_origin?(item_type, id)
      end

      private_class_method :repoint, :recordable?
    end
  end
end
