# frozen_string_literal: true

namespace :worldcat do
  desc "Write our ISBN-13s one per line for the WorldCat build's coverage gate: worldcat:export_isbns[<path>]"
  task :export_isbns, [:path] => :environment do |_task, args|
    path = args[:path] || Rails.root.join("tmp", "our_isbn13s.txt").to_s
    count = File.open(path, "w") { |file| Books::WorldCat::IsbnExport.call(io: file) }
    puts "wrote #{count} ISBNs to #{path}"
  end
end
