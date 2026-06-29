# frozen_string_literal: true

class CreateAuthorFollows < ActiveRecord::Migration[8.1]
  def change
    create_table :author_follows do |t|
      t.references :user, null: false, foreign_key: true
      t.string :author_name, null: false
      t.string :metadata_source
      t.string :metadata_author_id
      t.integer :book_type, null: false, default: 1
      t.boolean :auto_request, null: false, default: true
      t.boolean :enabled, null: false, default: true
      t.datetime :last_checked_at

      t.timestamps
    end

    add_index :author_follows, [ :user_id, :author_name, :book_type ], unique: true, name: "index_author_follows_on_user_author_type"
  end
end
