# Copyright (c) 2020, Oracle and/or its affiliates.
# Licensed under the MIT License.

module VagrantPlugins
  module PodmanProvisioner
    module Cap
      module OracleLinux
        module PodmanInstall
          def self.podman_install(machine, kubic)
            case machine.guest.capability("flavor")
            when :oraclelinux_7
              machine.communicate.tap do |comm|
                comm.sudo("yum install -y yum-utils oraclelinux-developer-release-el7")
                comm.sudo("yum-config-manager --enable ol7_addons ol7_developer")
                comm.sudo("yum install -y podman slirp4netns")
              end
            when :oraclelinux_8
              machine.communicate.sudo("dnf module install -y container-tools:ol8")
            end
          end
        end
      end
    end
  end
end
