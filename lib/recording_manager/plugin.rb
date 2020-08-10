require 'fileutils'
require 'uri'
require 'rb-inotify'

class RecordingFileMonitor
  include Celluloid

  def initialize
    @recording_dir_files = '/var/punchblock/record/'
    @notifier = INotify::Notifier.new
    self.async.start_file_monitoring
  end

  def start_file_monitoring
    logger.info "Recording file monitoring starting"

    @notifier.watch(@recording_dir_files, :create) do |event|
      logger.debug "File #{event.name} has been created."
      unless %w(-in -out).any?{|str| event.name.downcase.include? str}
        Celluloid::Actor[:recording_manager].store_recording(File.join(@recording_dir_files, event.name))
      end
    end

    @notifier.run
  end
end

class RecordingListMonitor
  include Celluloid

  def initialize
    @recording_key = Celluloid::Actor[:recording_manager].recording_move_key
    @redis = Redis.new(:url => RecordingManager::Plugin.config.uri, :db => 0)

    self.async.start_list_monitoring
  end

  def start_list_monitoring
    logger.info "Recording list monitoring starting"

    while true
      blocking_reliable_pop
    end
  end

  def blocking_reliable_pop
    recording = @redis.brpoplpush @recording_key, @recording_key
    recording_obj = JSON.parse(recording)

    Celluloid::Actor[:recording_manager].move_recording(recording_obj['recording_location'], recording_obj['new_location'])

    @redis.lrem @recording_key, 0, recording
  end
end

class RecordingManager
  include Celluloid
  attr_reader :recording_move
  attr_reader :recording_mutex
  attr_reader :recording_store


  def initialize
    @redis = Redis.new(:url => RecordingManager::Plugin.config.uri, :db => 0)
    @recording_move = 'enigma:recordings:move'
    @recording_mutex = 'enigma:recordings:mutex'
    @recording_store = 'enigma:recordings:store'

    move_old_recordings

    # TODO - DIAL-463 - Move logging to separate Monitoring Celluloid Actor
    every(3600) do
      all_actors = Celluloid::Actor.all.to_set
      logger.info "System Actor Count: #{all_actors.length} Alive: #{all_actors.select(&:alive?).length}"
      debug_actors
    end
  end

  def debug_actors
    actor_hash = Hash.new

    Celluloid.internal_pool.each do |t|
      next unless t.role == :actor
      if t.actor && t.actor.respond_to?(:proxy)
        if actor_hash.has_key?(t.actor.name)
            actor_hash[t.actor.name] = actor_hash[t.actor.name] += 1
        else
          actor_hash[t.actor.name] = 1
        end
      end
    end
    actor_hash.each_key do |key|
      logger.debug "Actor Count Type[#{key}] Total: #{actor_hash[key]}"
    end
  end

  def move_old_recordings
    recordings = @redis.hgetall(@recording_store)
    recordings.each {|filename, recording|
      logger.debug "Moving old recording: #{filename}"
      add_recording(filename, recording)
    }
  end

  def move_recording(recording_location, new_path)
    logger.debug "Trying to move recordings from  #{recording_location} to #{new_path}"

    if File.exist?(recording_location)
      FileUtils.mkdir_p(File.dirname(new_path))
      FileUtils.mv recording_location, new_path, force: true
      logger.info "Moved recording from #{recording_location} to #{new_path}"
    else
      logger.warn "The recording #{recording_location} could not be found."
    end

    FileUtils.rm recording_location if File.exist?(recording_location) && File.exist?(new_path)
  end


  def store_recording(recording_location, new_location = nil)

    filename = File.basename(recording_location)
    count = @redis.zincrby(@recording_mutex, 1, filename)

    if recording_location && new_location
      logger.debug "Watching for recording #{recording_location} -> #{new_location}"
      recording = {
          recording_location: recording_location,
          new_location: new_location
      }
      @redis.hset(@recording_store, filename, recording.to_json)
    end

    if count > 1
      recording = @redis.hget(@recording_store,filename)

      if recording
        add_recording(filename, recording)
      else
        logger.error "Unable to find #{filename} in redis store #{@recording_store}"
      end
    end
  end

  def add_recording(filename, recording)
    @redis.rpush(@recording_move, recording)
    logger.debug "Pushing #{filename} to redis list #{@recording_move}"
    #Cleaning up
    @redis.hdel(@recording_store, filename)
    @redis.zrem(@recording_mutex, filename)
  end

  def recording_move_key
    @recording_move
  end

  class Plugin < Adhearsion::Plugin
    config :recording_manager do
      storage_dir '/var/teleforge/recordings/dialer', :desc => 'Directory to store recordings in'
      uri       'redis://localhost:6379', :desc => 'URI to the Redis instance.'
      #TODO - implement -> format 'WAV', :desc => 'Recording format to pass to adhearsion and asterisk'
    end

    run :recording_manager do
      RecordingManager.supervise_as :recording_manager
      RecordingFileMonitor.supervise_as :recording_file_monitor
      RecordingListMonitor.supervise_as :recording_list_monitor
    end
  end
end
