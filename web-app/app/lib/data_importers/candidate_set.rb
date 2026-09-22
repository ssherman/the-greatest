# frozen_string_literal: true

module DataImporters
  # The union of every source's candidates, merged by local record or by
  # external key. Insertion order is kept, which is the order sources ran.
  class CandidateSet
    def initialize
      @candidates = []
    end

    def add(candidate)
      by_record = candidate.local? ? find_local(candidate.record) : nil
      by_key = candidate.external? ? find_external(candidate.external_source, candidate.external_key) : nil

      if by_record && by_key && !by_record.equal?(by_key)
        # A local candidate and an external-only candidate turn out to be
        # the same thing: fold the external one into the local one.
        by_record.absorb(by_key)
        @candidates.delete(by_key)
        by_record.absorb(candidate)
      elsif by_record
        by_record.absorb(candidate)
      elsif by_key
        by_key.absorb(candidate)
      else
        @candidates << candidate
      end
    end

    def to_a
      @candidates.dup
    end

    def locals
      @candidates.select(&:local?)
    end

    def size
      @candidates.size
    end

    def empty?
      @candidates.empty?
    end

    private

    def find_local(record)
      @candidates.find { |c| c.local? && c.record.instance_of?(record.class) && c.record.id == record.id }
    end

    def find_external(source, key)
      @candidates.find { |c| c.external? && c.external_source == source && c.external_key == key }
    end
  end
end
