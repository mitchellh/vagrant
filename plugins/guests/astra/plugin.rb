require "vagrant"

module VagrantPlugins
  module GuestAstra
    class Plugin < Vagrant.plugin("2")
      name "Astra Linux guest"
      description "Astra Linux guest support."

      guest(:astra, :debian) do
        require_relative "guest"
        Guest
      end
    end
  end
end
