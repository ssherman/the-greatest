module Services
  module Corrections
    # Writes an admin's accepted fields onto the record and closes the correction.
    #
    # `accepted` maps field name to the value to WRITE, which is not necessarily the
    # value that was submitted -- the review form lets an admin correct a near-miss
    # in place. A declared field absent from `accepted` is rejected. There is no
    # third outcome: leaving a field pending on a resolved correction would make the
    # queue lie about what is left to do.
    #
    # ::Correction and ::Books are root-anchored -- Services::Books exists, so a bare
    # Books::Book here resolves to Services::Books::Book and raises NameError.
    class Applier
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(correction:, accepted:, admin:)
        new(correction: correction, accepted: accepted || {}, admin: admin).call
      end

      def initialize(correction:, accepted:, admin:)
        @correction = correction
        @accepted = accepted
        @admin = admin
      end

      def call
        unless @correction.pending?
          return failure(["This correction has already been resolved or rejected"])
        end

        ::Correction.transaction do
          apply_fields
          @record.save!
          resolve_correction
        end

        Result.new(success?: true, data: @correction.reload, errors: [])
      rescue ActiveRecord::RecordInvalid => e
        # The record's real validation errors, not legacy's single generic
        # "Failed to apply changes" -- an admin cannot fix what they cannot see.
        failure(e.record.errors.full_messages)
      end

      private

      def apply_fields
        @record = @correction.correctable
        applied_names = []

        @correction.correction_fields.each do |field|
          # [] with a nil guard, NOT fetch. insert_all in the legacy migrator
          # bypasses validations, and a declaration removed later (say, dropping
          # word_count) strands already-submitted rows -- fetch would turn both
          # into a KeyError 500 in the admin, on data the admin cannot fix.
          definition = @record.class.correctable_fields[field.field_name]

          # Undeclared: checked first and unconditionally, before @accepted is even
          # consulted. field_name_is_declared has no `on:` guard, so a plain
          # update! here would re-validate the very row we are rejecting BECAUSE
          # it is invalid and raise -- reject_field's validate: false is the only
          # thing standing between this branch and that crash.
          if definition.nil?
            reject_field(field)
            next
          end

          unless @accepted.key?(field.field_name)
            field.update!(status: :rejected)
            next
          end

          value = ValueCaster.call(@accepted[field.field_name], type: definition.type)
          Targets.for(definition.target).write(@record, field.field_name, value)

          field.update!(status: :applied, new_value: value, applied_at: Time.current)
          applied_names << field.field_name
        end

        # Before save!, so a cleared derived column re-derives in the same write.
        @record.correction_applied(applied_names)
      end

      # Only the undeclared-field branch above calls this. validate: false is
      # deliberate there: a stranded row's field_name is exactly what makes
      # CorrectionField#field_name_is_declared fail, so a validating save on this
      # row cannot ever succeed. Every other rejection (declared field the admin
      # didn't accept) goes through the ordinary update! and keeps full validation
      # -- CorrectionField's own validations are defence in depth for the field
      # rows an agent will write through this service later, and only this one
      # branch has a reason to bypass them.
      def reject_field(field)
        field.status = :rejected
        field.save!(validate: false)
      end

      def resolve_correction
        @correction.update!(status: :resolved, resolved_by: @admin, resolved_at: Time.current)
      end

      def failure(errors)
        Result.new(success?: false, data: nil, errors: errors)
      end
    end
  end
end
