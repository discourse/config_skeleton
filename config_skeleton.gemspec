# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name = "config_skeleton"
  s.version = "2.2.1"

  s.platform = Gem::Platform::RUBY
  s.summary  = "Dynamically generate configs and reload servers"
  s.authors  = ["Matt Palmer", "Discourse Team"]
  s.email    = ["matt.palmer@discourse.org", "team@discourse.org"]
  s.homepage = "https://github.com/discourse/config_skeleton"

  s.files = `git ls-files -z`.split("\0").reject { |f| f =~ /^(G|spec|Rakefile)/ }

  s.required_ruby_version = ">= 2.5.0"

  s.add_runtime_dependency 'diffy', '~> 3.0'
  s.add_runtime_dependency 'rb-inotify', '~> 0.9'
  s.add_runtime_dependency 'service_skeleton', "~> 2.0"
  s.add_runtime_dependency 'webrick'

  s.add_development_dependency 'bundler'
  s.add_development_dependency 'rake', "~> 13.0"
  s.add_development_dependency 'redcarpet'
  s.add_development_dependency 'rubocop-discourse', '~> 2.4.1'
  s.add_development_dependency 'yard'
  s.add_development_dependency 'rspec'
  s.add_development_dependency 'pry'
  s.add_development_dependency 'pry-byebug'
end
