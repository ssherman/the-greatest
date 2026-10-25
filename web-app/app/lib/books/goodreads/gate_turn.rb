# frozen_string_literal: true

module Books
  module Goodreads
    # One turn through FetchGate's sequence, shared by every caller that
    # fetches a Goodreads page (FetchPageJob and the enrichment step), so the
    # order cannot drift between them: reserve unless the turn is already due,
    # refuse, wait for the reservation, refuse if blocked, wait out the spacing
    # since the last fetch, then start. The caller reschedules itself for a
    # :wait (with due: true) and never sleeps.
    module GateTurn
      Decision = Data.define(:action, :wait, :refusal)

      def self.call(gate:, due:)
        unless due
          reservation = gate.reserve
          return refused(reservation.refusal) unless reservation.granted?
          return waiting(reservation.wait) if reservation.wait.positive?
        end
        return refused(:blocked) if gate.blocked?

        # A turn that came due late (a deploy, a slow fetch before it) still
        # waits out the gap since the last fetch began, without a new turn.
        spacing = gate.spacing_wait
        return waiting(spacing) if spacing.positive?

        gate.started!
        Decision.new(action: :fetch, wait: nil, refusal: nil)
      end

      # A challenge or an unrecognizable page blocks every fetch for the cooldown.
      def self.after_fetch(gate:, outcome:)
        gate.block! if %i[blocked unparseable].include?(outcome)
      end

      def self.refused(reason) = Decision.new(action: :refused, wait: nil, refusal: reason)

      def self.waiting(seconds) = Decision.new(action: :wait, wait: seconds, refusal: nil)
      private_class_method :refused, :waiting
    end
  end
end
