require File.expand_path("../../../../base", __FILE__)

describe Vagrant::Action::Builtin::Confirm do
  let(:app) { lambda { |env| } }
  let(:env) { { :ui => double("ui") } }
  let(:message) { "foo" }

  ["y", "Y"].each do |valid|
    it "should set the result to true if '#{valid}' is given" do
      env[:ui].should_receive(:ask).with(message).and_return(valid)
      described_class.new(app, env, message).call(env)
      env[:result].should be
    end
  end

  it "should set result to false if anything else is given" do
    env[:ui].should_receive(:ask).with(message).and_return("nope")
    described_class.new(app, env, message).call(env)
    env[:result].should_not be
  end
end
