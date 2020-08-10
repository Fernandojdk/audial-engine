require 'connection_pool'
require 'redis'
require 'active_support/inflector'
require 'json'

# Base Class for Enigma Notifications
module Enigma
  class Notifier
    attr_accessor :pool
    attr_accessor :scripts
    attr_accessor :pool_name

      # @param name [String] name of the Notifier
      # @param config [Object] config options with redis settings
      def initialize(name, config)
        params = config.to_hash.select { |k,v| !v.nil? }
        timeout = params.delete :pool_timeout
        size = params.delete :pool_size 
        url = params.delete :uri

        @pool_name = name.to_s
        @base_key = params.delete :base_key
        @pool = ConnectionPool.new(size: size, timeout: timeout) { Redis.new :url => url }
        logger.info "[Notifier: #{@pool_name}] Notification connection pool connected to Redis at #{url} with #{size} connections" if @pool

        scripts_dir = params.delete :scripts

        unless scripts_dir.nil? || scripts_dir.empty?
          @scripts = Redis::Scripting::Module.new(self, scripts_dir)
        end
      end

      # Stop the redis connection
      def shutdown
        @pool.shutdown { |conn| conn.close } if @pool
      end

      # Sends a notification
      # @param type [Symbol] (:agent | :campaign | :cdr | :dialer)
      # @param ref [String] Reference for notification
      # @param sub_type [Symbol] (:dial_preview | :call | :cdr | :stats | :status | :queue_calls)
      # @param msg [String] payload of the notification
      # @param method [Symbol] :internal | :queue | :pubsub
      def notify(type, ref, sub_type, msg, method=:queue)
        payload = __make_payload(sub_type, msg, ref)

        redis = @pool.checkout

        case method.to_sym
        when :queue
          key = __make_key(type, nil)
          redis.rpush key, payload
        when :queue_ref
          key = __make_key(type, ref)
          redis.rpush key, payload
        when :pubsub
          key = __make_key(type, ref)
          redis.publish key, payload
        when :all
          keyps = __make_key(type, ref)
          key   = __make_key(type, nil)
          redis.publish keyps, payload
          redis.rpush key, payload
        when :internal
          key = "enigma:pbx:cdrs"
          redis.rpush key, payload
        else
          raise ArgumentError, "[Notifier: #{@pool_name}] Enigma notification method (#{method}) is not valid."
        end

        @pool.checkin
        
      end

      # Generates a key for the Redis PubSub or Queue
      # @param type [String]
      # @param ref [String]
      # @return [String] "#{@base_key}:#{type}:#{ref}"
      def __make_key(type, ref)
        type = type.to_s.pluralize
        key = "#{@base_key}:#{type}"
        key += ":#{ref}" if !ref.nil?
        return key
      end

      # Generates a payload for the Redis PubSub or Queue
      # @param sub_type [Symbol]
      # @param msg [String]
      # @param ref [String]
      # @return [JSON]
      def __make_payload(sub_type, msg, ref=nil)
        pl = {}
        pl[:type] = sub_type
        pl[:payload] = msg
        pl[:payload].merge!( {ref: ref} ) if ref
        pl.to_json
      end

      # todo - Not sure where this method is used
      def method_missing(meth, *args, &blk)
        if @pool
          @pool.with do |conn|
            if conn.respond_to?(meth)
              conn.send meth, *args, &blk
            else
              super
            end
          end
        else
          raise Error, "[Notifier: #{@pool_name}] The connection pool appears to be closed"
        end
      end
      
  end
end
