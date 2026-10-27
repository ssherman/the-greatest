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
  end
end
