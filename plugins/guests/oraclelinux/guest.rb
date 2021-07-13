# Copyright (c) 2020, Oracle and/or its affiliates.
# Licensed under the MIT License.

module VagrantPlugins
  module GuestOracleLinux
    class Guest < Vagrant.plugin("2", :guest)
      def detect?(machine)
        machine.communicate.test("cat /etc/oracle-release")
      end
    end
  end
end
