require_relative 'stats_store'
require 'deep_enumerable'

module Enigma
    class CampaignStats

  	attr_reader :campaign
  	attr_reader :stats_key

  	attr_reader :call_stats
  	attr_reader :agent_stats
  	attr_reader :queue_stats
    attr_reader :default_call_stats
    attr_reader :default_agent_stats

  	DEFAULT_CALL_STATS = {
      timers: {
        ring_time:        0,  # Total number of seconds all calls have run for
        hold_time:        0,  # Total amount of time callees spend on hold
        abandon_time:     0,  # The total time someone was on hold before dropping the call
        talk_time:        0,  # Total talk time of agents
      },

      counters: {
        answered:         0,  # Number of calls which have been answered
        unanswered:       0,
        dropped:          0,  # Number of dropped calls
        rejected:         0,  # Number of rejected calls
        failed:           0,  # Number of failed calls
        total_calls:      0,  # Total number of calls made
        total_inbound:    0,  # Total number of inbound calls
        total_outbound:   0,  # Total number of outbound calls
      },

      gauges: {
        callees_remaining:  nil,# Number of callees which still need to be dialled
        callees_queued:     nil,# Number of callees currently queued to be dialled
        callees_completed:  nil,# Number of completed or closed callees
        callees_failed:     nil,# Number of callees which failed due to too many attempts
      }
    }.freeze

    DEFAULT_AGENT_STATS = {
      timers: {
        wrapup_time:    0,  # Total number of seconds agents have been in wrapup
        idle_time:      0,  # Total time agent has been waiting for a call
      },

      counters: {
        active:         0, # Total number of agents in the campaign
        available:      0,
        busy:           0,
        wrapup:         0,
      },

      gauges: {
      }
    }.freeze

    # Initialise the stats class, pull existing stats from redis
    def initialize( campaign )
      @campaign = campaign
      @stats_key = "campaign:#{@campaign.ref}"

      @default_call_stats = DEFAULT_CALL_STATS.deep_dup
      @default_agent_stats = DEFAULT_AGENT_STATS.deep_dup

      @call_stats = Enigma::StatsStore.new "#{@stats_key}:call_stats", @default_call_stats
      @agent_stats = Enigma::StatsStore.new "#{@stats_key}:agent_stats", @default_agent_stats

      Celluloid::Actor["#{@stats_key}:call_stats"] = @call_stats
      Celluloid::Actor["#{@stats_key}:agent_stats"] = @agent_stats

      ObjectSpace.define_finalizer(self, proc {
        @agent_stats.async.terminate
        @call_stats.async.terminate
      })
    end

    # Account a call which has just ended
    def account_call( call_dialled, call_answered, call_handled, call_ended, call_end_reason, call_direction )
      logger.debug "Account Call: D:#{call_dialled.to_i} A:#{call_answered.to_i} J:#{call_handled.to_i} E:#{call_ended.to_i} R:#{call_end_reason}"

      stats = DEFAULT_CALL_STATS.deep_dup

      stats[:timers][:ring_time] = (call_answered.to_i > 0) ? call_answered.to_i - call_dialled.to_i : call_ended.to_i - call_dialled.to_i
      stats[:timers][:talk_time] = call_ended.to_i - call_handled.to_i if call_handled.to_i > 0

      # If the call was handled calc hold time, otherwise calc abandon time
      if call_answered.to_i > 0 && call_handled.to_i > 0
        stats[:timers][:hold_time] = call_handled.to_i - call_answered.to_i
      elsif call_answered.to_i > 0
        stats[:timers][:abandon_time] = call_ended.to_i - call_answered.to_i
        stats[:counters][:dropped] = 1
      end

      stats[:counters][:total_calls]        = 1
      stats[:counters][:answered]           = 1 if call_answered.to_i > 0
      stats[:counters][:unanswered]         = 1 unless call_answered.to_i > 0
      stats[:counters][:rejected]           = 1 if call_end_reason.to_sym == :reject
      stats[:counters][:failed]             = 1 if call_end_reason.to_sym == :failed
      stats[:counters][:total_outbound]     = 1 if call_direction == :outbound
      stats[:counters][:total_inbound]      = 1 if call_direction == :inbound


      logger.debug "Increment stats with: #{stats.inspect}"

      @call_stats.update_stats stats
    end

    def account_callees(callees_remaining, callees_queued, callees_completed, callees_failed)
      stats = DEFAULT_CALL_STATS.deep_dup

      stats[:gauges][:callees_remaining]  = callees_remaining unless callees_remaining.nil?
      stats[:gauges][:callees_queued]     = callees_queued unless callees_queued.nil?
      stats[:gauges][:callees_completed]  = callees_completed unless callees_completed.nil?
      stats[:gauges][:callees_failed]     = callees_failed unless callees_failed.nil?

      @call_stats.update_stats stats
    end

    def account_agent_timers( wrapup_time, idle_time )
      stats = DEFAULT_AGENT_STATS.deep_dup

      stats[:timers][:wrapup_time] = wrapup_time if wrapup_time.to_i > 0
      stats[:timers][:idle_time] = idle_time if idle_time.to_i > 0

      @agent_stats.update_stats stats

    end

    def account_agent( new_status, old_status = nil )
      stats = DEFAULT_AGENT_STATS.deep_dup

      stats[:counters][old_status] = -1 unless old_status.nil?
      stats[:counters][new_status] =  1

      @agent_stats.update_stats stats
    end

  end
end
