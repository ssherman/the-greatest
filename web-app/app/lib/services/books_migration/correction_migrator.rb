module Services
  module BooksMigration
    # Legacy `changesets` -> `corrections` + `correction_fields`.
    #
    # Legacy ids are PRESERVED, below the reserved ceiling (RESERVED_CEILINGS). That
    # buys idempotency -- a re-run collides on the pkey and ON CONFLICT DO NOTHING
    # absorbs it -- and traceability back to the legacy row. Book ids and user ids
    # are already preserved by BookMigrator and UserMigrator, so both map 1:1.
    #
    # NOT an InsertOnlyMigrator subclass: this writes two tables per legacy row and
    # needs the parent's id in hand to write the children, which the batching base
    # does not model. It uses insert_all directly for the same
    # callbacks-and-validations-bypassed reason -- notably, no correction email.
    #
    # The parent and child inserts run inside one `Correction.transaction` (see
    # upsert_row) so a process death between them can never leave a correction
    # committed with no fields -- and the child insert is always attempted, even
    # when the parent's insert_all reports zero rows (already migrated), so a
    # re-run recovers a row that WAS left partial before this transaction existed.
    #
    # ::Books, ::Correction and ::CorrectionField are root-anchored: Services::Books
    # exists, so a bare Books::Book here resolves to Services::Books::Book.
    class CorrectionMigrator < Migrator
      # Legacy column name => this app's declared field name. Absent from this map
      # and not a declared field => folded into the notes.
      FIELD_RENAMES = {
        "sub_title" => "subtitle",
        "first_year_published" => "first_published_year"
      }.freeze

      LEGACY_STATUS_APPLIED = 3

      # PUBLIC, deliberately. Migrator.call is `new.call`, so a private #call here
      # raises NoMethodError before a single row is read. Migrator (unlike
      # BulkUpsertMigrator) has no preload_context hook -- it goes straight from
      # legacy_each to upsert_row -- so this override is what runs it.
      def call
        preload_context
        super
      end

      private

      def legacy_model
        LegacyBooks::Changeset
      end

      def model_key
        "Correction"
      end

      def preload_context
        @book_ids = ::Books::Book.pluck(:id).to_set
        @user_ids = ::User.pluck(:id).to_set
        @declared = ::Books::Book.correctable_field_names.to_set
        @route = BookRoute.new(sync, book_ids_here: @book_ids) if sync
        @stats = {inserted: 0, dropped: 0, waiting: 0, missing: 0}
      end

      def extra_result_data
        sync ? @stats : {}
      end

      # insert_all with explicit ids never advances the sequence, so without this the
      # first correction a real visitor submits collides -- and it must sit at the
      # reserved ceiling, not max + 1, or new corrections take ids legacy will use.
      def finalize
        Services::BooksMigration.bump_sequence_to_floor!("corrections")
      end

      def upsert_row(attrs)
        Services::BooksMigration.raise_if_at_ceiling!("corrections", attrs["id"])

        book_id = target_book_id(attrs)
        return if book_id.nil?

        mappable, unmappable = partition_change_data(attrs["change_data"])
        applied = attrs["status"] == LEGACY_STATUS_APPLIED

        # One transaction for both inserts, and the child insert is ALWAYS attempted
        # (not gated on the parent's insert_all reporting a row). Two separate
        # statements with an early return on "parent reported 0 rows" -- the earlier
        # version of this method -- meant a process death between them committed the
        # parent with no children, and a later re-run's ON CONFLICT DO NOTHING on the
        # parent (0 rows, "already migrated") skipped the children forever, with no
        # way to recover. Children carry their own UNIQUE (correction_id, field_name)
        # index and unique_by: nil, so re-attempting them is a no-op once they exist
        # and a real recovery when they don't.
        ::Correction.transaction do
          if sync && !@route.lock([book_id])
            # A merge or delete committed since this run started, and route.lock
            # reloaded the redirects: route the book again.
            book_id = target_book_id(attrs)
            next if book_id.nil?
            raise "Books::Book #{book_id} vanished twice mid-run; re-run the sync" unless @route.lock([book_id])
          end

          inserted = ::Correction.insert_all(
            [correction_row(attrs, book_id, unmappable, applied)],
            unique_by: nil, record_timestamps: false
          )
          @stats[:inserted] += inserted.length

          next if mappable.empty?

          ::CorrectionField.insert_all(
            mappable.map { |name, change| field_row(attrs, name, change, applied) },
            unique_by: nil, record_timestamps: false
          )
        end
      end

      # The book the correction lands on, or nil to skip it (counted). Sync mode
      # routes it through redirects (spec §6): a deleted book drops it, and a book
      # still inside the delay makes it wait; this migrator is insert-only, so a
      # later run picks it up. A book that is simply not here is skipped in both
      # modes, not raised -- a departure from ReviewMigrator's fail-loud rule: two
      # legacy changesets point at books legacy itself deleted, and a correction
      # for a deleted book has nothing to correct.
      def target_book_id(attrs)
        book_id = attrs["changeable_id"]
        routed = if sync
          @route.call(book_id)
        else
          @book_ids.include?(book_id) ? book_id : :missing
        end
        return routed if routed.is_a?(Integer)

        @stats[(routed == :deleted) ? :dropped : routed] += 1
        if routed == :missing
          Rails.logger.warn("CorrectionMigrator: skipped legacy changeset id=#{attrs["id"]}, no Books::Book #{book_id}")
        end
        nil
      end

      def correction_row(attrs, book_id, unmappable, applied)
        {
          id: attrs["id"],
          correctable_type: "Books::Book",
          correctable_id: book_id,
          user_id: @user_ids.include?(attrs["user_id"]) ? attrs["user_id"] : nil,
          notes: notes_with_unmappable(attrs["notes"], unmappable),
          status: applied ? ::Correction.statuses[:resolved] : ::Correction.statuses[:pending],
          resolved_at: applied ? attrs["applied_at"] : nil,
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }
      end

      def field_row(attrs, name, change, applied)
        {
          correction_id: attrs["id"],
          field_name: name,
          old_value: change["from"],
          new_value: change["to"],
          status: applied ? ::CorrectionField.statuses[:applied] : ::CorrectionField.statuses[:pending],
          applied_at: applied ? attrs["applied_at"] : nil,
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        }
      end

      # series_name, series_number, series and original_language are associations in
      # this app, not columns, so there is nothing for the applier to write. Folding
      # them into the notes keeps the proposal visible and actionable by hand rather
      # than silently discarding 103 field proposals.
      def partition_change_data(change_data)
        renamed = (change_data || {}).to_h do |legacy_name, change|
          [FIELD_RENAMES.fetch(legacy_name, legacy_name), change]
        end

        renamed.partition { |name, _| @declared.include?(name) }.map(&:to_h)
      end

      def notes_with_unmappable(notes, unmappable)
        return notes.presence if unmappable.empty?

        lines = unmappable.map do |name, change|
          "  #{name.humanize}: #{change["from"].inspect} -> #{change["to"].inspect}"
        end

        [notes.presence, "From the old site — these could not be applied automatically:", *lines]
          .compact.join("\n")
      end
    end
  end
end
