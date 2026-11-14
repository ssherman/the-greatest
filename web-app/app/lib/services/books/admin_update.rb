# frozen_string_literal: true

module Services
  module Books
    # The one save an admin makes on a book's editable fields. The edit page and
    # the admin API both call it, so the two cannot drift. Callers pass typed
    # values; original_language_id, when present, must name an existing Language.
    #
    # Everything runs in one transaction. Besides saving, it keeps the
    # cleared_fields rows honest: a clearable field that went from present to
    # blank gets a row (enrichment then leaves it blank); a field that is present
    # again loses its row. explicit_nulls names clearable fields the caller asked
    # to blank even though they already were, so they get a row too.
    #
    # attrs is partial on purpose: keys not in it, alternate titles included,
    # are left alone. The alternate_titles key is written through
    # Services::AlternateTitles::Writer; every other key is assigned.
    class AdminUpdate
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(book:, attrs:, user:, via:, explicit_nulls: [])
        persist(record: book, attrs: attrs, user: user, via: via, explicit_nulls: explicit_nulls)
      end

      # Shared with Services::Books::Authors::AdminUpdate.
      def self.persist(record:, attrs:, user:, via:, explicit_nulls:)
        attrs = attrs.to_h.stringify_keys
        titles = attrs.delete("alternate_titles")
        clearable = ::ClearedField::CLEARABLE.fetch(record.class.name)
        explicit = Array(explicit_nulls).map(&:to_s) & clearable
        before = attrs.keys.index_with { |key| record.public_send(key) }
        before["alternate_titles"] = record.alternate_titles if titles
        before_blank = clearable.index_with { |field| ::ClearedField.blank_value?(record.public_send(field)) }

        result = nil
        record.class.transaction do
          record.assign_attributes(attrs)
          unless record.save
            raise ActiveRecord::Rollback
          end
          if titles
            Services::AlternateTitles::Writer.replace(record: record, titles: titles, source: :admin, user: user)
            record.save! if record.changed?
          end
          clearable.each do |field|
            blank_now = ::ClearedField.blank_value?(record.public_send(field))
            if blank_now && (!before_blank[field] || explicit.include?(field))
              record.cleared_fields.find_or_create_by!(field_name: field) do |row|
                row.cleared_by = user
                row.cleared_via = via
              end
            elsif !blank_now
              record.cleared_fields.where(field_name: field).delete_all
            end
          end
          changed = before.keys.reject { |key| before[key] == record.public_send(key) }
          result = Result.new(success?: true, data: {record: record, changed: changed}, errors: [])
        end

        result || Result.new(success?: false, data: {code: :invalid, record: record}, errors: record.errors.full_messages)
      end
    end
  end
end
