module Enigma
  class StatsStore
    # FIXME: This should not be an actor
    include Celluloid
    finalizer :shut_down

    attr_reader :stats
    attr_reader :redis_key
    attr_reader :statsd_key

    DEFAULT_STATS = {
      timers: {
      },

      counters: {
      },

      gauges: {         
      }
    }.freeze
    
    def initialize( stats_store_key, default_stats )
      @redis_key = "stats:" + stats_store_key.split('.').join(':')
      @statsd_key = "stats.dialer." + stats_store_key.split(':').join('.')

      @redis_timers    = "#{@redis_key}:timers"
      @redis_counters  = "#{@redis_key}:counters"
      @redis_gauges    = "#{@redis_key}:gauges"

      @stats = DEFAULT_STATS.merge default_stats

      logger.debug "Initialising StatsStore [#{@redis_key}]: with defaults #{default_stats.inspect}  --  #{@stats}"

      @statsd = Statsd.new('localhost').tap{ |sd| sd.namespace = @statsd_key }

      @redis = Enigma::Notifications.client

      # Load the stats and then save them to ensure safe defaults
      load_stats
      save_stats
    end

    def shut_down
      logger.debug "Destroying Instance"
    end

    def update_stats(stats)
      # Remove gauges where there is no new data
      stats[:gauges].delete_if{ |k,v| v.nil? }

      update_redis stats
      update_statsd stats
    end

    def get_stats
      load_stats
      @stats.dup
    end

    private

    def load_stats
      @redis.hgetall(@redis_timers).each_pair do |k, v|
        @stats[:timers][k.to_sym] = v if @stats[:timers][k.to_sym]
      end

      @redis.hgetall(@redis_counters).each_pair do |k, v|
        @stats[:counters][k.to_sym] = v if @stats[:counters][k.to_sym]
      end

      @redis.hgetall(@redis_gauges).each_pair do |k, v|
        @stats[:gauges][k.to_sym] = v if @stats[:gauges][k.to_sym]
      end

      logger.debug "Loaded Redis stats [#{@redis_key}]: #{@stats.inspect}"
    end

    def save_stats
      @redis.pipelined do
          @stats[:timers].each_pair do |k,v|
            @redis.hset @redis_timers, k, v if @stats[:timers][k.to_sym]
          end

          @stats[:counters].each_pair do |k,v|
            @redis.hset @redis_counters, k, v if @stats[:counters][k.to_sym]
          end

          @stats[:gauges].each_pair do |k,v|
            @redis.hset @redis_gauges, k, v if @stats[:gauges][k.to_sym]
          end
      end

      logger.debug "Saved Redis stats [#{@redis_key}]: #{@stats.inspect}"
    end

    def update_redis(stats)
      logger.debug "Updating redis stats with: #{stats.inspect}"

      @redis.pipelined do
          stats[:timers].each_pair do |k,v|
            @redis.hincrby @redis_timers, k, v.to_i*1000 if @stats[:timers][k.to_sym]
          end

          stats[:counters].each_pair do |k,v|
            @redis.hincrby @redis_counters, k, v.to_i if @stats[:counters][k.to_sym]
          end

          stats[:gauges].each_pair do |k,v|
            @redis.hset @redis_gauges, k, v if @stats[:gauges][k.to_sym]
          end
      end
    end

    def update_statsd(stats)
      batch = Statsd::Batch.new @statsd

      stats[:timers].each_pair do |k, v|
        batch.timing "#{k}.timers", v.to_i*1000 if v
      end

      stats[:counters].each_pair do |k, v|
        batch.increment "#{k}.counters" if v.to_i > 0
        batch.decrement "#{k}.counters" if v.to_i < 0
      end

      stats[:gauges].each_pair do |k, v|
        batch.gauge "#{k}.gauges", v if v
      end

      batch.flush
    end
  end
end
