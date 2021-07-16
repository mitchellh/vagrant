require_relative '../linux/guest'

module VagrantPlugins
  module GuestAstra
    class Guest < VagrantPlugins::GuestLinux::Guest
      # Name used for guest detection
      GUEST_DETECTION_NAME = "astra".freeze
    end
  end
end
