module VagrantPlugins
  module GuestWindows
    module Cap
      class RSync
        def self.rsync_scrub_guestpath( machine, opts )
          # Windows guests most often use cygwin-dependent rsync utilities
          # that expect "/cygdrive/c" instead of "c:" as the path prefix
          # some vagrant code may pass guest paths with drive-lettered paths here
          opts[:guestpath].gsub( /^([a-zA-Z]):/, '/cygdrive/\1' )
        end

        def self.rsync_pre(machine, opts)
          machine.communicate.tap do |comm|
            # rsync does not construct any gaps in the path to the target directory
            # make sure that all subdirectories are created
            # NB: Per #11878, the `mkdir` command on Windows is different than used on Unix.
            # This formulation matches the form used in the WinRM communicator plugin.
            # This will ignore any -p switches, which are redundant in PowerShell,
            # and ambiguous in PowerShell 4+
            comm.execute("mkdir \"#{opts[:guestpath]}\" -force")
          end
        end
      end
    end
  end
end
