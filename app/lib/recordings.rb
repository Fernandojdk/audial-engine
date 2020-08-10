require 'fileutils'
require 'uri'

module TFDialer
  module Recordings
    module_function

    def dir_path(timestamp)
      timestamp.strftime("%Y/%m/%d")
    end

    def get_recording_location(ts, call_id, to, from)
      dir = File.join(RecordingManager::Plugin.config.storage_dir, dir_path(ts))
      new_filename = ts.strftime("dialer-#{to}-#{from}-%Y%m%d-#{call_id}")
      File.join(dir, new_filename)
    end

  end
end
