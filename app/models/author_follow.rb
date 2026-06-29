# frozen_string_literal: true

# A user following an author: the sync job periodically discovers that
# author's books from the metadata providers and (optionally) auto-requests
# any that aren't already in the library.
class AuthorFollow < ApplicationRecord
  belongs_to :user

  enum :book_type, { audiobook: 0, ebook: 1 }

  # Re-check a followed author at most this often.
  CHECK_INTERVAL = 12.hours

  validates :author_name, presence: true
  validates :book_type, presence: true
  validates :author_name, uniqueness: { scope: [ :user_id, :book_type ], case_sensitive: false }

  scope :enabled, -> { where(enabled: true) }
  scope :due, -> { enabled.where("last_checked_at IS NULL OR last_checked_at <= ?", CHECK_INTERVAL.ago) }

  def mark_checked!
    update!(last_checked_at: Time.current)
  end

  def display_name
    "#{author_name} (#{book_type})"
  end
end
