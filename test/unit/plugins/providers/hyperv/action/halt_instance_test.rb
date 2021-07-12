require_relative "../../../../base"

require Vagrant.source_root.join("plugins/providers/hyperv/action/halt_instance")

describe VagrantPlugins::HyperV::Action::HaltInstance do
  let(:app){ double("app") }
  let(:env){ {ui: ui, machine: machine} }
  let(:ui){ double("ui") }
  let(:provider){ double("provider", driver: driver) }
  let(:driver){ double("driver") }
  let(:machine){ double("machine", provider: provider, data_dir: "/dev/null") }
  let(:subject){ described_class.new(app, env) }

  before do
    allow(app).to receive(:call)
    allow(ui).to receive(:info)
    allow(driver).to receive(:halt)
  end

  it "should call the app on success" do
    expect(app).to receive(:call)
    subject.call(env)
  end

  it "should call the driver to halt the vm" do
    expect(driver).to receive(:halt)
    subject.call(env)
  end
end
