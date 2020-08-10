class OutboundAgentController < Adhearsion::CallController
  def run
    answer
    @agent, @campaign = metadata[:agent], metadata[:campaign]

    call.on_joined do |event|
      callee_call = call.peers[event.call_uri]
      logger.debug "Agent #{@agent.extension} received a call from #{callee_call.variables['callee'].callee_address}"

      callee_call[:callee].handled_by(@agent) if callee_call
      # @agent.checkout
    end

    # As the agent is not yet in the queue we can call this directly to set the agent to available
    # before putting the agent in a queue
    @agent.checkin

    call.auto_hangup = false
  end
end
