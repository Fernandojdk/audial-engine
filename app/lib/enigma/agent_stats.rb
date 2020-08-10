require_relative 'stats_store'
require 'deep_enumerable'

module Enigma
    class AgentStats

    attr_reader :agent
    attr_reader :stats_key

    attr_reader :call_stats
    attr_reader :agent_stats

    attr_reader :default_call_stats
    attr_reader :default_agent_stats

    DEFAULT_AGENT_STATS = {
      timers: {
        talk_time:        0,  # Total number of secondsthis agent has spoken for
        wrapup_time:      0,  # Amount of wrapup time for this agent
        idle_time:        0,  # Amount of idel time for this agent
      },

      counters: {
        calls:            0,  # Number of calls this agent has handled
      },

      gauges: {       
      }
    }.freeze

    # Initialise the stats class, pull existing stats from redis
    def initialize( agent )
      @agent = agent
      @stats_key = "agent:#{@agent.extension}"

      @default_agent_stats = DEFAULT_AGENT_STATS.deep_dup

      @agent_stats = Enigma::StatsStore.new "#{@stats_key}", @default_agent_stats
      Celluloid::Actor["#{@stats_key}"] = @agent_stats
      ObjectSpace.define_finalizer(self, proc {
        @agent_stats.async.terminate
      })
    end

    # Account a call which has just finished wrapup
    def account_call( talk_time, idle_time, wrapup_time )
      stats = DEFAULT_AGENT_STATS.deep_dup

      stats[:timers][:idle_time] = idle_time if idle_time.to_i > 0    # How long the agent was on hold for before receiving this call
      stats[:timers][:wrapup_time] = wrapup_time if wrapup_time.to_i > 0  # How long the agent was wrapping this call up for
      stats[:timers][:talk_time] = talk_time if talk_time.to_i > 0 # How long the agent was on this call for
      stats[:counters][:calls] = 1 if talk_time.to_i > 0

      @agent_stats.update_stats stats
    end

  end
end
