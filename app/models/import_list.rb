# frozen_string_literal: true

# A user-configured external book list (Hardcover list, OpenLibrary subject,
# Goodreads RSS, or a plain query). The sync job periodically resolves the
# list to metadata candidates and (optionally) auto-requests them.
class ImportList < ApplicationRecord
  belongs_to :user

  enum :book_type, { audiobook: 0, ebook: 1 }

  # list_type => human label. The resolver in ImportListSyncJob maps each type
  # to a metadata query; "query" is the always-available fallback.
  LIST_TYPES = {
    "query" => "Saved search",
    "openlibrary_subject" => "Open Library subject",
    "goodreads_rss" => "Goodreads RSS feed"
  }.freeze

  SYNC_INTERVAL = 12.hours

  validates :name, presence: true
  validates :name, uniqueness: { scope: :user_id, case_sensitive: false }
  validates :list_type, presence: true, inclusion: { in: LIST_TYPES.keys }
  validates :book_type, presence: true
  validates :item_limit, numericality: { greater_than: 0, less_than_or_equal_to: 200 }
  validate :source_present_for_type

  scope :enabled, -> { where(enabled: true) }
  scope :due, -> { enabled.where("last_synced_at IS NULL OR last_synced_at <= ?", SYNC_INTERVAL.ago) }

  def list_type_label
    LIST_TYPES.fetch(list_type, list_type)
  end

  def mark_synced!(status)
    update!(last_synced_at: Time.current, last_sync_status: status.to_s.truncate(250))
  end

  private

  # "query" and "openlibrary_subject" live in source_id; feeds live in source_url.
  def source_present_for_type
    case list_type
    when "goodreads_rss"
      errors.add(:source_url, "is required for a Goodreads RSS feed") if source_url.blank?
    else
      errors.add(:source_id, "is required for this list type") if source_id.blank?
    end
  end
end
