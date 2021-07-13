require "fileutils"
require "shellwords"
require_relative "../../../synced_folders/unix_mount_helpers"

module VagrantPlugins
  module GuestOpenBSD
    module Cap
      class MountSMBSharedFolder

        extend SyncedFolder::UnixMountHelpers

        # Mounts and SMB folder on OpenBSD guest
        #
        # @param [Machine] machine
        # @param [String] name of mount
        # @param [String] path of mount on guest
        # @param [Hash] hash of mount options 
        def self.mount_smb_shared_folder(machine, name, guestpath, options)

          expanded_guest_path = machine.guest.capability(
            :shell_expand_guest_path, guestpath)
          options[:smb_id] ||= name
          mount_options, _, _ = self.mount_options(machine, name, expanded_guest_path, options)

          # If a domain is provided in the username, separate it
          username, domain = (options[:smb_username] || '').split('@', 2)
          smb_password = options[:smb_password]
          # Ensure password is scrubbed
          Vagrant::Util::CredentialScrubber.sensitive(smb_password)

          conf_path = "/etc/usmb_conf_#{name}"

          mount_command = "usmb -c #{conf_path} #{name}"

          # Create the guest path if it doesn't exist
          machine.communicate.sudo("mkdir -p #{expanded_guest_path}")

          # Write the credentials file
          machine.communicate.sudo(<<-SCRIPT)
cat <<"EOF" >#{conf_path}
<usmbconfig>
<credentials id="cred1">
 <domain>#{domain ? "#{domain}" : ""}</domain>
 <username>#{username}</username>
 <password>#{smb_password}</password>
</credentials>
<mount id="#{name}" credentials="cred1">
  <server>#{options[:smb_host]}</server>
  <share>#{name}</share>
  <mountpoint>#{expanded_guest_path}</mountpoint>
  <options>#{mount_options}</options>
</mount>
</usmbconfig>
EOF
chmod 0600 #{conf_path}
SCRIPT
          # write config file without password, for unmounting purposes
          machine.communicate.sudo(<<-SCRIPT)
cat <<"EOF" >#{conf_path}_umount
<usmbconfig>
<credentials id="cred1">
 <domain>#{domain ? "#{domain}" : ""}</domain>
 <username>#{username}</username>
</credentials>
<mount id="#{name}" credentials="cred1">
  <server>#{options[:smb_host]}</server>
  <share>#{name}</share>
  <mountpoint>#{expanded_guest_path}</mountpoint>
  <options>#{mount_options}</options>
</mount>
</usmbconfig>
EOF
chmod 0600 #{conf_path}_umount
SCRIPT

          # Attempt to mount the folder. We retry here a few times because
          # it can fail early on.
          begin
            retryable(on: Vagrant::Errors::LinuxMountFailed, tries: 10, sleep: 2) do
              no_such_device = false
              stderr = ""
              status = machine.communicate.sudo(mount_command, error_check: false) do |type, data|
                if type == :stderr
                  no_such_device = true if data =~ /No such device/i
                  stderr += data.to_s
                end
              end
              if status != 0 || no_such_device
                raise Vagrant::Errors::LinuxMountFailed,
                  command: mount_command,
                  output: stderr
              end
            end
          ensure
            # Always remove credentials file after mounting attempts
            # have been completed. We leave the no-password one for unmounting purposes.
            if !machine.config.vm.allow_fstab_modification
              machine.communicate.sudo("rm #{conf_path}")
            end
          end

          emit_upstart_notification(machine, expanded_guest_path)
        end

        def self.mount_options(machine, name, guest_path, options)
          mount_options = options.fetch(:mount_options, [])
          #options[:smb_id] ||= name
          detected_ids = detect_owner_group_ids(machine, guest_path, mount_options, options)
          mount_uid = detected_ids[:uid]
          mount_gid = detected_ids[:gid]

          mnt_opts = []
          mnt_opts << "uid=#{mount_uid}"
          mnt_opts << "gid=#{mount_gid}"
          mnt_opts << "allow_other"
          mount_options = mnt_opts.join(",")

          return mount_options, mount_uid, mount_gid
        end

      end

    end
  end
end
