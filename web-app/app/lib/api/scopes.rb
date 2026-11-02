# frozen_string_literal: true

# The one place that answers "what may a token do?". A registry, not an
# abstraction layer -- its value is that a reviewer reads one hash and knows
# the complete answer, the same reason MembershipGate is a hash.
#
# Scope strings are OAuth-style (`books:read`) on purpose: when Doorkeeper
# arrives for the MCP server, these exact strings become OAuth scopes.
#
# Each scope carries its own eligibility rule, `->(user, member)`: who may
# hold it. `member` is `user.member?` computed once by `eligible_for`. Read scopes
# are for members and service accounts; the `books:admin:*` scopes defer to the
# Books policies so the API never decides admin power differently from the
# admin UI. `implies:` names the scopes a scope covers, and `satisfies?` and
# `eligible_for` both honour it, so a books viewer who is not a member still
# gets `books:read` through `books:admin:read`.
module Api
  module Scopes
    class UnknownScope < StandardError; end

    Scope = Struct.new(:name, :description, :admin, :implies, :eligible, keyword_init: true)

    READER = ->(user, member) { member || user.service? }

    ALL = {
      "books:read" => Scope.new(
        name: "books:read",
        description: "Read books and authors on The Greatest Books",
        admin: false,
        implies: [],
        eligible: READER
      ),
      "music:read" => Scope.new(
        name: "music:read",
        description: "Read albums, artists and songs on The Greatest Music",
        admin: false,
        implies: [],
        eligible: READER
      ),
      "games:read" => Scope.new(
        name: "games:read",
        description: "Read games on The Greatest Games",
        admin: false,
        implies: [],
        eligible: READER
      ),
      "books:admin:read" => Scope.new(
        name: "books:admin:read",
        description: "Read the books admin data: search, and the records behind merges",
        admin: true,
        implies: ["books:read"],
        eligible: ->(user, _member) { ::Books::BookPolicy.new(user, ::Books::Book).index? }
      ),
      "books:admin:merge" => Scope.new(
        name: "books:admin:merge",
        description: "Merge books and authors. This permanently deletes the merged-away records",
        admin: true,
        implies: ["books:admin:read"],
        eligible: ->(user, _member) { ::Books::BookPolicy.new(user, ::Books::Book).destroy? }
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

    def self.admin?(scope) = fetch(scope).admin

    # Every scope this account may hold: those whose own rule passes, plus
    # everything those imply.
    def self.eligible_for(user)
      member = user.member? # one query per call, not one per read scope
      passing = registry.values.select { |scope| scope.eligible.call(user, member) }.map(&:name)
      held = passing.flat_map { |name| [name, *expand(name)] }.uniq
      registry.keys & held
    end

    # What an account may put on a personal token.
    def self.mintable_by(user) = eligible_for(user)

    # The scopes a token really carries right now: what was granted plus what
    # that implies, limited to what the owner is still eligible for. A demoted
    # owner's token shrinks instead of keeping power the owner lost.
    def self.effective(granted, user)
      wanted = Array(granted).select { |scope| known?(scope) }.flat_map { |scope| [scope, *expand(scope)] }.uniq
      registry.keys & wanted & eligible_for(user)
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
