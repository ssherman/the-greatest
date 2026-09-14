# frozen_string_literal: true

# The one place that answers "what may a token do?". A registry, not an
# abstraction layer -- its value is that a reviewer reads one hash and knows
# the complete answer, the same reason MembershipGate is a hash.
#
# Scope strings are OAuth-style (`books:read`) on purpose: when Doorkeeper
# arrives for the MCP server, these exact strings become OAuth scopes.
#
# Write and admin scopes are not defined yet. When one is, it goes here with
# `implies:` naming the reads it covers, and `satisfies?` already honours that.
module Api
  module Scopes
    class UnknownScope < StandardError; end

    Scope = Struct.new(:name, :description, :member_mintable, :implies, keyword_init: true)

    ALL = {
      "books:read" => Scope.new(
        name: "books:read",
        description: "Read books and authors on The Greatest Books",
        member_mintable: true,
        implies: []
      ),
      "music:read" => Scope.new(
        name: "music:read",
        description: "Read albums, artists and songs on The Greatest Music",
        member_mintable: true,
        implies: []
      ),
      "games:read" => Scope.new(
        name: "games:read",
        description: "Read games on The Greatest Games",
        member_mintable: true,
        implies: []
      )
    }.freeze

    def self.all = registry.keys

    def self.known?(scope) = registry.key?(scope.to_s)

    def self.description(scope) = fetch(scope).description

    def self.fetch(scope)
      registry.fetch(scope.to_s) do
        raise UnknownScope, "#{scope.inspect} is not registered in Api::Scopes::ALL"
      end
    end

    # What an account may put on a personal token. A person gets the
    # member-mintable set; a service account gets whatever an admin assigns.
    def self.mintable_by(user)
      return all if user.service?

      registry.values.select(&:member_mintable).map(&:name)
    end

    # Does the granted set cover the required scope? A granted scope covers
    # itself and everything it implies, transitively. Unknown granted scopes
    # are ignored rather than raised on: a token minted before a scope was
    # retired must still work for the scopes it does have.
    def self.satisfies?(granted, required)
      required = required.to_s
      Array(granted).any? { |scope| scope == required || expand(scope).include?(required) }
    end

    def self.expand(scope)
      return [] unless known?(scope)

      fetch(scope).implies.flat_map { |implied| [implied, *expand(implied)] }
    end

    # Indirection so a test can register a hypothetical write scope without
    # mutating the frozen constant.
    def self.registry = ALL
    private_class_method :registry
  end
end
