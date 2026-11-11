# frozen_string_literal: true

module Services
  module MatchDecisions
    # The match-decision queue's filters, shared by the admin page and the admin
    # API so the two cannot drift. Takes an already domain-scoped relation and
    # the request params; a value outside a filter's vocabulary is ignored here
    # (the API rejects bad values with a 400 before calling this). Defaults are
    # the queue's: pending (needing review, not yet reviewed), verify runs hidden.
    # The `via` filter is not here: it narrows reviewed rows only and each
    # surface applies it itself.
    class Filter
      OUTCOMES = ::MatchDecision.outcomes.keys.freeze
      CONFIDENCES = ::MatchDecision.confidences.keys.freeze
      DECIDED_BY = ::MatchDecision.defined_enums.fetch("decided_by").keys.freeze
      REVIEWED = %w[pending reviewed all].freeze
      VERIFY = %w[hide include].freeze

      def self.call(scope, params) = new(scope, params).call

      def self.reviewed_value(params) = REVIEWED.include?(params[:reviewed]) ? params[:reviewed] : "pending"

      def self.verify_value(params) = VERIFY.include?(params[:verify]) ? params[:verify] : "hide"

      def initialize(scope, params)
        @scope = scope
        @params = params
      end

      def call
        scope = @scope
        # The full registry, not a domain's entries: an entity label that belongs
        # to another domain (entity=album on a books queue) must still resolve to
        # a real entry so the finder filter intersects with the domain scope and
        # returns nothing -- as opposed to an entity that matches no label
        # anywhere ("cheese"), which is ignored rather than filtered.
        entity = DataImporters::FinderRegistry::ENTRIES.find { |entry| entry.label.parameterize == @params[:entity].to_s }
        scope = scope.where(finder: entity.finder) if entity
        scope = scope.where(outcome: @params[:outcome]) if OUTCOMES.include?(@params[:outcome])
        scope = scope.where(confidence: @params[:confidence]) if CONFIDENCES.include?(@params[:confidence])
        scope = scope.where(decided_by: @params[:decided_by]) if DECIDED_BY.include?(@params[:decided_by])
        scope = case reviewed
        when "pending" then scope.needing_review
        when "reviewed" then scope.where.not(reviewed_at: nil)
        else scope
        end
        scope = scope.where(verify: false) if verify == "hide"
        scope
      end

      private

      def reviewed = self.class.reviewed_value(@params)

      def verify = self.class.verify_value(@params)
    end
  end
end
