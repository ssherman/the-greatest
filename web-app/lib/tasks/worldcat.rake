# frozen_string_literal: true

namespace :worldcat do
  desc "Write our ISBN-13s one per line for the WorldCat build's coverage gate: worldcat:export_isbns[<path>]"
  task :export_isbns, [:path] => :environment do |_task, args|
    path = args[:path] || Rails.root.join("tmp", "our_isbn13s.txt").to_s
    count = File.open(path, "w") { |file| Books::WorldCat::IsbnExport.call(io: file) }
    puts "wrote #{count} ISBNs to #{path}"
  end

  desc "Count WorldCat genre terms across our books and write config/worldcat/genre_terms.csv (+ _tail.csv)"
  task vocabulary: :environment do
    result = Services::Books::WorldCat::VocabularySnapshot.call(client: Books::WorldCat::Client.new, out_dir: Rails.root.join("config", "worldcat"))
    abort result.errors.join("; ") unless result.success?
    d = result.data
    puts "#{d[:books_matched]} of #{d[:books_seen]} books matched; #{d[:head].size} head terms, #{d[:tail].size} tail terms -> config/worldcat/"
  end

  desc "Run the one-time AI pass mapping config/worldcat/genre_terms.csv onto our genre categories -> config/worldcat/genre_map.yml"
  task map: :environment do
    genres = Books::Category.active.genre.order(:name).pluck(:name)
    result = Services::Books::WorldCat::MapVocabulary.call(
      terms_path: Rails.root.join("config", "worldcat", "genre_terms.csv"),
      out_path: Rails.root.join("config", "worldcat", "genre_map.yml"),
      genres: genres
    )
    abort result.errors.join("; ") unless result.success?
    d = result.data
    puts "mapped #{d[:mapped]} terms (#{d[:skipped_existing]} already mapped) in #{d[:batches]} batch#{"es" unless d[:batches] == 1}; review config/worldcat/genre_map.yml"
  end

  desc "Write docs/data-quality/worldcat-genre-mapping.md from config/worldcat/genre_map.yml"
  task report: :environment do
    result = Services::Books::WorldCat::MappingReport.call(
      map: Books::WorldCat::GenreMap.load,
      out_path: Rails.root.join("..", "docs", "data-quality", "worldcat-genre-mapping.md").expand_path
    )
    abort result.errors.join("; ") unless result.success?
    c = result.data[:counts]
    puts "#{c[:genre]} genre, #{c[:subject]} subject, #{c[:drop]} drop; #{result.data[:unplaced].size} terms with no genre -> docs/data-quality/worldcat-genre-mapping.md"
  end

  desc "Add every mapped WorldCat term as an alternative name on its genre category (idempotent)"
  task apply_aliases: :environment do
    result = Services::Books::WorldCat::ApplyAliases.call(map: Books::WorldCat::GenreMap.load)
    abort result.errors.join("; ") unless result.success?
    d = result.data
    line = "added #{d[:aliases_added]} aliases on #{d[:categories_updated]} genres"
    line += "; genres named by the map but missing: #{d[:missing_genres].join(", ")}" if d[:missing_genres].any?
    puts line
  end
end
