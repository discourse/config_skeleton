The `ConfigSkeleton` provides a framework for creating a common class of
service which periodically (or in response to external stimulii) rewrites
a file on disk and (optionally) causes a stimulus to be sent, in turn, to
another process.


# Installation

It's a gem:

    gem install config_skeleton

There's also the wonders of [the Gemfile](http://bundler.io):

    gem 'config_skeleton'

If you're the sturdy type that likes to run from git:

    rake install

Or, if you've eschewed the convenience of Rubygems entirely, then you
presumably know what to do already.


# Usage

A single execution of configuration generation can be performed by specifying
the `SERVICE_NAME_CONFIG_ONESHOT=true` environment variable.

All of the documentation is provided in the [ConfigSkeleton class](https://rubydoc.info/gems/config_skeleton/ConfigSkeleton).


# Contributing

Patches can be sent as [a Github pull
request](https://github.com/discourse/config_skeleton).  This project is
intended to be a safe, welcoming space for collaboration, and contributors
are expected to adhere to the [Contributor Covenant code of
conduct](CODE_OF_CONDUCT.md).


# Licence

Unless otherwise stated, everything in this repo is covered by the following
copyright notice:

    Copyright (C) 2020 Civilized Discourse Construction Kit, Inc.

    This program is free software: you can redistribute it and/or modify it
    under the terms of the GNU General Public License version 3, as
    published by the Free Software Foundation.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
