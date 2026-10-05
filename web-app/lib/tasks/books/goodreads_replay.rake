# The legacy Goodreads replay (Goodreads import spec §12). A full pass, after
# every books migration pass and in the launch sequence:
#   load -> fix_slugs -> apply -> resolve (wait for the jobs) -> duplicates -> junk -> apply -> report
# apply does nothing while config.x.goodreads_replay.auto_apply is false.
namespace :books do
  namespace :goodreads_replay do
    tally = ->(counts) { counts.map { |key, count| "#{key} #{count}" }.join(", ").presence || "nothing" }

    desc "Copy the legacy app's Goodreads imports, their uploads (legacy R2, LEGACY_R2_* env) and rows into " \
      "replay imports. Idempotent; reads the legacy_books database."
    task load: :environment do
      puts "legacy Goodreads imports: #{tally.call(Services::Books::GoodreadsReplay::LoadImports.call.data[:tally])}"
    end

    desc "Record a strip_identifier verdict for every slug-form Goodreads id (applied by books:goodreads_replay:apply)"
    task fix_slugs: :environment do
      puts "slug-form Goodreads ids: #{Services::Books::GoodreadsReplay::FixSlugIdentifiers.call.data[:recorded]} verdicts"
    end
  end
end
