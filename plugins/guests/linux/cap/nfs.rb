require_relative "../../../synced_folders/unix_mount_helpers"

module VagrantPlugins
  module GuestLinux
    module Cap
      class NFS
        extend SyncedFolder::UnixMountHelpers

        def self.nfs_client_installed(machine)
          machine.communicate.test("test -x /sbin/mount.nfs")
        end

        def self.mount_nfs_folder(machine, ip, folders)
          # Mount each folder separately so we can retry.
          folders.each do |name, opts|
            # Shellescape the paths in case they do not have special characters.
            guest_path = Shellwords.escape(opts[:guestpath])
            host_path  = Shellwords.escape(opts[:hostpath])

            mount_opts, _, _ =  opts[:plugin].capability(:mount_options, name, guest_path, opts)
            mount_type = opts[:plugin].capability(:mount_type)

            machine.communicate.sudo("mkdir -p #{guest_path}")

            command = "mount -t #{mount_type} -o #{mount_opts} #{ip}:#{host_path} #{guest_path}"

            # Run the command, raising a specific error.
            retryable(on: Vagrant::Errors::NFSMountFailed, tries: 3, sleep: 5) do
              machine.communicate.sudo(command,
                error_class: Vagrant::Errors::NFSMountFailed,
              )
            end

            emit_upstart_notification(machine, guest_path)
          end
        end
      end
    end
  end
end
