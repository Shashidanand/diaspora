#   Copyright (c) 2010-2011, Diaspora Inc.  This file is
#   licensed under the Affero General Public License version 3 or later.  See
#   the COPYRIGHT file.


class Postzord::Dispatcher
  require File.join(Rails.root, 'lib/postzord/dispatcher/private')
  require File.join(Rails.root, 'lib/postzord/dispatcher/public')

  attr_reader :sender, :object, :xml, :subscribers

  # @return [Postzord::Dispatcher] Public or private dispatcher depending on the object's intended audience
  def self.build(user, object, opts={})
    unless object.respond_to? :to_diaspora_xml
      raise 'this object does not respond_to? to_diaspora xml.  try including Diaspora::Webhooks into your object'
    end

    if self.object_should_be_processed_as_public?(object)
      Postzord::Dispatcher::Public.new(user, object, opts)
    else
      Postzord::Dispatcher::Private.new(user, object, opts)
    end
  end

  # @param object [Object]
  # @return [Boolean]
  def self.object_should_be_processed_as_public?(object)
    if object.respond_to?(:public?) && object.public?
      true
    else
      false
    end
  end 

  # @return [Object]
  def post(opts={})
    self.post_to_subscribers if @subscribers.present?
    self.deliver_to_services(opts[:url], opts[:services] || [])
    self.process_after_dispatch_hooks
    @object
  end

  protected

  # @return [Object]
  def process_after_dispatch_hooks
    @object.after_dispatch(@sender)
    @object
  end

  def post_to_subscribers
    remote_people, local_people = @subscribers.partition{ |person| person.owner_id.nil? }

    if @object.respond_to?(:relayable?) && @sender.owns?(@object.parent)
      self.socket_and_notify_local_users(local_people)
    else
      self.deliver_to_local(local_people)
    end

    self.deliver_to_remote(remote_people)
  end

  # @return [Array<Person>] Recipients of the object, minus any additional subscribers
  def subscribers_from_object
    @object.subscribers(@sender)
  end

  # @param local_people [Array<People>]
  # @return [ActiveRecord::Association<User>, Array]
  def fetch_local_users(people)
    return [] if people.blank?
    user_ids = people.map{|x| x.owner_id }
    User.where(:id => user_ids)
  end

  # @param remote_people [Array<Person>] Recipients of the post on other pods
  def deliver_to_remote(remote_people)
    return if remote_people.blank?
    queue_remote_delivery_job(remote_people)
  end

  # Enqueues a job in Resque
  # @param remote_people [Array<Person>] Recipients of the post on other pods
  # @return [void]
  def queue_remote_delivery_job(remote_people)
    Resque.enqueue(Jobs::HttpMulti, 
                   @sender.id, 
                   Base64.encode64s(@object.to_diaspora_xml), 
                   remote_people.map{|p| p.id}, 
                   self.class.to_s)
  end

  # @param people [Array<Person>] Recipients of the post
  def deliver_to_local(people)
    return if people.blank? || @object.is_a?(Profile)
    if @object.respond_to?(:persisted?) && !@object.is_a?(Conversation)
      batch_deliver_to_local(people)
    else
      people.each do |person|
        Rails.logger.info("event=push route=local sender=#{@sender.person.diaspora_handle} recipient=#{person.diaspora_handle} payload_type=#{@object.class}")
        Resque.enqueue(Jobs::Receive, person.owner_id, @xml, @sender.person.id)
      end
    end
  end

  # @param people [Array<Person>] Recipients of the post
  def batch_deliver_to_local(people)
    ids = people.map{ |p| p.owner_id }
    Resque.enqueue(Jobs::ReceiveLocalBatch, @object.class.to_s, @object.id, ids)
    Rails.logger.info("event=push route=local sender=#{@sender.person.diaspora_handle} recipients=#{ids.join(',')} payload_type=#{@object.class}")
  end

  def deliver_to_hub
    Rails.logger.debug("event=post_to_service type=pubsub sender_handle=#{@sender.diaspora_handle}")
    Resque.enqueue(Jobs::PublishToHub, @sender.public_url)
  end

  # @param url [String]
  # @param services [Array<Service>]
  def deliver_to_services(url, services)
    if @object.respond_to?(:public) && @object.public
      deliver_to_hub
    end
    if @object.instance_of?(StatusMessage)
      services.each do |service|
        Resque.enqueue(Jobs::PostToService, service.id, @object.id, url)
      end
    end
  end

  # @param local_people [Array<People>]
  def socket_and_notify_local_users(local_people)
    local_users = fetch_local_users(local_people)
    self.notify_users(local_users)
    local_users << @sender if @object.author.local?
    self.socket_to_users(local_users)
  end

  # @param services [Array<User>]
  def notify_users(users)
    return unless users.present? && @object.respond_to?(:persisted?)

    #temp hax
    unless object_is_related_to_diaspora_hq?
      Resque.enqueue(Jobs::NotifyLocalUsers, users.map{|u| u.id}, @object.class.to_s, @object.id, @object.author.id)
    end
  end

  def object_is_related_to_diaspora_hq?
    (@object.author.diaspora_handle == 'diasporahq@joindiaspora.com' || (@object.respond_to?(:relayable?) && @object.parent.author.diaspora_handle == 'diasporahq@joindiaspora.com'))
  end

  # @param services [Array<User>]
  def socket_to_users(users)
    return unless users.present? && @object.respond_to?(:socket_to_user)
    users.each do |user|
      @object.socket_to_user(user)
    end
  end
end

