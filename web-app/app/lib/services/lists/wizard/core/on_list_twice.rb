# frozen_string_literal: true

module Services
  module Lists
    module Wizard
      module Core
        # Books list wizard spec §3: rows that land on the same local book, or
        # on the same Open Library work to create, are all flagged. Settled rows
        # are never changed (§8). Safe to run again.
        class OnListTwice
          def self.call(list:)
            new(list).call
          end

          def initialize(list)
            @list = list
          end

          def call
            rows = @list.list_items.to_a.reject { |item| RowState.new(item).removed? }
            groups = rows.group_by { |item| target_key(item) }
            groups.delete(nil)

            flagged = 0
            groups.each_value do |members|
              next if members.size < 2

              members.each do |item|
                state = RowState.new(item)
                next if state.settled?

                state.flag!("on_list_twice")
                flagged += 1
              end
            end
            flagged
          end

          private

          def target_key(item)
            state = RowState.new(item)
            record_id = item.listable_id || state.target_record_id
            return "record:#{record_id}" if record_id
            return "work:#{state.ol_work_key}" if state.bucket == "create" && state.ol_work_key

            nil
          end
        end
      end
    end
  end
end
