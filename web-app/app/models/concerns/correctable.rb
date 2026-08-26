# The contract shared correction code depends on. Corrections are polymorphic
# through `correctable` and there is no per-domain Correction subclass to hang
# behaviour on, so each correctable class declares what the shared code needs.
#
# Same shape as Reviewable and Describable. Unlike Reviewable, nothing here
# raises NotImplementedError: a model that includes this and declares no fields
# is a legitimate state (it accepts free-text notes and nothing else).
module Correctable
  extend ActiveSupport::Concern

  # The declared `type` does three jobs at once: it is the allowlist entry, the
  # cast rule, and the choice of form input. Legacy derived all three by
  # pattern-matching `columns_hash[field].sql_type_metadata.sql_type` at runtime,
  # logged an error on anything it did not recognise, and silently dropped the
  # field. Declaring it is shorter and cannot drift from the column.
  FieldDefinition = Struct.new(:name, :type, :target, :label, :hint, keyword_init: true)

  TYPES = %i[string text integer string_array].freeze
  TARGETS = %i[column description].freeze

  included do
    has_many :corrections, as: :correctable, dependent: :destroy
    class_attribute :correctable_fields, default: {}.freeze
  end

  class_methods do
    def correctable_field(name, type:, target: :column, label: nil, hint: nil)
      unless Correctable::TYPES.include?(type)
        raise ArgumentError, "unknown correctable type #{type.inspect} (one of #{Correctable::TYPES.join(", ")})"
      end
      unless Correctable::TARGETS.include?(target)
        raise ArgumentError, "unknown correctable target #{target.inspect} (one of #{Correctable::TARGETS.join(", ")})"
      end

      definition = Correctable::FieldDefinition.new(
        name: name.to_s,
        type: type,
        target: target,
        label: label || name.to_s.humanize,
        hint: hint
      )

      # merge, never mutate: class_attribute's default hash is one object shared
      # by every including class, so `correctable_fields[k] = v` would add this
      # field to every other correctable model in the app.
      self.correctable_fields = correctable_fields.merge(definition.name => definition).freeze
    end

    def correctable_field_names
      correctable_fields.keys
    end
  end

  # Called by the applier after accepted fields are written and before the record
  # is saved, with the applied field names. Override to clear a derived column
  # that a corrected input feeds. No-op by default.
  def correction_applied(field_names)
  end
end
