module Services
  module Corrections
    # Casts a submitted form value to the type its field declared. The submission
    # service uses this on the way in (so a proposal is compared against the
    # current value in the same representation), and the applier uses it again on
    # the way out (the admin may have edited the value in the review form).
    class ValueCaster
      def self.call(value, type:)
        case type
        when :string, :text
          value.to_s.strip.presence
        when :integer
          cast_integer(value)
        when :string_array
          Array(value).map { |element| element.to_s.strip }.reject(&:blank?).uniq
        else
          raise ArgumentError, "unknown correction field type: #{type.inspect}"
        end
      end

      # Integer(..., exception: false), never to_i. to_i turns "not a year" into 0
      # -- which legacy then wrote to first_published_year on apply, silently. nil
      # is the honest answer for garbage, and it is distinguishable from a real 0.
      def self.cast_integer(value)
        return nil if value.blank?

        Integer(value.to_s.strip, exception: false)
      end
      private_class_method :cast_integer
    end
  end
end
