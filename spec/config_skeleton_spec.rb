# frozen_string_literal: true

require 'config_skeleton'

RSpec.describe ConfigSkeleton do
  let(:cfg_file_path) { "#{Dir.pwd}/cfg.txt" }
  let(:env) do
    {
      "MY_CONFIG_FILE" => cfg_file_path,
      "MY_CONFIG_WATCH_FILE" => tmp_watch_file.path,
      "MY_CONFIG_LOG_LEVEL" => "ERROR"
    }
  end
  let(:tmp_watch_file) { Tempfile.new }

  class MyConfig < ConfigSkeleton
    string :MY_CONFIG_FILE
    string :MY_CONFIG_WATCH_FILE

    def initialize(*_, metrics:, config:)
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

    attr_accessor :before_regenerate_data, :after_regenerate_data

    def before_regenerate_config(**kwargs)
      @before_regenerate_data ||= []
      @before_regenerate_data << kwargs
    end

    def after_regenerate_config(**kwargs)
      @after_regenerate_data ||= []
      @after_regenerate_data << kwargs
    end
  end

  let(:runner) { ServiceSkeleton::Runner.new(MyConfig, env) }
  let(:ultravisor) { runner.instance_variable_get(:@ultravisor) }

  def instance
    ultravisor[:my_config].unsafe_instance
  end

  before do
    if File.file?(cfg_file_path)
      FileUtils.rm(cfg_file_path)
    end
    FileUtils.touch(cfg_file_path)
  end

  it "respects the shutdown and breaks the run loop" do
    thread = Thread.new { runner.run }
    wait_until { File.read(cfg_file_path) != "" }
    ultravisor.shutdown
    thread.join(2)
  end

  it "watches for file changes and regenerates config on change" do
    skip("No inotify, no watching for file changes") if ENV["DISABLE_INOTIFY"]

    thread = Thread.new { runner.run }
    wait_until { File.read(cfg_file_path) != "" }
    config_before_file_change = File.read(cfg_file_path)
    File.write(tmp_watch_file, "some data")
    config_after_file_change = nil
    wait_until { config_after_file_change = File.read(cfg_file_path) != config_before_file_change }
    expect(config_before_file_change).not_to eq(config_after_file_change)
    ultravisor.shutdown
    thread.join(2)
  end

  it "watches for a regen trigger write and regenerate the config" do
    thread = Thread.new { runner.run }
    notif = instance.regen_notifier

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

    ultravisor.shutdown
    thread.join(2)
  end

  it "listens for a SIGHUP signal and regenerates the config" do
    pid = fork do
      runner.run
    end
    wait_until { File.read(cfg_file_path) != "" }

    config_before_hup = File.read(cfg_file_path)
    Process.kill('HUP', pid)
    config_after_hup = nil
    wait_until { (config_after_hup = File.read(cfg_file_path)) != config_before_hup }
    expect(config_before_hup).not_to eq(config_after_hup)

    Process.kill('TERM', pid)
    Process.wait(pid)
  end

  it "calls before_regenerate_config with the appropriate arguments" do
    thread = Thread.new { runner.run }

    wait_until { !instance.nil? }
    instance.regen_notifier.trigger_regen

    wait_until { instance.before_regenerate_data&.size == 2 }
    wait_until { instance.after_regenerate_data&.size == 2 }

    expect(instance.before_regenerate_data).to include(
      { force_reload: false, existing_config_hash: kind_of(String), existing_config_data: kind_of(String) },
      { force_reload: true, existing_config_hash: kind_of(String), existing_config_data: kind_of(String) }
    )

    expect(instance.after_regenerate_data).to include(
      { force_reload: false, config_was_different: true, config_was_cycled: true, new_config_hash: kind_of(String) },
      { force_reload: true, config_was_different: true, config_was_cycled: true, new_config_hash: kind_of(String) }
    )

    ultravisor.shutdown
    thread.join(2)
  end

  def force_regen_with_notifier
    notif = subject.regen_notifier
    Thread.new { subject.run }

    wait_until { File.read(cfg_file_path) != "" }
    config_before_trigger = File.read(cfg_file_path)
    notif.trigger_regen
    config_after_trigger = nil
    wait_until { config_after_trigger = File.read(cfg_file_path) != config_before_trigger }
  end

  def wait_until(timeout = 2, &blk)
    till = Time.now + timeout
    while !blk.call
      sleep 0.001
      raise "Condition not met after 2 seconds" if Time.now > till
    end
  end
end
