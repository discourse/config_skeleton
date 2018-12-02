begin
  require 'git-version-bump'
rescue LoadError
  nil
end

Gem::Specification.new do |s|
  s.name = "config_skeleton"

  s.version = GVB.version rescue "0.0.0.1.NOGVB"
  s.date    = GVB.date    rescue Time.now.strftime("%Y-%m-%d")

  s.platform = Gem::Platform::RUBY

  s.summary  = "Dynamically generate configs and reload servers"

  s.authors  = ["Matt Palmer"]
  s.email    = ["matt.palmer@discourse.org"]
  s.homepage = "https://github.com/discourse/config_skeleton"

  s.files = `git ls-files -z`.split("\0").reject { |f| f =~ /^(G|spec|Rakefile)/ }

  s.required_ruby_version = ">= 2.3.0"

  s.add_runtime_dependency 'diffy', '~> 3.0'
  s.add_runtime_dependency 'frankenstein', '~> 1.0'
  s.add_runtime_dependency 'rb-inotify', '~> 0.9'
  s.add_runtime_dependency 'service_skeleton', '> 0.a'

  s.add_development_dependency 'bundler'
  s.add_development_dependency 'github-release'
  s.add_development_dependency 'git-version-bump'
  s.add_development_dependency 'rake', "~> 12.0"
  s.add_development_dependency 'redcarpet'
  s.add_development_dependency 'rubocop'
  s.add_development_dependency 'yard'
end
