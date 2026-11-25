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

          # The creator; contributors only when the record has no creator at
          # all. A creator that cleans to nothing leaves the book authorless
          # rather than crediting an illustrator or translator.
          def authors(record)
            creators = [record.creator].reject { |entry| raw_name(entry).blank? }
            creators = Array(record.contributors) if creators.empty?
            creators.filter_map { |entry| Names.world_cat_person(raw_name(entry)) }
          end

          def raw_name(entry)
            entry.is_a?(Hash) ? entry["name"] : entry
          end
        end
      end
    end
  end
end
