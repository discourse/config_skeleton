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
    expect(subject).to receive(:shutdown).and_call_original
    Thread.new { sleep 0.5; subject.shutdown }
    subject.run
    expect(true).to eq(true)
  end

  it "watches for file changes and regenerates config on change" do
    expect(subject).to receive(:regenerate_config).once.and_call_original
    expect(subject).to receive(:regenerate_config).with(force_reload: true).once.and_call_original
    Thread.new { sleep 0.5; File.write(tmp_watch_file, "some data") }
    Thread.new { sleep 1.5; subject.shutdown }
    subject.run
  end

  it "watches for a regen trigger write and regenerate the config" do
    expect(subject).to receive(:regenerate_config).with(force_reload: true).twice.and_call_original
    expect(subject).to receive(:regenerate_config).once.and_call_original
    notif = subject.regen_notifier
    Thread.new { sleep 0.5; notif.trigger_regen }
    Thread.new { sleep 1.5; notif.trigger_regen }
    Thread.new { sleep 2.5; subject.shutdown }
    subject.run
  end

  it "listens for a SIGHUP signal and regenerates the config" do
    pid = fork do
      # needs start instead of run otherwise signals are not trapped
      subject.start
    end
    sleep 1

    config_before_hup = File.read(cfg_file_path)
    Process.kill('HUP', pid)

    sleep 1
    Process.kill('TERM', pid)
    config_after_hup = File.read(cfg_file_path)
    expect(config_before_hup).not_to eq(config_after_hup)
  end
end
