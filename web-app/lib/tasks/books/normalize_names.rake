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
      result = Services::Books::NormalizeStoredNames.call(apply: true)
      print_report.call(result.data)
      puts "flagged #{result.data[:pairs_flagged]} duplicate pairs"
      unless result.errors.empty?
        result.errors.each { |error| puts "ERROR: #{error}" }
        abort "#{result.errors.size} row(s) could not be saved"
      end
    end
  end
end
