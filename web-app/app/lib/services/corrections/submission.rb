module Services
  module Corrections
    # Turns a submitted form into a Correction plus one CorrectionField per value
    # that actually moved.
    #
    # The submitter's browser sends what it believes the current values to be, but
    # `old_value` is read from the RECORD here, never from the submission. A cached
    # form page can be up to 24 hours stale, and trusting its idea of "from" is how
    # a correction ends up claiming a change that never happened.
    class Submission
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(record:, field_params:, notes:, user: nil, submitter_ip: nil)
        new(record: record, field_params: field_params, notes: notes,
          user: user, submitter_ip: submitter_ip).call
      end

      def initialize(record:, field_params:, notes:, user:, submitter_ip:)
        @record = record
        @field_params = field_params || {}
        @notes = notes
        @user = user
        @submitter_ip = submitter_ip
      end

      def call
        fields, oversized = collect_fields

        # REJECTED, never truncated. Silently storing half of what someone typed
        # is how an admin ends up applying a sentence that stops mid-word, and the
        # submitter has no way to know it happened. The controller renders these
        # through the same inline @error the model's own validation errors use.
        return Result.new(success?: false, data: nil, errors: oversized) if oversized.any?

        correction = ::Correction.new(
          correctable: @record, user: @user, notes: @notes, submitter_ip: @submitter_ip
        )
        fields.each { |attrs| correction.correction_fields.build(**attrs) }

        if correction.save
          Result.new(success?: true, data: correction, errors: [])
        else
          Result.new(success?: false, data: nil, errors: correction.errors.full_messages)
        end
      end

      private

      # Undeclared keys are dropped silently rather than rejected: the form only
      # renders declared fields, so anything else is either a stale cached page from
      # before a field was removed, or someone poking at the endpoint. Neither is
      # worth an error the submitter cannot act on.
      #
      # Returns [fields that moved, size errors]. The size check runs BEFORE the
      # cast, and on every submitted field rather than only the ones that moved:
      # before the cast because that is what stops ValueCaster walking a
      # million-element array in the first place, and on every field because the
      # caps (see Correction) are set well above the largest value any real record
      # holds, so a prefilled input the submitter never touched cannot trip one.
      def collect_fields
        fields = []
        errors = []

        @record.class.correctable_fields.each do |name, definition|
          next unless @field_params.key?(name)

          error = size_error(name, definition)
          if error
            errors << error
            next
          end

          target = Targets.for(definition.target)
          current = ValueCaster.call(target.read(@record, name), type: definition.type)
          proposed = ValueCaster.call(@field_params[name], type: definition.type)
          next if current == proposed

          # A target that cannot write a blank must not accept a blank proposal:
          # storing one produces a correction the admin can only ever reject,
          # because applying it would report success while changing nothing.
          # Told to the submitter rather than dropped, so clearing the box is not
          # silently ignored.
          if proposed.blank? && !target.accepts_blank?
            errors << "#{definition.label} cannot be cleared here — please describe the problem in the notes instead"
            next
          end

          fields << {field_name: name, old_value: current, new_value: proposed}
        end

        [fields, errors]
      end

      def size_error(name, definition)
        raw = @field_params[name]

        if definition.type == :string_array
          values = Array(raw)

          if values.size > ::Correction::MAX_ARRAY_ELEMENTS
            return "#{definition.label} has too many entries (maximum is #{::Correction::MAX_ARRAY_ELEMENTS})"
          end

          return nil if values.none? { |value| value.to_s.length > ::Correction::MAX_FIELD_VALUE_LENGTH }

          return "#{definition.label} has an entry that is too long " \
            "(maximum is #{::Correction::MAX_FIELD_VALUE_LENGTH} characters)"
        end

        limit = (definition.type == :text) ? ::Correction::MAX_TEXT_VALUE_LENGTH : ::Correction::MAX_FIELD_VALUE_LENGTH
        return nil if raw.to_s.length <= limit

        "#{definition.label} is too long (maximum is #{limit} characters)"
      end
    end
  end
end
