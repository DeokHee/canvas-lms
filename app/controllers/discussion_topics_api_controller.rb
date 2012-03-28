#
# Copyright (C) 2011 Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

# @API Discussion Topics
#
# API for accessing and participating in discussion topics in groups and courses.
class DiscussionTopicsApiController < ApplicationController
  include Api::V1::DiscussionTopics

  before_filter :require_context
  before_filter :require_topic
  before_filter :require_initial_post, :except => [:add_entry, :mark_topic_read, :mark_topic_unread]

  # @API
  # Return a cached structure of the discussion topic, containing all entries,
  # their authors, and their message bodies.
  #
  # May require (depending on the topic) that the user has posted in the topic.
  # If it is required, and the user has not posted, will respond with a 403
  # Forbidden status and the body 'require_initial_post'.
  #
  # In some rare situations, this cached structure may not be available yet. In
  # that case, the server will respond with a 503 error, and the caller should
  # try again soon.
  #
  # The response is an object containing the following keys:
  # * "participants": a list of summary information on users who have posted to
  #   the discussion. Each value is an object containing their id, display_name,
  #   and avatar_url.
  # * "unread_entries": a list of entry ids that are unread by the current
  #   user. this implies that any entry not in this list is read.
  # * "view": a threaded view of all the entries in the discussion, containing
  #   the id, user_id, and message.
  #
  # @example_request
  #
  #   curl 'http://<canvas>/api/v1/courses/<course_id>/discussion_topics/<topic_id>/view' \ 
  #        -H "Authorization: Bearer <token>"
  #
  # @example_response
  #   {
  #     "unread_entries": [1,3,4],
  #     "participants": [
  #       { "id": 10, "display_name": "user 1", "avatar_url": "https://..." },
  #       { "id": 11, "display_name": "user 2", "avatar_url": "https://..." }
  #     ],
  #     "view": [
  #       { "id": 1, "user_id": 10, "parent_id": null, "message": "...html text...", "replies": [
  #         { "id": 3, "user_id": 11, "parent_id": 1, "message": "...html....", "replies": [...] }
  #       ]},
  #       { "id": 2, "user_id": 11, "parent_id": null, "message": "...html..." },
  #       { "id": 4, "user_id": 10, "parent_id": null, "message": "...html..." }
  #     ]
  #   }
  def view
    return unless authorized_action(@topic, @current_user, :read)
    structure, participant_ids, entry_ids = @topic.materialized_view
    if structure
      participant_info = User.find(participant_ids).map do |user|
        { :id => user.id, :display_name => user.short_name, :avatar_image_url => avatar_image_url(User.avatar_key(user.id)), :html_url => polymorphic_url([@context, user]) }
      end
      unread_entries = entry_ids - DiscussionEntryParticipant.read_entry_ids(entry_ids, @current_user)
      # as an optimization, the view structure is pre-serialized as a json
      # string, so we have to do a bit of manual json building here to fit it
      # into the response.
      render :json => %[{ "unread_entries": #{unread_entries.to_json}, "participants": #{participant_info.to_json}, "view": #{structure} }]
    else
      render :nothing => true, :status => 503
    end
  end

  # @API
  # Create a new entry in a discussion topic. Returns a json representation of
  # the created entry (see documentation for 'entries' method) on success.
  #
  # @argument message The body of the entry.
  #
  # @argument attachment [Optional] a multipart/form-data form-field-style
  #   attachment. Attachments larger than 1 kilobyte are subject to quota
  #   restrictions.
  #
  # @example_request
  #
  #   curl 'http://<canvas>/api/v1/courses/<course_id>/discussion_topics/<topic_id>/entries.json' \ 
  #        -F 'message=<message>' \ 
  #        -F 'attachment=@<filename>' \ 
  #        -H "Authorization: Bearer <token>"
  def add_entry
    @entry = build_entry(@topic.discussion_entries)
    if authorized_action(@topic, @current_user, :read) && authorized_action(@entry, @current_user, :create)
      save_entry
    end
  end

  # @API
  # Retrieve the (paginated) top-level entries in a discussion topic.
  #
  # May require (depending on the topic) that the user has posted in the topic.
  # If it is required, and the user has not posted, will respond with a 403
  # Forbidden status and the body 'require_initial_post'.
  #
  # Will include the 10 most recent replies, if any, for each entry returned.
  #
  # If the topic is a root topic with children corresponding to groups of a
  # group assignment, entries from those subtopics for which the user belongs
  # to the corresponding group will be returned.
  #
  # Ordering of returned entries is newest-first by posting timestamp (reply
  # activity is ignored).
  #
  # @response_field id The unique identifier for the entry.
  #
  # @response_field user_id The unique identifier for the author of the entry.
  #
  # @response_field editor_id The unique user id of the person to last edit the entry, if different than user_id.
  #
  # @response_field user_name The name of the author of the entry.
  #
  # @response_field message The content of the entry.
  #
  # @response_field read_state The read state of the entry, "read" or "unread".
  #
  # @response_field created_at The creation time of the entry, in ISO8601
  #   format.
  #
  # @response_field updated_at The updated time of the entry, in ISO8601 format.
  #
  # @response_field attachment JSON representation of the attachment for the
  #   entry, if any. Present only if there is an attachment.
  #
  # @response_field attachments *Deprecated*. Same as attachment, but returned
  #   as a one-element array. Present only if there is an attachment.
  #
  # @response_field recent_replies The 10 most recent replies for the entry,
  #   newest first. Present only if there is at least one reply.
  #
  # @response_field has_more_replies True if there are more than 10 replies for
  #   the entry (i.e., not all were included in this response). Present only if
  #   there is at least one reply.
  #
  # @example_response
  #   [ {
  #       "id": 1019,
  #       "user_id": 7086,
  #       "user_name": "nobody@example.com",
  #       "message": "Newer entry",
  #       "read_state": "read",
  #       "created_at": "2011-11-03T21:33:29Z",
  #       "attachment": {
  #         "content-type": "unknown/unknown",
  #         "url": "http://www.example.com/files/681/download?verifier=JDG10Ruitv8o6LjGXWlxgOb5Sl3ElzVYm9cBKUT3",
  #         "filename": "content.txt",
  #         "display_name": "content.txt" } },
  #     {
  #       "id": 1016,
  #       "user_id": 7086,
  #       "user_name": "nobody@example.com",
  #       "message": "first top-level entry",
  #       "read_state": "unread",
  #       "created_at": "2011-11-03T21:32:29Z",
  #       "recent_replies": [
  #         {
  #           "id": 1017,
  #           "user_id": 7086,
  #           "user_name": "nobody@example.com",
  #           "message": "Reply message",
  #           "created_at": "2011-11-03T21:32:29Z"
  #         } ],
  #       "has_more_replies": false } ]
  def entries
    if authorized_action(@topic, @current_user, :read)
      @entries = Api.paginate(root_entries(@topic).newest_first, self, entry_pagination_path(@topic))
      render :json => discussion_entry_api_json(@entries, @context, @current_user, session)
    end
  end

  # @API
  # Add a reply to an entry in a discussion topic. Returns a json
  # representation of the created reply (see documentation for 'replies'
  # method) on success.
  #
  # May require (depending on the topic) that the user has posted in the topic.
  # If it is required, and the user has not posted, will respond with a 403
  # Forbidden status and the body 'require_initial_post'.
  #
  # @argument message The body of the entry.
  #
  # @argument attachment [Optional] a multipart/form-data form-field-style
  #   attachment. Attachments larger than 1 kilobyte are subject to quota
  #   restrictions.
  #
  # @example_request
  #
  #   curl 'http://<canvas>/api/v1/courses/<course_id>/discussion_topics/<topic_id>/entries/<entry_id>/replies.json' \ 
  #        -F 'message=<message>' \ 
  #        -F 'attachment=@<filename>' \ 
  #        -H "Authorization: Bearer <token>"
  def add_reply
    @parent = all_entries(@topic).find(params[:entry_id])
    @entry = build_entry(@parent.discussion_subentries)
    if authorized_action(@topic, @current_user, :read) && authorized_action(@entry, @current_user, :create)
      save_entry
    end
  end

  # @API
  # Retrieve the (paginated) replies to a top-level entry in a discussion
  # topic.
  #
  # May require (depending on the topic) that the user has posted in the topic.
  # If it is required, and the user has not posted, will respond with a 403
  # Forbidden status and the body 'require_initial_post'.
  #
  # Ordering of returned entries is newest-first by creation timestamp.
  #
  # @response_field id The unique identifier for the reply.
  #
  # @response_field user_id The unique identifier for the author of the reply.
  #
  # @response_field editor_id The unique user id of the person to last edit the entry, if different than user_id.
  #
  # @response_field user_name The name of the author of the reply.
  #
  # @response_field message The content of the reply.
  #
  # @response_field read_state The read state of the entry, "read" or "unread".
  #
  # @response_field created_at The creation time of the reply, in ISO8601
  #   format.
  #
  # @example_response
  #   [ {
  #       "id": 1015,
  #       "user_id": 7084,
  #       "user_name": "nobody@example.com",
  #       "message": "Newer message",
  #       "read_state": "read",
  #       "created_at": "2011-11-03T21:27:44Z" },
  #     {
  #       "id": 1014,
  #       "user_id": 7084,
  #       "user_name": "nobody@example.com",
  #       "message": "Older message",
  #       "read_state": "unread",
  #       "created_at": "2011-11-03T21:26:44Z" } ]
  def replies
    @parent = root_entries(@topic).find(params[:entry_id])
    if authorized_action(@topic, @current_user, :read)
      @replies = Api.paginate(reply_entries(@parent).newest_first, self, reply_pagination_path(@parent))
      render :json => discussion_entry_api_json(@replies, @context, @current_user, session)
    end
  end

  # @API
  # Retrieve a paginated list of discussion entries, given a list of ids.
  #
  # May require (depending on the topic) that the user has posted in the topic.
  # If it is required, and the user has not posted, will respond with a 403
  # Forbidden status and the body 'require_initial_post'.
  #
  # @argument ids[] A list of entry ids to retrieve. Entries will be returned in id order, smallest id first.
  #
  # @response_field id The unique identifier for the reply.
  #
  # @response_field user_id The unique identifier for the author of the reply.
  #
  # @response_field user_name The name of the author of the reply.
  #
  # @response_field message The content of the reply.
  #
  # @response_field read_state The read state of the entry, "read" or "unread".
  #
  # @response_field created_at The creation time of the reply, in ISO8601
  #   format.
  #
  # @response_field deleted If the entry has been deleted, returns true. The
  #   user_id, user_name, and message will not be returned for deleted entries.
  #
  # @example_request
  #
  #   curl 'http://<canvas>/api/v1/courses/<course_id>/discussion_topics/<topic_id>/entry_list?ids[]=1&ids[]=2&ids[]=3' \ 
  #        -H "Authorization: Bearer <token>"
  #
  # @example_response
  #   [
  #     { ... entry 1 ... },
  #     { ... entry 2 ... },
  #     { ... entry 3 ... },
  #   ]
  def entry_list
    if authorized_action(@topic, @current_user, :read)
      ids = Array(params[:ids])
      entries = @topic.discussion_entries.find(ids, :order => :id)
      @entries = Api.paginate(entries, self, entry_pagination_path(@topic))
      render :json => discussion_entry_api_json(@entries, @context, @current_user, session, [])
    end
  end

  # @API
  # Mark the initial text of the discussion topic as read.
  #
  # No request fields are necessary.
  #
  # On success, the response will be 204 No Content with an empty body.
  #
  # @example_request
  #
  #   curl 'http://<canvas>/api/v1/courses/<course_id>/discussion_topics/<topic_id>/read.json' \ 
  #        -X PUT \ 
  #        -H "Authorization: Bearer <token>"
  #        -H "Content-Length: 0"
  def mark_topic_read
    change_topic_read_state("read")
  end

  # @API
  # Mark the initial text of the discussion topic as unread.
  #
  # No request fields are necessary.
  #
  # On success, the response will be 204 No Content with an empty body.
  #
  # @example_request
  #
  #   curl 'http://<canvas>/api/v1/courses/<course_id>/discussion_topics/<topic_id>/read.json' \ 
  #        -X DELETE \ 
  #        -H "Authorization: Bearer <token>"
  def mark_topic_unread
    change_topic_read_state("unread")
  end

  # @API
  # Mark the discussion topic and all its entries as read.
  #
  # No request fields are necessary.
  #
  # On success, the response will be 204 No Content with an empty body.
  #
  # @example_request
  #
  #   curl 'http://<canvas>/api/v1/courses/<course_id>/discussion_topics/<topic_id>/read_all.json' \ 
  #        -X PUT \ 
  #        -H "Authorization: Bearer <token>" \ 
  #        -H "Content-Length: 0"
  def mark_all_read
    if authorized_action(@topic, @current_user, :read)
      @topic.change_all_read_state("read", @current_user)
      render :json => {}, :status => :no_content
    end
  end

  # @API
  # Mark the discussion topic and all its entries as unread.
  #
  # No request fields are necessary.
  #
  # On success, the response will be 204 No Content with an empty body.
  #
  # @example_request
  #
  #   curl 'http://<canvas>/api/v1/courses/<course_id>/discussion_topics/<topic_id>/read_all.json' \ 
  #        -X DELETE \ 
  #        -H "Authorization: Bearer <token>"
  def mark_all_unread
    if authorized_action(@topic, @current_user, :read)
      @topic.change_all_read_state("unread", @current_user)
      render :json => {}, :status => :no_content
    end
  end

  # @API
  # Mark a discussion entry as read.
  #
  # No request fields are necessary.
  #
  # On success, the response will be 204 No Content with an empty body.
  #
  # @example_request
  #
  #   curl 'http://<canvas>/api/v1/courses/<course_id>/discussion_topics/<topic_id>/entries/<entry_id>/read.json' \ \ 
  #        -X PUT \ 
  #        -H "Authorization: Bearer <token>"\ 
  #        -H "Content-Length: 0"
  def mark_entry_read
    change_entry_read_state("read")
  end

  # @API
  # Mark a discussion entry as unread.
  #
  # No request fields are necessary.
  #
  # On success, the response will be 204 No Content with an empty body.
  #
  # @example_request
  #
  #   curl 'http://<canvas>/api/v1/courses/<course_id>/discussion_topics/<topic_id>/entries/<entry_id>/read.json' \ 
  #        -X DELETE \ 
  #        -H "Authorization: Bearer <token>"
  def mark_entry_unread
    change_entry_read_state("unread")
  end

  protected
  def require_topic
    @topic = @context.all_discussion_topics.active.find(params[:topic_id])
    return authorized_action(@topic, @current_user, :read)
  end

  def require_initial_post
    return true if !@topic.initial_post_required?(@current_user, @context_enrollment, session)

    # neither the current user nor the enrollment user (if any) has posted yet,
    # so give them the forbidden status
    render :json => 'require_initial_post', :status => :forbidden
    return false
  end

  def build_entry(association)
    association.build(:message => params[:message], :user => @current_user, :discussion_topic => @topic)
  end

  def save_entry
    has_attachment = params[:attachment].present? && params[:attachment].size > 0 && 
      @entry.grants_right?(@current_user, session, :attach)
    return if has_attachment && params[:attachment].size > 1.kilobytes &&
      quota_exceeded(named_context_url(@context, :context_discussion_topic_url, @topic.id))
    if @entry.save
      @entry.update_topic
      log_asset_access(@topic, 'topics', 'topics', 'participate')
      @entry.context_module_action
      if has_attachment
        @attachment = @context.attachments.create(:uploaded_data => params[:attachment])
        @entry.attachment = @attachment
        @entry.save
      end
      render :json => discussion_entry_api_json([@entry], @context, @current_user, session, [:user_name]).first, :status => :created
    else
      render :json => @entry.errors, :status => :bad_request
    end
  end

  def visible_topics(topic)
    # conflate entries from all child topics for groups the user can access
    topics = [topic]
    if topic.for_group_assignment? && !topic.child_topics.empty?
      groups = topic.assignment.group_category.groups.active.select do |group|
        group.grants_right?(@current_user, session, :read)
      end
      topic.child_topics.each{ |t| topics << t if groups.include?(t.context) }
    end
    topics
  end

  def all_entries(topic)
    DiscussionEntry.all_for_topics(visible_topics(topic)).active
  end

  def root_entries(topic)
    DiscussionEntry.top_level_for_topics(visible_topics(topic)).active
  end

  def reply_entries(entry)
    entry.flattened_discussion_subentries.active
  end

  def change_topic_read_state(new_state)
    if authorized_action(@topic, @current_user, :read)
      topic_participant = @topic.change_read_state(new_state, @current_user)
      if topic_participant.present? && (topic_participant == true || topic_participant.errors.blank?)
        render :nothing => true, :status => :no_content
      else
        error_json = topic_participant.errors.to_json rescue {}
        render :json => error_json, :status => :bad_request
      end
    end
  end

  def change_entry_read_state(new_state)
    @entry = @topic.discussion_entries.find(params[:entry_id])
    if authorized_action(@entry, @current_user, :read)
      entry_participant = @entry.change_read_state(new_state, @current_user)
      if entry_participant.present? && (entry_participant == true || entry_participant.errors.blank?)
        render :nothing => true, :status => :no_content
      else
        error_json = entry_participant.errors.to_json rescue {}
        render :json => error_json, :status => :bad_request
      end
    end
  end
end
