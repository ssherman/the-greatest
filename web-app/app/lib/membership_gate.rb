# frozen_string_literal: true

# The one place that answers "what is behind the paywall?".
#
# Top-level and not nested under Membership on purpose: inside a Membership
# namespace a bare `Membership` resolves to the module rather than the model,
# which has bitten this codebase at least three times and presents as a
# confusing NameError.
#
# This is a registry, not an abstraction layer. Its value is that a reviewer can
# read one hash and know the complete answer. require_membership! refuses an
# unregistered key, so a feature cannot be gated without being written down here.
module MembershipGate
  class UnknownFeature < StandardError; end

  # key => what a person would call it
  FEATURES = {
    members_area: "The members' area at /members"
  }.freeze

  def self.members_only?(feature) = FEATURES.key?(feature.to_sym)

  def self.features = FEATURES.keys

  # Returns the symbol, or raises. Called by require_membership! so a typo in a
  # controller is a loud failure in development and in test rather than a page
  # that silently gates nothing (or gates everything).
  def self.validate!(feature)
    key = feature.to_sym
    raise UnknownFeature, "#{feature.inspect} is not registered in MembershipGate::FEATURES" unless FEATURES.key?(key)
    key
  end
end
