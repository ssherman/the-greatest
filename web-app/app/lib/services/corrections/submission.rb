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
        correction = ::Correction.new(
          correctable: @record, user: @user, notes: @notes, submitter_ip: @submitter_ip
        )
        moved_fields.each { |attrs| correction.correction_fields.build(**attrs) }

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
      def moved_fields
        @record.class.correctable_fields.filter_map do |name, definition|
          next unless @field_params.key?(name)

          target = Targets.for(definition.target)
          current = ValueCaster.call(target.read(@record, name), type: definition.type)
          proposed = ValueCaster.call(@field_params[name], type: definition.type)
          next if current == proposed

          {field_name: name, old_value: current, new_value: proposed}
        end
      end
    end
  end
end
