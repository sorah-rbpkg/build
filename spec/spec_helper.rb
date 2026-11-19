require 'rspec'

Dir[File.join(__dir__, 'support', '*.rb')].each { require it }

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand(config.seed)
end
