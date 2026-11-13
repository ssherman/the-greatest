# frozen_string_literal: true

module Services
  module Descriptions
    # The four writes an admin makes on a record's descriptions: add, edit,
    # delete, and mark one preferred. The admin page and the admin API both call
    # this, so the two cannot drift.
    #
    # Rules that belong to one caller (the API's Wikipedia source_url and license
    # default) stay with that caller: this is the page's behaviour, nothing more.
    #
    # A failed create/update carries data[:code]: :invalid (a validation) or
    # :conflict (another description already holds this source for the record,
    # kind and locale; data[:existing_id] names it). data[:description] is always
    # the record, so a caller can read its errors.
    class AdminWrite
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      FIELDS = %w[content source source_name source_url license].freeze

      # attrs: content, source, source_name, source_url, license. Kind, locale and
      # rank are forced here (summary, en, normal) and never taken from attrs; only
      # set_preferred changes a rank.
      def self.create(describable:, attrs:)
        description = describable.descriptions.build(attrs.to_h.stringify_keys.slice(*FIELDS))
        description.kind = :summary
        description.locale = "en"
        description.rank = :normal
        persist(description)
      end

      def self.update(description:, attrs:)
        description.assign_attributes(attrs.to_h.stringify_keys.slice(*FIELDS))
        persist(description)
      end

      def self.destroy(description:)
        description.destroy!
        Result.new(success?: true, data: {description: description}, errors: [])
      end

      # Demote-then-promote in a transaction. This cannot mirror Image's after_save
      # promote-first callback: the partial unique index index_descriptions_one_preferred_per_key
      # rejects two preferred rows for the same (describable, kind, locale) mid-callback.
      def self.set_preferred(description:)
        ::Description.transaction do
          ::Description
            .where(describable_type: description.describable_type,
              describable_id: description.describable_id,
              kind: description.kind, locale: description.locale, rank: :preferred)
            .where.not(id: description.id)
            .update_all(rank: 0)
          description.update!(rank: :preferred)
        end
        Result.new(success?: true, data: {description: description}, errors: [])
      end

      def self.persist(description)
        return Result.new(success?: true, data: {description: description}, errors: []) if description.save

        failure(description)
      rescue ActiveRecord::RecordNotUnique
        # A concurrent add won the race past the uniqueness validation.
        description.errors.add(:source, :taken)
        failure(description)
      end
      private_class_method :persist

      def self.failure(description)
        existing_id = existing_id_for(description) if description.errors.of_kind?(:source, :taken)
        data = {description: description, code: existing_id ? :conflict : :invalid}
        data[:existing_id] = existing_id if existing_id
        Result.new(success?: false, data: data, errors: description.errors.full_messages)
      end
      private_class_method :failure

      def self.existing_id_for(description)
        ::Description
          .where(describable_type: description.describable_type, describable_id: description.describable_id,
            kind: description.kind, locale: description.locale, source: description.source,
            source_name: description.source_name)
          .where.not(id: description.id)
          .pick(:id)
      end
      private_class_method :existing_id_for
    end
  end
end
