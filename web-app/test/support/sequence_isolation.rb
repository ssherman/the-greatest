# Id sequences are not transactional: setval and nextval survive the rollback that
# undoes everything else a test does. Fixture loading leaves each sequence above the
# hashed fixture ids, so a test that moves one lower leaks into every later test in
# the same worker -- a new row lands below the fixtures and `Model.last` stops
# returning it. A test class that moves a sequence declares it here, and the value
# is put back after each test.
module SequenceIsolation
  extend ActiveSupport::Concern

  class_methods do
    def isolate_sequences(*tables)
      setup { @isolated_sequences = tables.index_with { |table| SequenceIsolation.next_value(table) } }
      teardown { @isolated_sequences.each { |table, value| SequenceIsolation.set_next_value(table, value) } }
    end
  end

  def self.next_value(table)
    last_value, is_called = connection.select_rows("SELECT last_value, is_called FROM #{sequence_for(table)}").first
    ActiveModel::Type::Boolean.new.cast(is_called) ? last_value.to_i + 1 : last_value.to_i
  end

  def self.set_next_value(table, value)
    connection.execute("SELECT setval(#{connection.quote(sequence_for(table))}, #{value.to_i}, false)")
  end

  def self.sequence_for(table)
    connection.select_value("SELECT pg_get_serial_sequence(#{connection.quote(table)}, 'id')")
  end

  def self.connection
    ActiveRecord::Base.connection
  end
end
