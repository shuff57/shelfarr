# frozen_string_literal: true

require "test_helper"

class AuthorFollowTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)
  end

  test "valid with a user and author name" do
    follow = @user.author_follows.new(author_name: "Brandon Sanderson", book_type: :ebook)
    assert follow.valid?
  end

  test "requires an author name" do
    follow = @user.author_follows.new(author_name: "", book_type: :ebook)
    assert_not follow.valid?
    assert_includes follow.errors[:author_name], "can't be blank"
  end

  test "author name is unique per user and book type, case-insensitively" do
    @user.author_follows.create!(author_name: "Jane Austen", book_type: :ebook)
    dup = @user.author_follows.new(author_name: "jane austen", book_type: :ebook)
    assert_not dup.valid?
  end

  test "same author allowed for a different book type" do
    @user.author_follows.create!(author_name: "Jane Austen", book_type: :ebook)
    other = @user.author_follows.new(author_name: "Jane Austen", book_type: :audiobook)
    assert other.valid?
  end

  test "due scope includes never-checked and stale, excludes recent and disabled" do
    never = @user.author_follows.create!(author_name: "A", book_type: :ebook, last_checked_at: nil)
    stale = @user.author_follows.create!(author_name: "B", book_type: :ebook, last_checked_at: 2.days.ago)
    recent = @user.author_follows.create!(author_name: "C", book_type: :ebook, last_checked_at: 1.minute.ago)
    disabled = @user.author_follows.create!(author_name: "D", book_type: :ebook, enabled: false)

    due = AuthorFollow.due
    assert_includes due, never
    assert_includes due, stale
    assert_not_includes due, recent
    assert_not_includes due, disabled
  end

  test "mark_checked! stamps last_checked_at" do
    follow = @user.author_follows.create!(author_name: "A", book_type: :ebook)
    freeze_time do
      follow.mark_checked!
      assert_in_delta Time.current.to_f, follow.last_checked_at.to_f, 1
    end
  end
end
