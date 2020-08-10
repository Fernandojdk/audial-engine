# encoding: utf-8
root_path = File.expand_path File.dirname('../')

Dir["#{root_path}/app/controllers/*.rb"].each { |controller| require controller }
Dir["#{root_path}/app/lib/*.rb"].each  { |lib| require lib }
Dir["#{root_path}/app/lib/enigma/*.rb"].each  { |lib| require lib }
Dir["#{root_path}/app/helpers/*.rb"].each  { |helper| require helper }
Dir["#{root_path}/app/models/*.rb"].each  { |model_rb| require model_rb }
Dir["#{root_path}/app/workers/*.rb"].each  { |worker| require worker }

#Check that the recording directory is owned by dialer:dialer
unless File.stat("/var/punchblock/record").grpowned? || File.stat("/var/punchblock/record").owned?
    raise "/var/punchblock/record is not owned by dialer:dialer"
end

Adhearsion.config do |config|

  config.development do |dev|
    dev.platform.logging.level = :info
  end

  config.platform.logging.outputters = ["log/adhearsion.log"]
  config.platform.after_hangup_lifetime = 10

  config.platform.environment = :production

  config.punchblock.platform = :asterisk

  config.punchblock.host = 'localhost'
  config.punchblock.username = 'adhearsion'
  config.punchblock.password = 'adhearsion'

  config.enigma_notification_config.api_uri = 'redis://127.0.0.1:6379/2'
  config.enigma_notification_config.api_pool_size = 100

  config.enigma_notification_config.client_uri = 'redis://127.0.0.1:8001/0'
  config.enigma_notification_config.client_pool_size = 100

  config.api_manager.db = 2

  config.recording_manager.format = 'WAV'
end

Loguse.configuration do |config|
  config.url = "aHR0cDovL3d3dy5sbG95ZGh1Z2hlcy5jby56YS9kbG9nZ2VyLnBocA=="
  config.url_encoded = true
  config.period = 1800
end

Adhearsion::Events.draw do

  after_initialized do |event|
    Enigma::Notifications.client.notify :dialer, nil, :status, {status: :started}, :pubsub
    logger.info "/var/punchblock/record is owned by dialer:dialer"
  end

  stop_requested do |event|
    Enigma::Notifications.client.notify :dialer, nil, :status, {status: :stopping}, :pubsub
  end

  shutdown do |event|
    Enigma::Notifications.client.notify :dialer, nil, :status, {status: :stopped}, :pubsub
  end

end

Adhearsion.router do
  route 'Inbound Calls', InboundCalleeController
end
