# frozen_string_literal: true

class CreateReadingProgresses < ActiveRecord::Migration[8.1]
  def change
    create_table :reading_progresses do |t|
      t.references :user, null: false, foreign_key: true
      t.references :book, null: false, foreign_key: true
      t.string :location
      t.float :percent, null: false, default: 0.0

      t.timestamps
    end

    add_index :reading_progresses, [ :user_id, :book_id ], unique: true
  end
end
