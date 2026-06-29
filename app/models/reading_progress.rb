# frozen_string_literal: true

# A user's saved place in a book: an opaque +location+ (epub CFI, pdf page, or
# comic page index) plus a 0..100 +percent+ for progress display.
class ReadingProgress < ApplicationRecord
  belongs_to :user
  belongs_to :book

  validates :book_id, uniqueness: { scope: :user_id }
  validates :percent, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }
end
