# frozen_string_literal: true

# Everything the user-owned ranking configuration feature needs to know about
# a domain, in one place. Switching a domain on is adding entries here (two
# for music: albums and songs), a nav link, and the banner line in its layout
# -- no controller, model or job changes (spec §14).
#
# A domain with no entry 404s the whole /my/rankings surface: every domain
# shares one Firebase project, so a music or games user can sign in and type
# the URL today; the empty registry is what keeps it closed.
module RankingConfigurations
  module Registry
    URL_HELPERS = Rails.application.routes.url_helpers

    Entry = Struct.new(
      :domain,                      # :books
      :kind,                        # URL/param token; only consulted by new/create
      :ranking_configuration_class, # "Books::RankingConfiguration"
      :list_class,                  # what the picker searches and AddLists accepts
      :penalty_classes,             # Penalty STI types a configuration of this kind may apply
      :results_path,                # ->(config) { public ranked page for this configuration }
      :lists_path,                  # ->(config) { public lists page for this configuration }
      :list_path,                   # ->(list)   { public page for one list }
      :official_rankings_path,      # -> { the site's official ranking }
      keyword_init: true
    )

    ENTRIES = [
      Entry.new(
        domain: :books,
        kind: "books",
        ranking_configuration_class: "Books::RankingConfiguration",
        list_class: "Books::List",
        penalty_classes: ["Global::Penalty", "Books::Penalty"],
        results_path: ->(config) { URL_HELPERS.books_rc_path(ranking_configuration_id: config.id) },
        lists_path: ->(config) { URL_HELPERS.books_rc_lists_path(ranking_configuration_id: config.id) },
        list_path: ->(list) { URL_HELPERS.books_list_path(list) },
        official_rankings_path: -> { URL_HELPERS.books_root_path }
      )
    ].freeze

    def self.for_domain(domain)
      ENTRIES.select { |entry| entry.domain == domain.to_sym }
    end

    def self.find(domain, kind)
      for_domain(domain).find { |entry| entry.kind == kind.to_s }
    end

    def self.for_config(config)
      ENTRIES.find { |entry| entry.ranking_configuration_class == config.type }
    end

    # The penalties a user may switch on for this kind: the catalogue rows
    # (never another user's private penalties) that can actually change a
    # result. A dynamic penalty fires from list attributes, so it always can.
    # A static penalty only acts through ListPenalty tags, so one tagged on no
    # active list of this kind is inert whatever value it is given -- showing
    # it would invite a user to enable something that never moves a ranking.
    def self.penalties_for(entry)
      catalogue = ::Penalty.where(type: entry.penalty_classes, user_id: nil)
      tagged = ::ListPenalty.joins(:list)
        .where(lists: {type: entry.list_class, status: ::List.statuses[:active]})
        .select(:penalty_id)

      catalogue.where.not(dynamic_type: nil).or(catalogue.where(dynamic_type: nil, id: tagged))
    end
  end
end
