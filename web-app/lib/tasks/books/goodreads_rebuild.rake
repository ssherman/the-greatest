# The Goodreads rebuild (docs/superpowers/specs/2026-10-27-goodreads-rebuild-design.md,
# docs/features/goodreads-rebuild.md): repairs the books legacy's Goodreads imports made, from the
# export rows. Steps and their order live in docs/launch-todo.md.
namespace :books do
  namespace :goodreads_rebuild do
    tally = ->(counts) { counts.map { |key, count| "#{key} #{count}" }.join(", ").presence || "nothing" }

    desc "Read-only: how many post-import books are trusted (on a real list) and how many are derived (import-made)"
    task cohorts: :environment do
      puts "post-import books: #{tally.call(Services::Books::GoodreadsRebuild::Cohort.counts)}"
    end

    desc "Retire the replay's proposed relinks and identifier strips (rejected and superseded). " \
      "A dry run unless [apply]; a second apply finds 0."
    task :retire_replay_proposals, [:apply] => :environment do |_task, args|
      result = Services::Books::GoodreadsRebuild::RetireReplayProposals.call(apply: args[:apply] == "apply")
      puts "proposed replay verdicts: #{tally.call(result.data[:counts])}"
      puts(result.data[:applied] ? "retired" :
        "dry run: nothing changed; run books:goodreads_rebuild:retire_replay_proposals[apply]")
    end
  end
end
