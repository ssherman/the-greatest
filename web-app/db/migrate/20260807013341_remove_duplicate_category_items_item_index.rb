class RemoveDuplicateCategoryItemsItemIndex < ActiveRecord::Migration[8.1]
  # CONCURRENTLY cannot run inside a transaction, and category_items is ~390 MB
  # with millions of rows loaded by the data migrations -- a plain DROP INDEX
  # would hold an ACCESS EXCLUSIVE lock on the table for the duration.
  disable_ddl_transaction!

  # 20250810230523_create_category_items created this index twice: once
  # implicitly via `t.references :item, polymorphic: true`, and again via an
  # explicit `add_index :category_items, [:item_type, :item_id]`. The two
  # definitions are byte-identical, so one has always been dead weight -- index
  # maintenance on every write plus 23 MB, for plans the survivor already serves.
  def up
    remove_index :category_items, name: "index_category_items_on_item",
      algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :category_items, [:item_type, :item_id], name: "index_category_items_on_item",
      algorithm: :concurrently, if_not_exists: true
  end
end
