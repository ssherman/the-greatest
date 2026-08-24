namespace :books do
  desc "Backfill edition-level ASIN/ISBN/EAN identifiers from legacy Amazon metadata (one-time)"
  task backfill_edition_asins: :environment do
    puts "Backfilling edition identifiers from legacy Amazon metadata..."
    written = Services::Books::EditionIdentifierBackfill.call
    puts "Done. #{written} identifier rows attempted (duplicates ignored)."
  end
end
