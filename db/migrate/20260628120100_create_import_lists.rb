# frozen_string_literal: true

class CreateImportLists < ActiveRecord::Migration[8.1]
  def change
    create_table :import_lists do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.string :list_type, null: false
      t.string :source_url
      t.string :source_id
      t.integer :book_type, null: false, default: 1
      t.boolean :auto_request, null: false, default: true
      t.boolean :enabled, null: false, default: true
      t.integer :item_limit, null: false, default: 25
      t.datetime :last_synced_at
      t.string :last_sync_status

      t.timestamps
    end

    add_index :import_lists, [ :user_id, :name ], unique: true
  end
end
