# frozen_string_literal: true

require 'config_skeleton'

RSpec.describe ConfigSkeleton do
  let(:cfg_file_path) { "#{Dir.pwd}/cfg.txt" }
  let(:env) do
    {
      "MY_CONFIG_FILE" => cfg_file_path,
      "MY_CONFIG_WATCH_FILE" => tmp_watch_file.path,
      "MY_CONFIG_LOG_LEVEL" => "info"
    }
  end
  let(:tmp_watch_file) { Tempfile.new }

  class MyConfig < ConfigSkeleton
    string :MY_CONFIG_FILE
    string :MY_CONFIG_WATCH_FILE

    def initialize(*_)
      super
      watch config.watch_file
    end

    def config_file
      config.file
    end

    def config_data
      "important config data #{SecureRandom.hex(6)}\n"
    end

    def reload_server
      true
    end
  end

  let(:subject) { MyConfig.new(env) }

  before do
    if File.file?(cfg_file_path)
      FileUtils.rm(cfg_file_path)
    end
    FileUtils.touch(cfg_file_path)
  end

  it "respects the shutdown and breaks the run loop" do
    thread = Thread.new { subject.run }
    wait_until { File.read(cfg_file_path) != "" }
    subject.shutdown
    wait_until { !thread.alive? }
    expect(thread.alive?).to eq(false)
  end

  it "watches for file changes and regenerates config on change" do
    Thread.new { subject.run }
    wait_until { File.read(cfg_file_path) != "" }
    config_before_file_change = File.read(cfg_file_path)
    File.write(tmp_watch_file, "some data");
    config_after_file_change = nil
    wait_until { config_after_file_change = File.read(cfg_file_path) != config_before_file_change }
    expect(config_before_file_change).not_to eq(config_after_file_change)
  end

  it "watches for a regen trigger write and regenerate the config" do
    notif = subject.regen_notifier
    Thread.new { subject.run }

    wait_until { File.read(cfg_file_path) != "" }
    config_before_trigger = File.read(cfg_file_path)
    notif.trigger_regen
    config_after_trigger = nil
    wait_until { config_after_trigger = File.read(cfg_file_path) != config_before_trigger }
    expect(config_before_trigger).not_to eq(config_after_trigger)

    config_before_trigger = File.read(cfg_file_path)
    notif.trigger_regen
    config_after_trigger = nil
    wait_until { config_after_trigger = File.read(cfg_file_path) != config_before_trigger }
    expect(config_before_trigger).not_to eq(config_after_trigger)
  end

  it "listens for a SIGHUP signal and regenerates the config" do
    pid = fork do
      # needs start instead of run otherwise signals are not trapped
      subject.start
    end
    wait_until { File.read(cfg_file_path) != "" }

    config_before_hup = File.read(cfg_file_path)
    Process.kill('HUP', pid)
    Process.kill('TERM', pid)
    config_after_hup = nil
    wait_until { config_after_hup = File.read(cfg_file_path) != config_before_hup }
    expect(config_before_hup).not_to eq(config_after_hup)
  end

  def wait_until
    Timeout::timeout(2) do
      loop do
        condition = yield
        if condition
          break
        end
      end
    end
  end
end
