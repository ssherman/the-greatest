# frozen_string_literal: true

module Penalties
  # Canonical category and public description for every penalty.
  #
  # Keyed by id, not name: names are long, editable in admin, and several differ
  # only in a trailing clause. Descriptions are written for a site visitor AND
  # for whoever is tagging a list in admin -- one text serves both, which is why
  # there is no separate public_description column.
  module Backfill
    ENTRIES = {
      # --- Who voted -------------------------------------------------------
      8 => {category: :voter_expertise,
            description: "Most of the people who voted live in one country, so the list reflects one nation's taste rather than a broad readership."},
      9 => {category: :voter_expertise,
            description: "The voting panel was narrow -- similar backgrounds, similar training, or similar taste -- so the result reflects a small slice of readers."},
      10 => {category: :voter_expertise,
             description: "Voted on by the general public rather than critics, authors, or scholars. Popular opinion is worth something, but it is not expert judgement."},
      11 => {category: :voter_expertise,
             description: "Voting was limited to a specific group of people, so the list describes that group's preferences rather than a general consensus."},
      22 => {category: :voter_expertise,
             description: "The voters appear to be promoting a viewpoint rather than judging quality, so their picks say more about the agenda than the books."},
      32 => {category: :voter_expertise,
             description: "Roughly half the panel were experts and half were general readers, so the list blends expert and popular opinion."},
      44 => {category: :voter_expertise,
             description: "The public voted, but critics or experts chose and vetted the candidates, so expert judgement shaped the field even though the public ranked it."},

      # --- How many voted --------------------------------------------------
      12 => {category: :voter_participation,
             description: "We could not find out who voted. Named voters can be held to their choices; anonymous ones cannot."},
      13 => {category: :voter_participation,
             description: "Applied automatically when fewer people voted than on a typical list. The fewer the voters, the larger the reduction -- a poll of five is far easier to skew than a poll of five hundred."},
      14 => {category: :voter_participation,
             description: "The list does not say how many people voted, so we cannot tell whether it reflects a crowd or one person's opinion."},
      18 => {category: :voter_participation,
             description: "The number of voters was estimated rather than published, so the figure we hold is approximate."},
      21 => {category: :voter_participation,
             description: "The list names its voters but tells us little else about them, so we cannot judge how qualified the panel was."},

      # --- How much time the list covers -----------------------------------
      17 => {category: :list_time_scope,
             description: "Applied automatically based on how much of history a list covers. A list spanning a few years can only find the best of those years; one spanning centuries competes against everything ever published."},
      28 => {category: :list_time_scope,
             description: "Covers a single year. Yearly awards and best-of-the-year lists cannot tell you what will still be read in fifty years."},
      29 => {category: :list_time_scope,
             description: "Confined to roughly a fifty-year window, so anything published outside it was never eligible."},
      30 => {category: :list_time_scope,
             description: "Confined to roughly a century, so anything published outside it was never eligible."},
      33 => {category: :list_time_scope,
             description: "Confined to roughly five years of publishing -- a very narrow slice of what exists."},
      35 => {category: :list_time_scope,
             description: "Confined to roughly a seventy-five-year window, so anything published outside it was never eligible."},
      40 => {category: :list_time_scope,
             description: "Confined to roughly twenty-five years of publishing, so anything outside that window was never eligible."},
      41 => {category: :list_time_scope,
             description: "Confined to roughly a decade of publishing, so anything outside that window was never eligible."},

      # --- How narrow the list's subject is ---------------------------------
      5 => {category: :list_subject_scope,
            description: "Restricted to authors of one gender, so it surveys part of the field rather than all of it."},
      6 => {category: :list_subject_scope,
            description: "Restricted to books written in one language, so everything written elsewhere was never eligible."},
      7 => {category: :list_subject_scope,
            description: "Built around an unusual angle rather than quality -- entries were chosen to fit a concept, not because they are the best."},
      15 => {category: :list_subject_scope,
             description: "Applied automatically to lists that declare a regional focus. Their scope is narrow, but it is stated honestly up front -- which is also why they are exempt from the western-canon adjustment."},
      16 => {category: :list_subject_scope,
             description: "Applied automatically to single-genre lists. The best fantasy novel is competing in a far smaller field than the best novel."},
      19 => {category: :list_subject_scope,
             description: "Mostly compilations and greatest-hits collections rather than albums as their artists released them."},
      20 => {category: :list_subject_scope,
             description: "Restricted to one console or platform, so games released elsewhere were never eligible."},
      23 => {category: :list_subject_scope,
             description: "Applied automatically when a list that presents itself as general turns out to be 90% or more western. Lists that declare a regional focus up front are exempt."},
      26 => {category: :list_subject_scope,
             description: "Organised around a theme such as religion or politics, so books were picked for fitting the subject rather than for being the best."},
      27 => {category: :list_subject_scope,
             description: "Limited to genre fiction, so literary fiction and non-fiction were never eligible."},
      31 => {category: :list_subject_scope,
             description: "About half the entries were required to come from one country, so the field was partly reserved rather than open."},
      36 => {category: :list_subject_scope,
             description: "Restricted to one continent, so books from everywhere else were never eligible."},
      37 => {category: :list_subject_scope,
             description: "Restricted to authors or books from a single country."},
      38 => {category: :list_subject_scope,
             description: "Restricted to one large region, such as Asia or Latin America."},
      39 => {category: :list_subject_scope,
             description: "Restricted to a single state or province -- a very small pool to pick from."},
      42 => {category: :list_subject_scope,
             description: "Restricted to a single city, the smallest geographic pool we track."},
      43 => {category: :list_subject_scope,
             description: "Restricted to translated or foreign-language books relative to where the voters live."},
      46 => {category: :list_subject_scope,
             description: "Restricted to a small region, such as the American South."},
      47 => {category: :list_subject_scope,
             description: "Restricted to books that are part of a series, so standalone works were never eligible."},
      48 => {category: :list_subject_scope,
             description: "Built around an unusual premise rather than quality -- entries were chosen to fit the concept."},

      # --- How the list was made -------------------------------------------
      1 => {category: :list_integrity,
            description: "Whoever made the list also sells the books on it, so the selection has a commercial interest behind it."},
      2 => {category: :list_integrity,
            description: "Very long. Past a few hundred entries a list stops being a judgement and starts being an inventory."},
      3 => {category: :list_integrity,
            description: "Ranked by something other than quality -- most influential, most surprising, best beach read. Useful, but not a verdict on how good the books are."},
      4 => {category: :list_integrity,
            description: "A sequel or overflow list. Its entries are the ones that did not make the original."},
      24 => {category: :list_integrity,
             description: "The runners-up from another list rather than a selection in its own right."},
      25 => {category: :list_integrity,
             description: "One book chosen per year, so a book competed against whatever else came out that year rather than against everything ever written."},
      34 => {category: :list_integrity,
             description: "We could not find reliable information about how this list was made or who made it."},
      45 => {category: :list_integrity,
             description: "Itself an aggregation of other lists, several of which we may already count -- so it risks counting the same opinions twice."},
      49 => {category: :list_integrity,
             description: "A podcast or column featuring one book at a time. The picks are discussion topics, not a ranking."}
    }

    # Assigns only what actually differs, so a re-run is a no-op and updated_at
    # stays put. Missing ids are skipped rather than raising: this task runs
    # against dev and production, and the two may not hold identical rows.
    def self.call
      updated = 0
      skipped = 0

      ENTRIES.each do |id, entry|
        penalty = Penalty.find_by(id: id)
        if penalty.nil?
          skipped += 1
          next
        end

        penalty.category = entry[:category]
        penalty.description = entry[:description]
        updated += 1 if penalty.changed?
        penalty.save! if penalty.changed?
      end

      {updated: updated, skipped: skipped, total: ENTRIES.size}
    end
  end
end

namespace :penalties do
  desc "Backfill penalty categories and rewrite public descriptions (idempotent)"
  task backfill: :environment do
    result = Penalties::Backfill.call

    puts "Entries:   #{result[:total]}"
    puts "Updated:   #{result[:updated]}"
    puts "Not found: #{result[:skipped]}"

    uncategorized = Penalty.where(category: nil).count
    puts "Penalties still uncategorized: #{uncategorized}"
  end
end
