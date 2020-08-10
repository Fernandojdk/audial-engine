require 'redis'
require 'json'
require 'thor'


class CallTest < Thor
  @@redis = Redis.new db: 2

  desc "start CAMPAIGN_REF", "run campaign"
  def start(c_ref)
    @@redis.rpush "enigma:api", {type: :campaign, payload: {
        campaign_ref: c_ref,
        status: "start", 
        settings: { outbound_call_id: "0123456789", notif_type: 'redis' }}
    }.to_json
  end

  desc "stop CAMPAIGN_REF", "complete campaign"
  def stop(c_ref)
    @@redis.rpush "enigma:api", {type: :campaign, payload: {
      campaign_ref: c_ref,
      status: "stop"}
    }.to_json
  end

  desc "agent AGENT_EXT CAMPAIGN_REF", "add agent to campaign or pull out of wrapup"
  def agent(agent_ext, c_ref)
    @@redis.rpush "enigma:api", {type: :agent, payload: {
      campaign_ref: c_ref,
      status: :available,
      extension: agent_ext}
    }.to_json
  end

  desc "offline AGENT_EXT CAMPAIGN_REF", "set agent offline"
  def offline(agent_ext, c_ref)
    @@redis.rpush "enigma:api", {type: :agent, payload: {
      campaign_ref: c_ref,
      status: :offline,
      extension: agent_ext}
    }.to_json
  end

  desc "numbers CAMPAIGN_REF NUMBERS", "add NUMBERS (space separated) to the campaign"
  def numbers(c_ref, *numbers)
    numbers.each do |num|
      new_callee = {call_ref: "call_#{num}", contact_ref: "cellnumber_#{c_ref}_#{num}", number: "#{num}"}
      @@redis.rpush "campaign:#{c_ref}:calls:todial", new_callee.to_json
    end   
  end
end

CallTest.start(ARGV)
