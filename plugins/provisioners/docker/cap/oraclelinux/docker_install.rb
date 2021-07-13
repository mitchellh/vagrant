# Copyright (c) 2020, Oracle and/or its affiliates.
# Licensed under the MIT License.

# Enable the Docker provisioner for guests running Oracle Linux 7 / UEK5

module VagrantPlugins
  module DockerProvisioner
    module Cap
      module OracleLinux
        module DockerInstall
          def self.docker_install(machine)
            case machine.guest.capability("flavor")
            when :oraclelinux_7
              kernel = nil
              machine.communicate.execute "uname -r" do |type, data|
                if type == :stdout
                  kernel = data.chomp
                end
              end
              unless kernel.to_s.match(/4\.14\.35-.*el7uek/)
                raise DockerError, :not_supported
              end
              machine.communicate.tap do |comm|
                comm.sudo("yum install -y -q yum-utils")
                comm.sudo("yum-config-manager --enable ol7_addons")
                comm.sudo("yum install -y -q docker-engine docker-cli")
                # Select appropriate driver based on the filesystem type
                comm.sudo <<~SHELL
                  fstype=$(stat -f -c %T /var/lib/docker || stat -f -c %T /var/lib)
                  storage_driver=""
                  case "${fstype}" in
                    btrfs)
                      storage_driver="btrfs"
                      ;;
                    xfs)
                      storage_driver="overlay2"
                      ;;
                  esac
                  if [[ -n ${storage_driver} ]]; then
                    [ ! -d /etc/docker ] && mkdir -m 0770 /etc/docker && chown root:root /etc/docker
                    echo -e "{\n    \\"storage-driver\\": \\"${storage_driver}\\"\n}" > /etc/docker/daemon.json 
                  fi
                SHELL
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
