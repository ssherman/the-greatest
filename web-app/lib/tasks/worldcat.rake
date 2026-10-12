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
end
