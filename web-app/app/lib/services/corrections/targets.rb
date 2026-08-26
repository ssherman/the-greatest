module Services
  module Corrections
    module Targets
      # A case rather than a constant hash: a hash literal would reference both
      # classes at module-load time, which Zeitwerk resolves in whatever order it
      # loads these files. This resolves each lazily, at call time.
      def self.for(target)
        case target
        when :column then Column
        when :description then PrimaryDescription
        else raise ArgumentError, "unknown correction target: #{target.inspect}"
        end
      end
    end
  end
end
