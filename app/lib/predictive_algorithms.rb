module TFDialer
  module PredicitiveAlgorithms
    module Forati

      # Average talk time is calculated over a 5 minute rolling window interval and updated every 5 minutes
      # Call dialing interval is 1 second
      # Average hold time is calculated over the last 5 minutes and updated every 5 minutes
      def run(available_agents, desired_agent_occupation, avg_talk_time, avg_hold_time, calls_answered, calls_made, current_dialed_calls, calls_dropped, max_AR, max_TQ)
        lambda_m = _max_outbound_dial_rate(available_agents, desired_agent_occupation, avg_talk_time, calls_answered, calls_made, current_dialed_calls)
        ar = _abandon_rate(calls_dropped, calls_answered)

        if (ar < max_AR)
          if (avg_hold_time > max_TQ)
            # Stop dialing as the waiting time is too high
            lambda_m = 0
          end
        else
          # Stop dialing as the abandon rate is too high
          lambda_m = 0
        end

        lambda_m
      end

      # How many seconds between originating calls
      def dial_interval(lambda_m, current_interval = 1)
        if (lambda_m == 0)
          t = current_interval
        else
          t = (1.0/lambda_m)
        end
        # Round off to 3 decimal places of millisecond accuracy
        t.round(3)
      end

      def _hit_rate(answered, made)
        answered.to_f/made.to_f
      end

      def _service_time(avg_talk_time, wrapup_time)
        avg_talk_time + wrapup_time
      end

      # in_less_than_s defines the number of calls answered in less than s seconds
      # during the service level interval
      # calls_answered defines all the calls answered in this period
      def _service_level(in_less_than_s, calls_answered)
        in_less_than_s.to_f/calls_answered.to_f
      end

      # The number of calls that get hungup before an agent handles them
      def _abandon_rate(dropped, answered)
        dropped.to_f/answered.to_f
      end

      # total_call_time => active talk time of an agent over the interval
      # interval_time => the total interval time
      def _agents_occupation(total_call_time, interval_time)
        total_call_time.to_f/interval_time.to_f
      end

      # The number of calls actually reaching the cutomer
      def _call_volume(answered, dropped)
        answered - dropped
      end

      # agent_occupation is the percentage we wish to obtain
      def _max_offered_traffic(available_agents, desired_agent_occupation)
        available_agents * desired_agent_occupation
      end

      # Run the algorithm for 20 minutes initially, just dialing 1 call per agent
      # this is the configuration time
      # then after that every 5 minutes we recalculate our lambda_m
      # while every second we palce the lambda_m number of calls
      # NOTE: available_agents refers to the number fo agents actually working on the campaign
      # not just those waiting for calls
      def _max_outbound_dial_rate(available_agents, desired_agent_occupation, avg_talk_time, calls_answered, calls_made, current_dialed_calls)
        t_max = _max_offered_traffic(available_agents, desired_agent_occupation)
        p = _hit_rate(calls_answered, calls_made)

        can_dial = (t_max / (p*avg_talk_time)) - current_dialed_calls

        max_dial_rate = min( max(0, can_dial), available_agents )
      end
    end
  end
end
