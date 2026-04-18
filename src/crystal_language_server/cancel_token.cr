module CrystalLanguageServer
  # One-way latch threaded through a single in-flight request's fiber.
  # Closing the channel is both the wake-up signal for select-based
  # waits (see `Compiler::Subprocess.run_io`) and the boolean `cancelled?`
  # check that handlers poll at natural boundaries.
  #
  # `Channel#close` is idempotent, so `cancel` is safe to call from any
  # fiber without extra locking.
  class CancelToken
    getter channel : Channel(Nil)

    def initialize
      @channel = Channel(Nil).new
    end

    def cancel : Nil
      @channel.close
    end

    def cancelled? : Bool
      @channel.closed?
    end
  end
end
