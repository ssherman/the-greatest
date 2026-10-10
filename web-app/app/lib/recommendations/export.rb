# frozen_string_literal: true

require "zlib"

module Recommendations
  # The interaction export (spec 2 §3): every positive pair for a domain as
  # one gzipped CSV in the store, plus the `latest` pointer. With a hold-out
  # the named pairs are omitted and the pointer is left alone -- that file
  # exists for the harness, never for production training.
  module Export
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)

    def self.call(domain:, store:, name: Date.current.iso8601, hold_out: nil, config: Config.resolve)
      pairs_class = Registry.pairs_class_for(domain)
      return Result.new(success?: false, data: nil, errors: ["no positive pairs for domain #{domain}"]) if pairs_class.nil?

      held = (hold_out || {}).transform_values(&:to_set)
      rows = 0
      omitted = 0
      io = StringIO.new
      gz = Zlib::GzipWriter.new(io)
      gz.write("user_id,item_id\n")
      pairs_class.new(min_rating: config[:collaborative_min_rating]).each_batch do |batch|
        batch.each do |user_id, item_id|
          if held[user_id]&.include?(item_id)
            omitted += 1
            next
          end
          gz.write("#{user_id},#{item_id}\n")
          rows += 1
        end
      end
      gz.close

      key = Paths.interactions(domain, name)
      store.put(key, io.string)
      pointer_moved = hold_out.nil?
      store.write_pointer(Paths.interactions_latest(domain), name) if pointer_moved
      Result.new(success?: true, errors: [], data: {name: name, key: key, rows: rows, omitted: omitted, pointer_moved: pointer_moved})
    end
  end
end
