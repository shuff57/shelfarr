# frozen_string_literal: true

require "test_helper"

class ImportListTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
  end

  test "valid query list needs a source_id" do
    list = @user.import_lists.new(name: "Fantasy", list_type: "query", book_type: :ebook, source_id: "fantasy")
    assert list.valid?
  end

  test "query list without a source_id is invalid" do
    list = @user.import_lists.new(name: "Fantasy", list_type: "query", book_type: :ebook)
    assert_not list.valid?
    assert_includes list.errors[:source_id], "is required for this list type"
  end

  test "goodreads_rss list needs a source_url" do
    list = @user.import_lists.new(name: "Shelf", list_type: "goodreads_rss", book_type: :ebook)
    assert_not list.valid?
    assert_includes list.errors[:source_url], "is required for a Goodreads RSS feed"
  end

  test "rejects unknown list types" do
    list = @user.import_lists.new(name: "X", list_type: "nonsense", book_type: :ebook, source_id: "x")
    assert_not list.valid?
  end

  test "name is unique per user" do
    @user.import_lists.create!(name: "My List", list_type: "query", source_id: "x", book_type: :ebook)
    dup = @user.import_lists.new(name: "my list", list_type: "query", source_id: "y", book_type: :ebook)
    assert_not dup.valid?
  end

  test "item_limit must be within range" do
    list = @user.import_lists.new(name: "X", list_type: "query", source_id: "x", book_type: :ebook, item_limit: 0)
    assert_not list.valid?
  end

  test "due scope respects interval and enabled flag" do
    never = @user.import_lists.create!(name: "N", list_type: "query", source_id: "x", book_type: :ebook)
    stale = @user.import_lists.create!(name: "S", list_type: "query", source_id: "x", book_type: :ebook, last_synced_at: 2.days.ago)
    recent = @user.import_lists.create!(name: "R", list_type: "query", source_id: "x", book_type: :ebook, last_synced_at: 1.minute.ago)
    disabled = @user.import_lists.create!(name: "D", list_type: "query", source_id: "x", book_type: :ebook, enabled: false)

    due = ImportList.due
    assert_includes due, never
    assert_includes due, stale
    assert_not_includes due, recent
    assert_not_includes due, disabled
  end

  test "mark_synced! records status and timestamp" do
    list = @user.import_lists.create!(name: "X", list_type: "query", source_id: "x", book_type: :ebook)
    list.mark_synced!("ok: 3 requested")
    assert_equal "ok: 3 requested", list.last_sync_status
    assert_not_nil list.last_synced_at
  end

  test "list_type_label returns a human label" do
    list = @user.import_lists.new(list_type: "goodreads_rss")
    assert_equal "Goodreads RSS feed", list.list_type_label
  end
end
