# frozen_string_literal: true

module Api
  module V1
    module Admin
      module Books
        # Body parsing and rendering shared by the series write endpoints (SeriesController,
        # SeriesBooksController). Bodies are read raw, so an explicit null survives, and
        # every value is typed here: the services in Services::Books::SeriesEdits receive
        # string-keyed attrs they can trust. A wrong JSON type is a 400 (it raises
        # ::Api::Page::InvalidParameter); a well-formed value the services refuse is a 422.
        # Root-anchor every ::Books:: reference in this namespace.
        module SeriesWrites
          include ::Api::V1::Admin::StrictIds
          include ::Api::JsonBody

          # decimal(8,2)
          MAX_POSITION = BigDecimal("999999.99")

          private

          def find_series
            series = ::Books::Series.find_by(id: params[:id])
            render_problem(::Api::Problem.new(:not_found, detail: "No series #{params[:id]}.")) unless series
            series
          end

          def render_forbidden(detail = "Your account may not change series.")
            render_problem(::Api::Problem.new(:forbidden, detail: detail))
          end

          def refuse(result)
            code = (result.code == :not_found) ? :not_found : :unprocessable
            render_problem(::Api::Problem.new(code, detail: result.errors.join(", ")))
          end

          def render_series(series, status: :ok)
            render status: status, json: {data: SeriesDetailResource.new(::Books::Series.find(series.id)).to_h}
          end

          def log_series(action, series_id, extra = "")
            Rails.logger.info("event=api_admin_series_#{action} outcome=succeeded token_id=#{current_principal.token.id} " \
              "token_kind=#{current_principal.token_kind} user_id=#{current_principal.user.id} series_id=#{series_id}#{extra}")
          end

          def typed_string!(key, value, nullable: false)
            return nil if nullable && value.nil?
            raise ::Api::Page::InvalidParameter, "#{key} must be a string#{" or null" if nullable}" unless value.is_a?(String)
            raise ::Api::Page::InvalidParameter, "#{key} must not contain a null byte" if value.include?("\u0000")

            value
          end

          # A JSON integer or float with at most 2 decimals inside decimal(8,2), or null.
          def typed_position!(value)
            return nil if value.nil?

            unless value.is_a?(Integer) || value.is_a?(Float)
              raise ::Api::Page::InvalidParameter, "position must be a number or null"
            end
            number = BigDecimal(value.to_s)
            unless number.abs <= MAX_POSITION && number.round(2) == number
              raise ::Api::Page::InvalidParameter, "position must have at most 2 decimals and lie between -999999.99 and 999999.99"
            end

            number
          end

          def typed_boolean!(key, value)
            raise ::Api::Page::InvalidParameter, "#{key} must be true or false" unless [true, false].include?(value)

            value
          end
        end
      end
    end
  end
end
