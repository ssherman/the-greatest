# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      module Lookups
        # WorldCat by ISBN. The service returns every record it holds for the
        # number, so the pick is deterministic: usable records only, the most
        # holdings first, the lowest OCLC number on a tie.
        module WorldCat
          module_function

          def call(isbn)
            ::Books::WorldCat::Client.new.record_by_isbn(isbn)
              .filter_map { |record| candidate(record) }
              .min_by { |record, _answer| [-record.holding_count.to_i, record.oclc.to_i] }
              &.last
          rescue ::Books::WorldCat::Exceptions::NotFoundError
            nil
          end

          def candidate(record)
            title, subtitle = Names.world_cat_title(record.title, record.subtitle)
            answer = Answer.build(title: title, subtitle: subtitle, author_names: authors(record), year: record.year)
            [record, answer] if answer.usable?
          end

          # The creator; contributors only when there is no creator.
          def authors(record)
            creators = [record.creator].filter_map { |entry| name_of(entry) }
            creators = Array(record.contributors).filter_map { |entry| name_of(entry) } if creators.empty?
            creators
          end

          def name_of(entry)
            Names.world_cat_person(entry.is_a?(Hash) ? entry["name"] : entry)
          end
        end
      end
    end
  end
end
