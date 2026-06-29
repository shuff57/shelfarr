# frozen_string_literal: true

class AuthorFollowsController < ApplicationController
  before_action :set_author_follow, only: [ :update, :destroy ]

  def index
    @author_follows = Current.user.author_follows.order(:author_name)
  end

  def create
    @author_follow = Current.user.author_follows.new(create_params)

    if @author_follow.save
      AuthorFollowSyncJob.perform_later(@author_follow.id) if @author_follow.enabled?
      redirect_back fallback_location: author_follows_path,
        notice: "Now following #{@author_follow.author_name}. New books will be requested automatically."
    else
      redirect_back fallback_location: author_follows_path,
        alert: @author_follow.errors.full_messages.to_sentence.presence || "Could not follow author."
    end
  end

  def update
    if @author_follow.update(update_params)
      AuthorFollowSyncJob.perform_later(@author_follow.id) if @author_follow.enabled?
      redirect_to author_follows_path, notice: "Follow updated."
    else
      redirect_to author_follows_path, alert: @author_follow.errors.full_messages.to_sentence
    end
  end

  def destroy
    @author_follow.destroy
    redirect_back fallback_location: author_follows_path, notice: "Unfollowed #{@author_follow.author_name}."
  end

  private

  def set_author_follow
    @author_follow = Current.user.author_follows.find(params[:id])
  end

  def create_params
    params.require(:author_follow).permit(:author_name, :book_type, :metadata_source, :metadata_author_id, :auto_request)
  end

  def update_params
    params.require(:author_follow).permit(:enabled, :auto_request, :book_type)
  end
end
