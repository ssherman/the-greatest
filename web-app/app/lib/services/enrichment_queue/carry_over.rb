module Services
  module EnrichmentQueue
    # Moves source's queue rows to target for a merge. A row follows only when
    # target has no row of that kind; the source's duplicate is deleted. The
    # survivor's history wins: if it still has a gap and no row, the next fill
    # re-queues it. Returns a Result whose data[:moved] is the count moved.
    class CarryOver
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call(source:, target:)
        new(source: source, target: target).call
      end

      def initialize(source:, target:)
        @source = source
        @target = target
      end

      def call
        taken = ::EnrichmentRequest.where(enrichable: @target).pluck(:kind)
        moved = 0
        ::EnrichmentRequest.where(enrichable: @source).find_each do |row|
          if taken.include?(row.kind)
            row.delete
          else
            row.update!(enrichable: @target)
            taken << row.kind
            moved += 1
          end
        end
        Result.new(success?: true, data: {moved: moved}, errors: [])
      end
    end
  end
end
