# Copyright (c) 2020, Oracle and/or its affiliates.
# Licensed under the MIT License.

module VagrantPlugins
  module DockerProvisioner
    module Cap
      module OracleLinux
        module DockerStartService
          def self.docker_start_service(machine)
            case machine.guest.capability("flavor")
            when :oraclelinux_7
              machine.communicate.tap do |comm|
                comm.sudo("systemctl enable --now docker.service")
              end
            else
              raise DockerError, :not_supported
            end
          end
        end
      end
    end
  end
end
