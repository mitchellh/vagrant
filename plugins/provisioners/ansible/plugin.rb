require "vagrant"

module VagrantPlugins
  module Ansible
    class Plugin < Vagrant.plugin("2")

      name "ansible"
      description <<-DESC
      Provides support for provisioning your virtual machines with Ansible
      from the Vagrant host (`ansible`) or from the guests (`ansible_local`).
      DESC

      config("ansible", :provisioner) do
        require_relative "config/host"
        Config::Host
      end

      config("ansible_local", :provisioner) do
        require_relative "config/guest"
        Config::Guest
      end

      provisioner("ansible") do
        require_relative "provisioner/host"
        Provisioner::Host
      end

      provisioner("ansible_local") do
        require_relative "provisioner/guest"
        Provisioner::Guest
      end

      guest_capability(:linux, :ansible_installed) do
        require_relative "cap/guest/posix/ansible_installed"
        Cap::Guest::POSIX::AnsibleInstalled
      end

      guest_capability(:freebsd, :ansible_installed) do
        require_relative "cap/guest/posix/ansible_installed"
        Cap::Guest::POSIX::AnsibleInstalled
      end

      guest_capability(:arch, :ansible_install) do
        require_relative "cap/guest/arch/ansible_install"
        Cap::Guest::Arch::AnsibleInstall
      end

      guest_capability(:alpine, :ansible_install) do
        require_relative "cap/guest/alpine/ansible_install"
        Cap::Guest::Alpine::AnsibleInstall
      end

      guest_capability(:debian, :ansible_install) do
        require_relative "cap/guest/debian/ansible_install"
        Cap::Guest::Debian::AnsibleInstall
      end

      guest_capability(:ubuntu, :ansible_install) do
        require_relative "cap/guest/ubuntu/ansible_install"
        Cap::Guest::Ubuntu::AnsibleInstall
      end

      guest_capability(:fedora, :ansible_install) do
        require_relative "cap/guest/fedora/ansible_install"
        Cap::Guest::Fedora::AnsibleInstall
      end

      guest_capability(:redhat, :ansible_install) do
        require_relative "cap/guest/redhat/ansible_install"
        Cap::Guest::RedHat::AnsibleInstall
      end

      guest_capability(:oraclelinux, :ansible_install) do
        require_relative "cap/guest/oraclelinux/ansible_install"
        Cap::Guest::OracleLinux::AnsibleInstall
      end

      guest_capability(:suse, :ansible_install) do
        require_relative "cap/guest/suse/ansible_install"
        Cap::Guest::SUSE::AnsibleInstall
      end

      guest_capability(:freebsd, :ansible_install) do
        require_relative "cap/guest/freebsd/ansible_install"
        Cap::Guest::FreeBSD::AnsibleInstall
      end

    end
  end
end
