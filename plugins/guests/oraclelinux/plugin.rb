# Copyright (c) 2020, Oracle and/or its affiliates.
# Licensed under the MIT License.

require "vagrant"

module VagrantPlugins
  module GuestOracleLinux
    class Plugin < Vagrant.plugin("2")
      name "Oracle Linux guest"
      description "Oracle Linux guest support."

      guest(:oraclelinux, :redhat) do
        require_relative "guest"
        Guest
      end

      guest_capability(:oraclelinux, :flavor) do
        require_relative "cap/flavor"
        Cap::Flavor
      end
    end
  end
end
