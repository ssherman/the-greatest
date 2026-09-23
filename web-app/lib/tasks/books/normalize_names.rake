# frozen_string_literal: true

namespace :books do
  namespace :normalize_names do
    print_report = lambda do |data|
      %i[books authors].each do |model|
        counts = data[model]
        puts "#{model}: #{counts[:scanned]} scanned, #{counts[:changed]} would change " \
          "(#{counts[:whitespace]} whitespace only, #{counts[:nfkc]} NFKC beyond whitespace)"
        counts[:samples].each { |sample| puts "  #{sample[:id]} | #{sample[:before].inspect} -> #{sample[:after].inspect}" }
      end
    end

    desc "Report how many stored book titles and author names the save-time normalizer would change (read-only)"
    task report: :environment do
      print_report.call(Services::Books::NormalizeStoredNames.call(apply: false).data)
    end

    desc "Normalize every stored book title and author name the normalizer would change, in place, and flag the collisions"
    task apply: :environment do
      data = Services::Books::NormalizeStoredNames.call(apply: true).data
      print_report.call(data)
      puts "flagged #{data[:pairs_flagged]} duplicate pairs"
    end
  end
end
