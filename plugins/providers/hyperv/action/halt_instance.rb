module VagrantPlugins
  module HyperV
    module Action
      class HaltInstance
        def initialize(app, env)
          @app    = app
        end

        def call(env)
          env[:ui].info("Turning off the machine...")
          env[:machine].provider.driver.halt
          @app.call(env)
        end
      end
    end
  end
end
