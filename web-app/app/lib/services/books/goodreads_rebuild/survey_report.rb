# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # Plain-text summary of the stage one survey for Shane to read before
      # increment 2b changes anything: counts, then samples of each problem
      # with our title and authors beside what the export says.
      module SurveyReport
        module_function

        SAMPLE = 10

        def call
          surveys = ::Books::RebuildBookSurvey.all
          judged = surveys.where.not(classification: :unsupported)
          lines = []
          lines << "surveyed: #{surveys.count}; derived books not yet surveyed: #{unsurveyed}"
          lines << "by classification: #{tally(::Books::RebuildBookSurvey.classifications.keys.index_with { |key| surveys.where(classification: key).count })}"
          lines << "title disagrees: #{judged.title_disagrees.count}; authors disagree: #{judged.authors_disagree.count}; " \
            "wrong book: #{judged.where(wrong_book: true).count}"
          section(lines, "wrong book", judged.where(wrong_book: true))
          section(lines, "wrong author", judged.authors_disagree.where(wrong_book: false))
          section(lines, "stripped or different title", judged.title_disagrees.where(wrong_book: false))
          lumps(lines, surveys.lump)
          lines.join("\n")
        end

        def unsurveyed = Cohort.derived.where.not(id: ::Books::RebuildBookSurvey.select(:book_id)).count

        def tally(counts) = counts.map { |key, count| "#{key} #{count}" }.join(", ")

        def sample(scope) = scope.order(Arel.sql("random()")).limit(SAMPLE).includes(book: :authors)

        def section(lines, name, scope)
          lines << "" << "#{name} (sample of #{SAMPLE}):"
          sample(scope).each { |survey| lines << "  #{line(survey)}" }
        end

        def line(survey)
          main = survey.groups.first || {}
          %(##{survey.book_id} "#{survey.book.title}" by #{survey.book.authors.map(&:name).join(", ").presence || "nobody"} | ) +
            %(export: "#{Array(main["titles"]).join(" / ")}" by #{Array(main["authors"]).join(", ")} (#{main["row_count"].to_i} rows))
        end

        def lumps(lines, scope)
          lines << "" << "lumps (sample of #{SAMPLE}):"
          sample(scope).each do |survey|
            lines << %(  ##{survey.book_id} "#{survey.book.title}")
            survey.groups.each do |group|
              lines << %(    - "#{group["titles"].join(" / ")}" by #{group["authors"].join(", ")}, ) +
                "#{group["year"] || "year?"}#{", vol #{group["volume"]}" if group["volume"]} (#{group["row_count"]} rows)"
            end
          end
        end
      end
    end
  end
end
