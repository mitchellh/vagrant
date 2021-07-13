# Copyright (c) 2020, Oracle and/or its affiliates.
# Licensed under the MIT License.

module VagrantPlugins
  module GuestOracleLinux
    module Cap
      class Flavor
        def self.flavor(machine)
          # Read the version file
          output = ""
          machine.communicate.sudo("cat /etc/oracle-release") do |_, data|
            output = data
          end

          # Detect various flavors we care about
          if output =~ /(Oracle Linux)( .+)? 7/i
            return :oraclelinux_7
          elsif output =~ /(Oracle Linux)( .+)? 8/i
            return :oraclelinux_8
          else
            return :oraclelinux
          end
        end
      end
    end
  end
end
