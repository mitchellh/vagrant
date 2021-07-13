# Copyright (c) 2020, Oracle and/or its affiliates.
# Licensed under the MIT License.

require_relative "../facts"
require_relative "../pip/pip"

module VagrantPlugins
  module Ansible
    module Cap
      module Guest
        module OracleLinux
          module AnsibleInstall

            def self.ansible_install(machine, install_mode, ansible_version, pip_args, pip_install_cmd = "")
              case install_mode
              when :pip
                pip_setup machine, pip_install_cmd
                Pip::pip_install machine, "ansible", ansible_version, pip_args, true
              when :pip_args_only
                pip_setup machine, pip_install_cmd
                Pip::pip_install machine, "", "", pip_args, false
              else
                ansible_rpm_install machine
              end
            end

            private

            def self.ansible_rpm_install(machine)
              rpm_package_manager = Facts::rpm_package_manager(machine)
              case machine.guest.capability("flavor")
              when :oraclelinux_7
                package = "oracle-epel-release-el7"
                repo = "ol7_developer_EPEL"
              when :oraclelinux_8
                package = "oracle-epel-release-el8"
                repo = "ol8_developer_EPEL"
              else
                # Go to Fedora EPEL (most probably Oracle Linux 6...)
                dist = nil
                machine.communicate.execute "rpm -E %dist | sed -n 's/.*el\\([0-9]\\).*/\\1/p'" do |type, data|
                    if type == :stdout
                    dist = data.chomp
                  end
                end
                package = "https://dl.fedoraproject.org/pub/epel/epel-release-latest-#{dist}.noarch.rpm"
                repo = "epel"
              end
              epel = machine.communicate.execute "#{rpm_package_manager} repolist #{repo} | grep -q #{repo}", error_check: false
              if epel != 0
                machine.communicate.sudo "#{rpm_package_manager} -y install #{package}"
              end
              machine.communicate.sudo "#{rpm_package_manager} -y --enablerepo=#{repo} install ansible"
            end

            def self.pip_setup(machine, pip_install_cmd = "")
              rpm_package_manager = Facts::rpm_package_manager(machine)
              case machine.guest.capability("flavor")
              when :oraclelinux_7
                packages = "curl gcc libffi-devel openssl-devel python-crypto python-devel python-setuptools"
              when :oraclelinux_8
                packages = "curl gcc libffi-devel openssl-devel python3-cryptography python36-devel python3-setuptools"
                if pip_install_cmd.to_s.empty?
                  pip_install_cmd = "curl https://bootstrap.pypa.io/get-pip.py | sudo python3.6 - --prefix /usr"
                end
              else
                # Most probably Oracle Linux 6; latest pip/ansible won't install
                raise Ansible::Errors::AnsiblePipInstallIsNotSupported
              end

              machine.communicate.sudo("#{rpm_package_manager} -y install #{packages}")
              Pip::get_pip machine, pip_install_cmd
            end

          end
        end
      end
    end
  end
end
