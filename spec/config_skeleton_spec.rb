# frozen_string_literal: true

require 'config_skeleton'

RSpec.describe ConfigSkeleton do
  let(:env) do
    {
      "MY_CONFIG_FILE" => tmp_config_file.path,
      "MY_CONFIG_WATCH_FILE" => tmp_watch_file.path
    }
  end
  let(:tmp_config_file) { Tempfile.new }
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
      "nothing to see here\n"
    end

    def reload_server
      true
    end
  end

  let(:subject) { MyConfig.new(env) }
  
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
    trig = subject.regen_trigger
    Thread.new { sleep 0.5; trig.write(".") }
    Thread.new { sleep 1.5; trig.write(".") }
    Thread.new { sleep 2.5; subject.shutdown }
    subject.run
  end
end
