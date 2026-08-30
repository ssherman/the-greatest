# frozen_string_literal: true

module Penalties
  # Canonical category and public description for every penalty.
  #
  # Keyed by id, not name: names are long, editable in admin, and several differ
  # only in a trailing clause. Descriptions are written for a site visitor AND
  # for whoever is tagging a list in admin -- one text serves both, which is why
  # there is no separate public_description column.
  #
  # Each entry also carries the id's expected `name`, taken verbatim from the
  # legacy penalty reference. It exists purely as a guard: development ids are
  # not provably production ids, so before writing category/description this
  # confirms the row at that id is still the penalty this entry thinks it is.
  module Backfill
    ENTRIES = {
      # --- Who voted -------------------------------------------------------
      8 => {name: "Voters: are mostly from a single country/location",
            category: :voter_expertise,
            description: "Most of the people who voted live in one country, so the list reflects one nation's taste rather than a broad readership."},
      9 => {name: "Voters: diversity of voters is very low",
            category: :voter_expertise,
            description: "The voting panel was narrow -- similar backgrounds, similar training, or similar taste -- so the result reflects a small slice of the audience."},
      10 => {name: "Voters: not critics, authors, or experts",
             category: :voter_expertise,
             description: "Voted on by the general public rather than critics, experts or scholars. Popular opinion is worth something, but it is not expert judgement."},
      11 => {name: "Voters: restricted to a distinct criteria(race, gender, etc)",
             category: :voter_expertise,
             description: "Voting was limited to a specific group of people, so the list describes that group's preferences rather than a general consensus."},
      22 => {name: "Voters: Voters seem to have an agenda/bias of some kind",
             category: :voter_expertise,
             description: "The voters appear to be promoting a viewpoint rather than judging quality, so their picks say more about the agenda than the books."},
      32 => {name: "Voters: half the voters are not critics, authors, or experts",
             category: :voter_expertise,
             description: "Roughly half the panel were experts and half were general readers, so the list blends expert and popular opinion."},
      44 => {name: "Voters: not critics, authors, or experts, but the books on the list were curated by critics/experts",
             category: :voter_expertise,
             description: "The public voted, but critics or experts chose and vetted the candidates, so expert judgement shaped the field even though the public ranked it."},

      # --- How many voted --------------------------------------------------
      12 => {name: "Voters: Unknown Names",
             category: :voter_participation,
             description: "We could not find out who voted. Named voters can be held to their choices; anonymous ones cannot."},
      13 => {name: "Voters: Voter Count",
             category: :voter_participation,
             description: "Applied automatically when fewer people voted than on a typical list. The fewer the voters, the larger the reduction -- a poll of five is far easier to skew than a poll of five hundred."},
      14 => {name: "Voters: Unknown Count",
             category: :voter_participation,
             description: "The list does not say how many people voted, so we cannot tell whether it reflects a crowd or one person's opinion."},
      18 => {name: "Voters: Estimated Count",
             category: :voter_participation,
             description: "The number of voters was estimated rather than published, so the figure we hold is approximate."},
      21 => {name: "Voters: specific voter details are lacking",
             category: :voter_participation,
             description: "The list names its voters but tells us little else about them, so we cannot judge how qualified the panel was."},

      # --- How much time the list covers -----------------------------------
      17 => {name: "List: number of years covered",
             category: :list_time_scope,
             description: "Applied automatically based on how much of history a list covers. A list spanning a few years can only find the best of those years; one spanning centuries competes against everything ever published."},
      28 => {name: "List: only covers 1 year (yearly book awards, best of the year, etc)",
             category: :list_time_scope,
             description: "Covers a single year. Yearly awards and best-of-the-year lists cannot tell you what will still be read in fifty years."},
      29 => {name: "List: only covers 50 years",
             category: :list_time_scope,
             description: "Confined to roughly a fifty-year window, so anything published outside it was never eligible."},
      30 => {name: "List: only covers 100 years",
             category: :list_time_scope,
             description: "Confined to roughly a century, so anything published outside it was never eligible."},
      33 => {name: "List: only covers 5 years",
             category: :list_time_scope,
             description: "Confined to roughly five years of publishing -- a very narrow slice of what exists."},
      35 => {name: "List: only covers 75 years",
             category: :list_time_scope,
             description: "Confined to roughly a seventy-five-year window, so anything published outside it was never eligible."},
      40 => {name: "List: only covers 25 years",
             category: :list_time_scope,
             description: "Confined to roughly twenty-five years of publishing, so anything outside that window was never eligible."},
      41 => {name: "List: only covers 10 years",
             category: :list_time_scope,
             description: "Confined to roughly a decade of publishing, so anything outside that window was never eligible."},

      # --- How narrow the list's subject is ---------------------------------
      5 => {name: "List: only covers 1 specific gender",
            category: :list_subject_scope,
            description: "Restricted to creators of one gender, so it surveys part of the field rather than all of it."},
      6 => {name: "List: only covers 1 specific language",
            category: :list_subject_scope,
            description: "Restricted to one language, so work in every other language was never eligible."},
      7 => {name: "List: only covers items with a weird criteria",
            category: :list_subject_scope,
            description: "Built around an unusual angle rather than quality -- entries were chosen to fit a concept, not because they are the best."},
      15 => {name: "List: only covers 1 specific location",
             category: :list_subject_scope,
             description: "Applied automatically to lists that declare a regional focus. Their scope is narrow, but it is stated honestly up front -- which is also why they are exempt from the western-canon adjustment."},
      16 => {name: "List: only covers 1 specific genre",
             category: :list_subject_scope,
             description: "Applied automatically to single-genre lists. The best work in one genre is competing in a far smaller field than the best work overall."},
      19 => {name: "List: Majority is Greatest Hits Albums",
             category: :list_subject_scope,
             description: "Mostly compilations and greatest-hits collections rather than albums as their artists released them."},
      20 => {name: "List: Platform Specific",
             category: :list_subject_scope,
             description: "Restricted to one console or platform, so games released elsewhere were never eligible."},
      23 => {name: "List: only covers mostly \"Western Canon\" books",
             category: :list_subject_scope,
             description: "Applied automatically when a list that presents itself as general turns out to be 90% or more western. Lists that declare a regional focus up front are exempt."},
      26 => {name: "List: has a focus on a specific theme(religion, etc) but is not definite",
             category: :list_subject_scope,
             description: "Organised around a theme such as religion or politics, so books were picked for fitting the subject rather than for being the best."},
      27 => {name: "List: only covers genre fiction(multiple genres)",
             category: :list_subject_scope,
             description: "Limited to genre fiction, so literary fiction and non-fiction were never eligible."},
      31 => {name: "List: only partially covers 1 specific country",
             category: :list_subject_scope,
             description: "About half the entries were required to come from one country, so the field was partly reserved rather than open."},
      36 => {name: "List: only covers 1 specific continent",
             category: :list_subject_scope,
             description: "Restricted to one continent, so books from everywhere else were never eligible."},
      37 => {name: "List: only covers 1 specific country",
             category: :list_subject_scope,
             description: "Restricted to authors or books from a single country."},
      38 => {name: "List: only covers 1 specific large geographical region (Asia, Latin America, etc)",
             category: :list_subject_scope,
             description: "Restricted to one large region, such as Asia or Latin America."},
      39 => {name: "List: only covers 1 specific state of a country",
             category: :list_subject_scope,
             description: "Restricted to a single state or province -- a very small pool to pick from."},
      42 => {name: "List: only covers 1 specific city",
             category: :list_subject_scope,
             description: "Restricted to a single city, the smallest geographic pool we track."},
      43 => {name: "List: only covers translated or foreign books than where voters are from",
             category: :list_subject_scope,
             description: "Restricted to translated or foreign-language books relative to where the voters live."},
      46 => {name: "List: only covers 1 specific small geographical region (Southern United States, etc)",
             category: :list_subject_scope,
             description: "Restricted to a small region, such as the American South."},
      47 => {name: "List: Only covers Series'",
             category: :list_subject_scope,
             description: "Restricted to books that are part of a series, so standalone works were never eligible."},
      48 => {name: "List: only covers books with a weird criteria(books to help you survive the digital age, etc)",
             category: :list_subject_scope,
             description: "Built around an unusual premise rather than quality -- entries were chosen to fit the concept."},

      # --- How the list was made -------------------------------------------
      1 => {name: "List: Creator of the list, sells the items on the list",
            category: :list_integrity,
            description: "Whoever made the list also sells what is on it, so the selection has a commercial interest behind it."},
      2 => {name: "List: contains over 500 items(Quantity over Quality)",
            category: :list_integrity,
            description: "Very long. Past a few hundred entries a list stops being a judgement and starts being an inventory."},
      3 => {name: "List: criteria is not just best/favorite",
            category: :list_integrity,
            description: "Ranked by something other than quality -- most influential, most surprising, most underrated. Useful, but not a verdict on how good the entries are."},
      4 => {name: "List: is a follow up/honorable mention to a different list",
            category: :list_integrity,
            description: "A sequel or overflow list. Its entries are the ones that did not make the original."},
      24 => {name: "List: honorable mention",
             category: :list_integrity,
             description: "The runners-up from another list rather than a selection in its own right."},
      25 => {name: "List: The selection involves selecting a favorite book per year",
             category: :list_integrity,
             description: "One book chosen per year, so a book competed against whatever else came out that year rather than against everything ever written."},
      34 => {name: "List: Very hard to find any official information on the list",
             category: :list_integrity,
             description: "We could not find reliable information about how this list was made or who made it."},
      45 => {name: "List: Covers aggregated lists that might already be included on the site",
             category: :list_integrity,
             description: "Itself an aggregation of other lists, several of which we may already count -- so it risks counting the same opinions twice."},
      49 => {name: "List: Podcast/Etc that covers 1 book a week/month",
             category: :list_integrity,
             description: "A podcast or column featuring one book at a time. The picks are discussion topics, not a ranking."}
    }

    # Assigns only what actually differs, so a re-run is a no-op and updated_at
    # stays put. Missing ids are skipped rather than raising: this task runs
    # against dev and production, and the two may not hold identical rows.
    #
    # Development ids are not provably production ids -- the 27 Books::Penalty
    # rows exist only in dev, so an id that drifted between the two databases
    # would otherwise silently relabel a live penalty with another penalty's
    # public description. `name:` guards against that: a row is only touched
    # when its stored name matches what this entry expects for that id.
    # Mismatches are skipped and reported rather than raised, so one bad id
    # does not abort the whole backfill -- the caller decides what to do with
    # a non-empty `mismatched` list.
    def self.call
      updated = 0
      not_found = 0
      mismatched = []

      ENTRIES.each do |id, entry|
        penalty = Penalty.find_by(id: id)
        if penalty.nil?
          not_found += 1
          next
        end

        if penalty.name != entry[:name]
          mismatched << {id: id, expected: entry[:name], found: penalty.name}
          next
        end

        penalty.category = entry[:category]
        penalty.description = entry[:description]
        updated += 1 if penalty.changed?
        penalty.save! if penalty.changed?
      end

      {updated: updated, not_found: not_found, mismatched: mismatched, total: ENTRIES.size}
    end
  end
end

namespace :penalties do
  desc "Backfill penalty categories and rewrite public descriptions (idempotent)"
  task backfill: :environment do
    result = Penalties::Backfill.call

    puts "Entries:    #{result[:total]}"
    puts "Updated:    #{result[:updated]}"
    puts "Not found:  #{result[:not_found]}"
    puts "Mismatched: #{result[:mismatched].size}"

    result[:mismatched].each do |m|
      puts "MISMATCHED (skipped): #{m[:id]} expected \"#{m[:expected]}\" found \"#{m[:found]}\""
    end

    uncategorized = Penalty.where(category: nil).count
    puts "Penalties still uncategorized: #{uncategorized}"

    # A mismatch means an id we expected to be one penalty is actually
    # another -- the run must not be able to look successful when that
    # happens, so a bad production run is loud rather than silently wrong.
    exit(1) if result[:mismatched].any?
  end
end
