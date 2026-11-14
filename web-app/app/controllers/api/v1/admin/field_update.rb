# frozen_string_literal: true

module Api
  module V1
    module Admin
      # The PATCH of a book's or author's editable fields (update_book,
      # update_author). The controller declares its fields; this checks the body
      # and hands typed values to the shared admin save service, the same code the
      # edit page runs.
      #
      # Order of refusals: an empty body or a wrong JSON type is a 400, an unknown
      # key, enum name or language id is a 422 (the request is well formed but
      # names something that does not exist), and a failed model validation is a
      # 422 with the messages. Nothing is written unless every check passes.
      #
      # A field typed :year or :language_id, or :string_or_null (subtitle), is
      # clearable: null or "" sends it through as nil, and the service records
      # that a person blanked it on purpose.
      module FieldUpdate
        YEAR_RANGE = -3000..3000

        private

        # fields: {"name" => type}; enums: {"name" => [allowed names]};
        # service: responds to call(attrs:, user:, via:, explicit_nulls:, <record_key>:)
        def update_fields(record:, record_key:, fields:, enums:, clearable:, policy:, service:, resource:)
          return forbidden_update(record) unless policy.new(current_principal.user, record).update?

          body = json_body
          return bad_body("The body must be a JSON object with the fields to change.") if body.blank?

          unknown = body.keys - fields.keys
          if unknown.any?
            return render_problem(::Api::Problem.new(:unprocessable,
              detail: "Unknown field#{"s" if unknown.size > 1}: #{unknown.join(", ")}. Editable fields: #{fields.keys.join(", ")}."))
          end

          attrs = {}
          explicit_nulls = []
          body.each do |key, value|
            if clearable.include?(key) && ::ClearedField.blank_value?(value)
              attrs[key] = nil
              explicit_nulls << key
            else
              attrs[key] = typed_value!(key, value, fields.fetch(key))
            end
          end

          refusal = unknown_reference(attrs, enums)
          return render_problem(::Api::Problem.new(:unprocessable, detail: refusal)) if refusal

          result = service.call(record_key => record, :attrs => attrs, :user => current_principal.user,
            :via => Current.acting_via, :explicit_nulls => explicit_nulls)
          unless result.success?
            return render_problem(::Api::Problem.new(:unprocessable, detail: result.errors.join(", ")))
          end

          changed = result.data[:changed]
          log_update(record, changed)
          render json: {data: resource.new(record.reload).to_h, changed: changed}
        end

        # The JSON object as sent. Not request.request_parameters: ParamsWrapper
        # merges a copy of the body under a "book"/"author" key into it.
        def json_body
          parsed = JSON.parse(request.raw_post.to_s)
          parsed.is_a?(Hash) ? parsed : nil
        rescue JSON::ParserError
          nil
        end

        def typed_value!(key, value, type)
          case type
          when :string
            raise ::Api::Page::InvalidParameter, "#{key} must be a string" unless value.is_a?(String)
            no_nul!(key, value)
          when :string_or_null
            return nil if value.nil?
            raise ::Api::Page::InvalidParameter, "#{key} must be a string" unless value.is_a?(String)
            no_nul!(key, value)
            ::ClearedField.blank_value?(value) ? nil : value
          when :year
            unless value.is_a?(Integer) && YEAR_RANGE.cover?(value)
              raise ::Api::Page::InvalidParameter, "#{key} must be an integer from #{YEAR_RANGE.min} to #{YEAR_RANGE.max}"
            end
            value
          when :language_id
            raise ::Api::Page::InvalidParameter, "#{key} must be an integer" unless value.is_a?(Integer)
            value
          when :enum
            raise ::Api::Page::InvalidParameter, "#{key} must be a string" unless value.is_a?(String)
            value
          when :boolean
            raise ::Api::Page::InvalidParameter, "#{key} must be true or false" unless [true, false].include?(value)
            value
          when :strings
            unless value.is_a?(Array) && value.all?(String)
              raise ::Api::Page::InvalidParameter, "#{key} must be an array of strings"
            end
            value.each { |item| no_nul!(key, item) }
            value.map(&:strip).reject(&:empty?)
          end
        end

        def no_nul!(key, value)
          raise ::Api::Page::InvalidParameter, "#{key} must not contain a null byte" if value.include?("\u0000")

          value
        end

        # An enum name that does not exist, or a language id with no row.
        def unknown_reference(attrs, enums)
          enums.each do |key, allowed|
            next unless attrs.key?(key) && !allowed.include?(attrs[key])

            return "#{key} must be one of #{allowed.join(", ")}."
          end
          if attrs["original_language_id"] && !::Language.exists?(id: attrs["original_language_id"])
            return "original_language_id #{attrs["original_language_id"]} is not a language."
          end

          nil
        end

        def bad_body(detail)
          render_problem(::Api::Problem.new(:invalid_parameter, detail: detail))
        end

        def forbidden_update(record)
          render_problem(::Api::Problem.new(:forbidden, detail: "Your account may not edit #{record.class.model_name.human.downcase} #{record.id}."))
        end

        # Field names only, never the values.
        def log_update(record, changed)
          Rails.logger.info("event=api_admin_field_update changed=#{changed.join(",")} token_id=#{current_principal.token.id} " \
            "token_kind=#{current_principal.token_kind} user_id=#{current_principal.user.id} " \
            "record_type=#{record.class.name} record_id=#{record.id}")
        end
      end
    end
  end
end
