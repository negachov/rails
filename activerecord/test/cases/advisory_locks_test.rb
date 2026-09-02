# frozen_string_literal: true

require "cases/helper"
require "logger"
require "stringio"

# Advisory locks (PostgreSQL `pg_try_advisory_lock` / MySQL `GET_LOCK`) are
# session-scoped: the lock is held by a specific server-side backend, not by
# the Rails adapter object. If the underlying connection drops while we hold
# the lock, the server releases it the moment the session goes away.
#
# The dangerous failure mode (introduced with the Rails 7 "retry on
# connection error" mechanism) is that a subsequent query would transparently
# reconnect and re-run on a *different* backend. Because the statement is
# then executed on a new session that never held the lock, the application
# silently proceeds believing it still owns a lock it no longer has, and any
# mutual-exclusion guarantee is broken.
#
# `get_advisory_lock` / `release_advisory_lock` therefore probe the
# connection first and raise `ConnectionNotEstablished` if it was connected
# but its session is no longer active (which would otherwise be
# transparently re-established before running the lock query, on a different
# backend). A connection that is not connected *yet* is fine: it is
# established lazily by the lock query, exactly like any other first query
# (pre-Rails 7 behavior). They also pass `allow_retry: false` so that a
# failed query is not transparently reconnected and re-run (which would
# silently succeed where it should fail). This restores the pre-Rails 7
# behavior where a lost connection surfaces to the caller instead of being
# silently re-established. These tests guard that regression.
class AdvisoryLocksTest < ActiveRecord::TestCase
  def setup
    # `supports_advisory_locks?` is an adapter method: check it on the
    # connection, not on the test class.
    skip("Adapter does not support advisory locks") unless ActiveRecord::Base.lease_connection.supports_advisory_locks?
  end

  def teardown
    # Best-effort release in case a test acquired a lock and did not release it.
    connection = ActiveRecord::Base.lease_connection
    if connection.supports_advisory_locks?
      begin
        connection.release_advisory_lock(lock_arg)
      rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
        # The connection is likely broken (that's the point of the kill tests),
        # so releasing the lock may fail with a connection error; ignore
        # cleanup failures. The rescue is deliberately scoped to the release
        # call so that real failures in `super` are not masked.
      end
    end
    super
  end

  def test_release_advisory_lock_raises_instead_of_reconnecting
    connection = ActiveRecord::Base.lease_connection
    assert connection.get_advisory_lock(lock_arg), "should acquire the lock"

    # Kill the session server-side so the backend (and with it the lock) is
    # gone, but the adapter object still believes it holds the connection.
    kill_session(connection)

    # release_advisory_lock must surface the connection error rather than
    # transparently reconnecting (which would silently run against a backend
    # that does not hold the lock).
    assert_raises(ActiveRecord::ConnectionNotEstablished) do
      connection.release_advisory_lock(lock_arg)
    end
  ensure
    restore_live_connection(connection)
  end

  def test_get_advisory_lock_raises_instead_of_reconnecting
    connection = ActiveRecord::Base.lease_connection
    connection.get_advisory_lock(lock_arg)
    connection.release_advisory_lock(lock_arg)

    kill_session(connection)

    # Acquiring a lock over a dead connection must not transparently
    # reconnect and succeed on a fresh backend; it must raise.
    assert_raises(ActiveRecord::ConnectionNotEstablished) do
      connection.get_advisory_lock(lock_arg)
    end
  ensure
    restore_live_connection(connection)
  end

  def test_lock_is_released_after_session_kill
    # Verify that killing the session releases the lock (i.e., another
    # session can acquire it). This is a separate guarantee from "an exception
    # is raised": even if the exception were raised, the lock could still be
    # held by a different backend if retry had re-run the statement on a new
    # session. This test proves the old session actually lost the lock.
    connection = ActiveRecord::Base.lease_connection
    assert connection.get_advisory_lock(lock_arg), "should acquire the lock"

    kill_session_by_other_connection(connection)

    # The old session is dead, so the lock is free: another session can
    # acquire it (proves the old session lost the lock).
    other_pool = build_duplicate_pool
    other = other_pool.checkout
    assert other.get_advisory_lock(lock_arg),
      "lock should be released after the session was killed (proves the old session lost it)"
    other.release_advisory_lock(lock_arg)

    # The original connection must raise (not transparently reconnect and
    # acquire on a fresh backend).
    assert_raises(ActiveRecord::ConnectionNotEstablished) do
      connection.get_advisory_lock(lock_arg)
    end
  ensure
    other&.close
    other_pool&.disconnect!
    restore_live_connection(connection)
  end

  # -- allow_retry: false and no-reconnect guarantees -----------------------

  def test_get_advisory_lock_does_not_reconnect_after_kill
    # After the session is killed, get_advisory_lock must raise and the
    # connection must NOT be transparently reconnected. Verify that:
    #   1. An exception is raised
    #   2. The connection is still inactive (no silent reconnect happened)
    connection = ActiveRecord::Base.lease_connection
    assert connection.get_advisory_lock(lock_arg), "should acquire the lock"

    kill_session_by_other_connection(connection)

    assert_raises(ActiveRecord::ConnectionNotEstablished) do
      connection.get_advisory_lock(lock_arg)
    end

    # The connection must still be inactive: if a transparent reconnect had
    # occurred, active? would be true and the lock would have been acquired
    # on a fresh backend (the bug we are guarding against).
    assert_not connection.active?,
      "connection must not have been transparently reconnected after the kill"
  ensure
    restore_live_connection(connection)
  end

  def test_release_advisory_lock_does_not_reconnect_after_kill
    # Same guarantee for release_advisory_lock: after the session is killed,
    # release must raise and the connection must NOT be transparently
    # reconnected (which would run RELEASE_LOCK on a backend that never held
    # the lock).
    connection = ActiveRecord::Base.lease_connection
    assert connection.get_advisory_lock(lock_arg), "should acquire the lock"

    kill_session_by_other_connection(connection)

    assert_raises(ActiveRecord::ConnectionNotEstablished) do
      connection.release_advisory_lock(lock_arg)
    end

    assert_not connection.active?,
      "connection must not have been transparently reconnected after the kill"
  ensure
    restore_live_connection(connection)
  end

  def test_get_advisory_lock_with_needs_reconnect_true
    # When @needs_reconnect is true (set by a previous connection error),
    # get_advisory_lock must raise rather than transparently reconnecting.
    # This is the case where `active?` may still return true (the raw
    # connection object is present) but the adapter has flagged itself for
    # replacement. Without the @needs_reconnect check in
    # ensure_advisory_lock_session!, with_raw_connection would call verify!
    # and transparently reconnect, running the advisory lock on a different
    # backend.
    connection = ActiveRecord::Base.lease_connection
    assert connection.get_advisory_lock(lock_arg), "should acquire the lock"
    connection.release_advisory_lock(lock_arg)

    # Set @needs_reconnect = true directly to simulate the state after a
    # previous connection error (e.g. a failed query that was not retried).
    connection.instance_variable_set(:@needs_reconnect, true)

    # get_advisory_lock must raise (not transparently reconnect and acquire
    # on a fresh backend), even though active? may still be true.
    assert_raises(ActiveRecord::ConnectionNotEstablished) do
      connection.get_advisory_lock(lock_arg)
    end

    # release_advisory_lock must also raise.
    assert_raises(ActiveRecord::ConnectionNotEstablished) do
      connection.release_advisory_lock(lock_arg)
    end

    # @needs_reconnect should still be true (no reconnect happened).
    assert connection.needs_reconnect?,
      "@needs_reconnect must remain true (no transparent reconnect occurred)"
  ensure
    # Reset @needs_reconnect and restore a live connection.
    connection.instance_variable_set(:@needs_reconnect, false)
    restore_live_connection(connection)
  end

  # -- session_id_of guard --------------------------------------------------

  def test_session_id_of_raises_when_needs_reconnect
    # session_id_of must raise (not transparently reconnect) when
    # @needs_reconnect is true. allow_retry: false only prevents re-running
    # a failed query; it does NOT prevent the pre-execution connect!/verify!
    # calls in with_raw_connection from reconnecting on a different backend.
    connection = ActiveRecord::Base.lease_connection
    connection.instance_variable_set(:@needs_reconnect, true)

    assert_raises(ActiveRecord::ConnectionNotEstablished) do
      ActiveRecord.send(:session_id_of, connection)
    end
  ensure
    connection.instance_variable_set(:@needs_reconnect, false)
    restore_live_connection(connection)
  end

  def test_session_id_of_raises_when_inactive
    # session_id_of must raise (not transparently reconnect) when the
    # connection is connected but inactive.
    connection = ActiveRecord::Base.lease_connection
    assert connection.get_advisory_lock(lock_arg), "should acquire the lock"

    kill_session_by_other_connection(connection)

    assert_raises(ActiveRecord::ConnectionNotEstablished) do
      ActiveRecord.send(:session_id_of, connection)
    end
  ensure
    restore_live_connection(connection)
  end

  def test_session_id_of_returns_nil_for_unknown_adapter
    # session_id_of returns nil for adapters that do not support session id
    # tracking (e.g. SQLite). This is not an error state.
    fake = Object.new
    fake.define_singleton_method(:adapter_name) { "SQLite" }
    fake.define_singleton_method(:needs_reconnect?) { false }
    fake.define_singleton_method(:connected?) { true }
    fake.define_singleton_method(:active?) { true }

    result = ActiveRecord.send(:session_id_of, fake)
    assert_nil result, "session_id_of should return nil for unknown adapters"
  end

  # -- nested get_advisory_lock --------------------------------------------

  def test_nested_get_advisory_lock_raises_when_needs_reconnect
    # Nested get_advisory_lock: if the session dies while holding lock_a,
    # and then get_advisory_lock(lock_b) is called, the new session must NOT
    # silently acquire lock_b (which would break mutual exclusion because
    # lock_a was lost). @needs_reconnect must prevent the transparent
    # reconnect in with_raw_connection.
    #
    # Note: this test verifies the @needs_reconnect guard in
    # ensure_advisory_lock_session!. It does NOT test the scenario where
    # lock_a is held while the session dies (that is covered by the helper
    # tests below). Here, lock_a is released BEFORE @needs_reconnect is set,
    # so no lock is left behind.
    connection = ActiveRecord::Base.lease_connection
    lock_a = nested_lock_arg(0)
    lock_b = nested_lock_arg(1)

    # Acquire and release lock_a (the session is healthy).
    assert connection.get_advisory_lock(lock_a), "should acquire lock_a"
    assert connection.release_advisory_lock(lock_a), "should release lock_a"

    # Simulate the state after a connection error: @needs_reconnect = true.
    connection.instance_variable_set(:@needs_reconnect, true)

    # get_advisory_lock(lock_b) must raise (not transparently reconnect and
    # acquire lock_b on a fresh backend).
    assert_raises(ActiveRecord::ConnectionNotEstablished) do
      connection.get_advisory_lock(lock_b)
    end

    assert connection.needs_reconnect?,
      "@needs_reconnect must remain true (no transparent reconnect occurred)"
  ensure
    # Reset @needs_reconnect and restore a live connection.
    connection.instance_variable_set(:@needs_reconnect, false)
    restore_live_connection(connection)
  end

  def test_nested_get_advisory_lock_works_when_connection_is_healthy
    # Nested get_advisory_lock on a healthy connection: both locks should be
    # acquired and released successfully. This verifies that the guard does
    # not over-raise on a healthy connection.
    connection = ActiveRecord::Base.lease_connection
    lock_a = nested_lock_arg(0)
    lock_b = nested_lock_arg(1)

    assert connection.get_advisory_lock(lock_a), "should acquire lock_a"
    assert connection.get_advisory_lock(lock_b), "should acquire lock_b"
    assert connection.release_advisory_lock(lock_b), "should release lock_b"
    assert connection.release_advisory_lock(lock_a), "should release lock_a"
  end

  def test_nested_get_advisory_lock_releases_when_second_fails
    # If the second get_advisory_lock fails (e.g. held by another session),
    # the first lock must still be released. This is the typical cleanup
    # pattern: ensure { release lock_a } around the acquisition of lock_b.
    connection = ActiveRecord::Base.lease_connection
    lock_a = nested_lock_arg(0)
    lock_b = nested_lock_arg(1)

    # Hold lock_b on a separate session so the main session cannot acquire it.
    other_pool = build_duplicate_pool
    other = other_pool.checkout
    assert other.get_advisory_lock(lock_b), "other session should acquire lock_b"

    # Acquire lock_a on the main session.
    assert connection.get_advisory_lock(lock_a), "should acquire lock_a"

    # Attempt to acquire lock_b (should fail: held by other session).
    assert_not connection.get_advisory_lock(lock_b), "should not acquire lock_b"

    # Release lock_a (cleanup).
    assert connection.release_advisory_lock(lock_a), "should release lock_a"
  ensure
    other&.release_advisory_lock(lock_b)
    other&.close
    other_pool&.disconnect!
  end

  # -- helper edge cases ----------------------------------------------------

  def test_with_session_advisory_lock_releases_lock_when_session_id_fails
    # If session_id_of fails (e.g. the session died just after acquisition),
    # the lock must still be released in `ensure`. We simulate this with a
    # fake connection whose get_advisory_lock succeeds but whose active?
    # returns false (so session_id_of's guard raises). The helper should:
    #   1. Acquire the lock (fake returns true)
    #   2. session_id_of raises (active? is false -> guard raises)
    #   3. `ensure` calls release_and_report_advisory_lock with
    #      original_session_id == nil, which releases the lock best-effort
    #   4. The exception from session_id_of propagates to the caller
    release_called = false
    fake = Object.new
    fake.define_singleton_method(:advisory_locks_enabled?) { true }
    fake.define_singleton_method(:adapter_name) { "FakeAdapter" }
    fake.define_singleton_method(:get_advisory_lock) { |*| true }
    fake.define_singleton_method(:release_advisory_lock) { |*| release_called = true; true }
    # active? returns false -> session_id_of's guard raises
    fake.define_singleton_method(:needs_reconnect?) { false }
    fake.define_singleton_method(:active?) { false }

    assert_raises(ActiveRecord::ConnectionNotEstablished) do
      ActiveRecord.with_session_advisory_lock(lock_arg, connection: fake) { :ok }
    end
    assert release_called,
      "release_advisory_lock must be called in ensure even when session_id_of fails"
  end

  def test_with_session_advisory_lock_on_adapter_without_session_id
    # Adapters that do not support session id tracking (e.g. SQLite) should
    # still work: the helper acquires and releases the lock, and the block
    # runs. session_id_of returns nil, so release_and_report skips the
    # session-change check.
    fake = Object.new
    fake.define_singleton_method(:advisory_locks_enabled?) { true }
    fake.define_singleton_method(:adapter_name) { "SQLite" }
    fake.define_singleton_method(:get_advisory_lock) { |*| true }
    fake.define_singleton_method(:release_advisory_lock) { |*| true }
    # session_id_of returns nil for unknown adapters

    result = ActiveRecord.with_session_advisory_lock(lock_arg, connection: fake) { :ok }
    assert_equal :ok, result
  end

  def test_with_session_advisory_lock_session_dies_after_acquisition
    # Verify the helper's error path when the session dies after acquisition
    # but before session_id_of completes. The helper should:
    #   1. Acquire the lock (get_advisory_lock succeeds)
    #   2. Kill the session (from another connection)
    #   3. session_id_of raises (the session is gone)
    #   4. `ensure` calls release_and_report_advisory_lock with
    #      original_session_id == nil, which releases the lock best-effort
    #   5. The exception from session_id_of propagates to the caller
    #
    # This test calls the helper directly. We use a fake connection whose
    # get_advisory_lock succeeds but whose active? returns false (so
    # session_id_of's guard raises).
    release_called = false
    fake = Object.new
    fake.define_singleton_method(:advisory_locks_enabled?) { true }
    fake.define_singleton_method(:adapter_name) { "FakeAdapter" }
    fake.define_singleton_method(:get_advisory_lock) { |*| true }
    fake.define_singleton_method(:release_advisory_lock) { |*| release_called = true; true }
    # active? returns false -> session_id_of's guard raises
    fake.define_singleton_method(:needs_reconnect?) { false }
    fake.define_singleton_method(:active?) { false }

    assert_raises(ActiveRecord::ConnectionNotEstablished) do
      ActiveRecord.with_session_advisory_lock(lock_arg, connection: fake) { :ok }
    end
    assert release_called,
      "release_advisory_lock must be called in ensure even when session_id_of fails"
  end

  # -- query_value allow_retry: false unit test -----------------------------

  def test_advisory_lock_methods_pass_allow_retry_false
    # Verify that both get_advisory_lock and release_advisory_lock pass
    # allow_retry: false to query_value. We spy on query_value once and
    # capture both calls to avoid a "method redefined" warning (defining
    # the singleton method twice would trigger the warning).
    connection = ActiveRecord::Base.lease_connection
    captured = spy_on_method(connection, :query_value)

    connection.get_advisory_lock(lock_arg)
    connection.release_advisory_lock(lock_arg)

    # Both calls should have been captured with allow_retry: false.
    assert_equal 2, captured.size, "query_value should have been called twice"
    captured.each do |call|
      assert_equal false, call[:kwargs][:allow_retry],
        "advisory lock methods must pass allow_retry: false to query_value"
    end
  end

  # -- MySQL timeout branching ---------------------------------------------

  def test_with_session_advisory_lock_timeout_passthrough
    # Verify that the helper passes the timeout option through to
    # acquire_advisory_lock, which then passes it to the adapter.
    connection = ActiveRecord::Base.lease_connection
    captured = spy_on_method(connection, :get_advisory_lock)

    result = ActiveRecord.with_session_advisory_lock(lock_arg, timeout: 3, connection: connection) { :ok }
    assert_equal :ok, result

    # The timeout should have been passed to the adapter.
    # MySQL: positional argument (this repo's signature); PG: no timeout.
    if connection.adapter_name == "Mysql2" || connection.adapter_name == "Trilogy"
      assert_equal 3, captured.first[:args][1],
        "timeout should be passed as a positional argument to MySQL's get_advisory_lock"
    end
  ensure
    connection.release_advisory_lock(lock_arg)
  end

  def test_get_advisory_lock_connects_when_not_connected
    connection = ActiveRecord::Base.lease_connection
    connection.disconnect!

    # Not-yet-connected is not an error state for advisory locks: like any
    # other first query, the lock query lazily establishes the connection
    # and acquires (Rails 6 behavior). Only a *dead* session must raise --
    # see test_get_advisory_lock_raises_instead_of_reconnecting.
    assert connection.get_advisory_lock(lock_arg), "should lazily connect and acquire the lock"
  ensure
    # Keep the (re-established) connection alive so teardown/rollback can run
    # and later tests start from a live connection.
    connection.verify!
  end

  def test_release_advisory_lock_connects_when_not_connected
    connection = ActiveRecord::Base.lease_connection
    connection.disconnect!

    # Releasing a lock on a not-yet-connected connection lazily connects and
    # is a harmless no-op (false) -- the fresh session does not hold the lock
    # (Rails 6 behavior).
    assert_not connection.release_advisory_lock(lock_arg)
  ensure
    connection.verify!
  end

  def test_release_advisory_lock_raises_when_killed_by_other_connection
    connection = ActiveRecord::Base.lease_connection
    assert connection.get_advisory_lock(lock_arg), "should acquire the lock"

    # Kill the backend from a *separate* connection: +connection+'s client
    # side has not observed the failure yet (its last I/O succeeded), so
    # only an active? probe (or the next I/O) can detect that the session
    # -- and with it the lock -- is gone.
    kill_session_by_other_connection(connection)

    assert_raises(ActiveRecord::ConnectionNotEstablished) do
      connection.release_advisory_lock(lock_arg)
    end
  ensure
    restore_live_connection(connection)
  end

  def test_release_advisory_lock_returns_false_when_not_held
    connection = ActiveRecord::Base.lease_connection

    # Releasing a lock we never acquired on this session must be a harmless
    # no-op (this is how `ensure { release }` cleanup works when acquisition
    # failed), not an error: the new connection guard must not over-raise on
    # a healthy connection.
    assert_not connection.release_advisory_lock(lock_arg)
  end

  def test_get_advisory_lock_returns_false_when_held_by_other
    connection = ActiveRecord::Base.lease_connection

    # The main pool's connection is pinned by the test framework, so a
    # `checkout` on the main pool would hand back this very session (where
    # GET_LOCK is reentrant). Use a duplicate pool to get a genuinely
    # separate session.
    other_pool = build_duplicate_pool
    other = other_pool.checkout
    assert other.get_advisory_lock(lock_arg), "other session should acquire the lock"

    # A lock already held by another session must be reported as "not
    # acquired" (false), not as an error: this is the contention path that
    # e.g. the migrator relies on to raise ConcurrentMigrationError.
    assert_not connection.get_advisory_lock(lock_arg)
  ensure
    if other
      other.release_advisory_lock(lock_arg)
      other.close
    end
    other_pool&.disconnect!
  end

  def test_advisory_lock_works_inside_open_transaction
    connection = ActiveRecord::Base.lease_connection

    # The active? probe and the lock queries must be safe to run with an
    # open (virtual/materialized) transaction on the same connection.
    connection.transaction do
      assert connection.get_advisory_lock(lock_arg), "should acquire the lock"
      assert connection.release_advisory_lock(lock_arg), "should release the lock"
    end
  end

  # -- with_session_advisory_lock helper ---------------------------------

  def test_with_session_advisory_lock_yields_when_acquired
    # The helper acquires the lock on the leased connection (see below), so
    # we verify the connection is still active afterwards.
    connection = ActiveRecord::Base.lease_connection
    assert connection.supports_advisory_locks?, "setup should skip if unsupported"

    yielded = nil
    result = ActiveRecord.with_session_advisory_lock(lock_arg) do
      yielded = true
      :block_return_value
    end

    assert yielded, "block should yield while the lock is held"
    assert_equal :block_return_value, result, "helper should return the block's return value"
    assert connection.active?, "connection should still be active after the helper"
  end

  def test_with_session_advisory_lock_raises_when_not_acquired
    # Hold the lock on a separate session so the helper cannot acquire it.
    other_pool = build_duplicate_pool
    other = other_pool.checkout
    assert other.get_advisory_lock(lock_arg), "other session should acquire the lock"

    # The helper must raise its dedicated error (not the migration-specific
    # ConcurrentMigrationError) when it cannot acquire.
    assert_raises(ActiveRecord::AdvisoryLockAcquisitionFailed) do
      ActiveRecord.with_session_advisory_lock(lock_arg) { :noop }
    end
  ensure
    if other
      other.release_advisory_lock(lock_arg)
      other.close
    end
    other_pool&.disconnect!
  end

  def test_with_session_advisory_lock_releases_after_yield
    ActiveRecord.with_session_advisory_lock(lock_arg) { :noop }

    # After the helper returns, the lock must be released: a separate
    # session should now be able to acquire it.
    other_pool = build_duplicate_pool
    other = other_pool.checkout
    assert other.get_advisory_lock(lock_arg), "lock should be released after the helper"
    other.release_advisory_lock(lock_arg)
  ensure
    other&.close
    other_pool&.disconnect!
  end

  def test_with_session_advisory_lock_detects_session_change
    # The helper records pg_backend_pid / CONNECTION_ID at acquisition time.
    # If the session is severed and the connection transparently reconnects
    # (a *different* backend), the release-time check sees a different
    # session id and must raise AdvisoryLockLost -- the lock was silently
    # dropped with the old session.
    connection = ActiveRecord::Base.lease_connection

    # Acquire the lock through the helper so it records the session id.
    block_return = nil
    begin
      ActiveRecord.with_session_advisory_lock(lock_arg) do
        block_return = :yielded
        # Sever the session from a *separate* connection so this
        # connection's client side has not observed the failure yet.
        kill_session_by_other_connection(connection)
      end
    rescue ActiveRecord::AdvisoryLockLost => e
      # Expected: the helper detected that the lock was lost (either the
      # session changed, or the session-id query failed with a connection
      # error) and raised AdvisoryLockLost.
      assert_equal :yielded, block_return, "block should have yielded before the lock was lost"
      assert_match(/lost: (session changed|connection is gone)/, e.message)
    else
      # If no exception was raised, the session must not have changed --
      # which would mean the kill did not take effect. Fail the test.
      flunk "expected AdvisoryLockLost to be raised after the session was severed"
    end
  ensure
    # Best-effort cleanup: release the lock (no-op if already lost) and
    # restore a live connection for teardown/rollback.
    begin
      connection&.release_advisory_lock(lock_arg)
    rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid
      # connection may still be dead; ignore cleanup failures
    end
    connection&.verify!
  end

  def test_with_session_advisory_lock_yields_when_locks_disabled
    # Adapters without advisory lock support (or with advisory_locks: false)
    # must simply yield the block instead of raising NoMethodError:
    # get_advisory_lock does not even exist on such adapters.
    fake = Object.new
    def fake.advisory_locks_enabled?; false; end

    yielded = false
    result = ActiveRecord.with_session_advisory_lock(lock_arg, connection: fake) do
      yielded = true
      :ok
    end
    assert yielded, "block should run even when advisory locks are disabled"
    assert_equal :ok, result
  end

  def test_with_session_advisory_lock_does_not_mask_block_errors
    # If the block raises AND the lock is lost at the same time,
    # AdvisoryLockLost must NOT replace (mask) the original error; it is
    # reported via a logged warning instead.
    connection = ActiveRecord::Base.lease_connection
    old_logger = ActiveRecord::Base.logger
    log = StringIO.new
    ActiveRecord::Base.logger = Logger.new(log)

    err = assert_raises(RuntimeError) do
      ActiveRecord.with_session_advisory_lock(lock_arg, connection: connection) do
        kill_session_by_other_connection(connection)
        raise "boom"
      end
    end
    assert_equal "boom", err.message, "the block's own error must propagate unmasked"
    assert_match(/advisory lock .* lost/, log.string,
      "the lock loss should be reported via the logger instead")
  ensure
    ActiveRecord::Base.logger = old_logger
    begin
      connection&.release_advisory_lock(lock_arg)
    rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::StatementInvalid
      # connection may still be dead; ignore cleanup failures
    end
    connection&.verify!
  end

  def test_with_session_advisory_lock_releases_and_propagates_block_error
    # Healthy session: the block's error must propagate AND the lock must
    # still be released (a separate session can then acquire it).
    err = assert_raises(RuntimeError) do
      ActiveRecord.with_session_advisory_lock(lock_arg) { raise "boom" }
    end
    assert_equal "boom", err.message

    other_pool = build_duplicate_pool
    other = other_pool.checkout
    assert other.get_advisory_lock(lock_arg), "lock should have been released despite the error"
    other.release_advisory_lock(lock_arg)
  ensure
    other&.close
    other_pool&.disconnect!
  end

  def test_with_session_advisory_lock_raises_when_release_fails
    # Releasing the lock behind the helper's back makes its own release call
    # return false; that must surface as AdvisoryLockLost instead of silently
    # succeeding (the helper checks the release result, like the Migrator).
    assert_raises(ActiveRecord::AdvisoryLockLost) do
      ActiveRecord.with_session_advisory_lock(lock_arg) do
        ActiveRecord::Base.lease_connection.release_advisory_lock(lock_arg)
      end
    end
  end

  def test_with_session_advisory_lock_accepts_explicit_connection
    # The :connection option lets multi-database apps lock on a specific
    # connection instead of the Base leased one.
    other_pool = build_duplicate_pool
    other = other_pool.checkout

    result = ActiveRecord.with_session_advisory_lock(lock_arg, connection: other) { :ok }
    assert_equal :ok, result

    # The helper acquired and released on `other`; the main session can now
    # acquire the lock (proving it was held there and then released).
    connection = ActiveRecord::Base.lease_connection
    assert connection.get_advisory_lock(lock_arg),
      "lock should have been released on the explicit connection"
    connection.release_advisory_lock(lock_arg)
  ensure
    other&.close
    other_pool&.disconnect!
  end

  def test_with_session_advisory_lock_accepts_timeout_option
    # timeout: is MySQL-specific; it must be accepted (and ignored where the
    # adapter has no timeout concept, e.g. PostgreSQL) without ArgumentError.
    result = ActiveRecord.with_session_advisory_lock(lock_arg, timeout: 1) { :ok }
    assert_equal :ok, result
  end

  private
    # Advisory lock identifiers differ per adapter: PostgreSQL uses a signed
    # 64-bit integer, MySQL/Trilogy use a string name.
    def lock_arg
      current_adapter?(:PostgreSQLAdapter) ? LOCK_ID : LOCK_NAME
    end

    # Sever +connection+'s backend from the server side using a *separate*
    # connection, so that +connection+'s client side has not observed the
    # failure (its last I/O succeeded) and only an active? probe or the next
    # I/O can detect that the session is gone.
    def kill_session_by_other_connection(connection)
      session_id = session_id_of(connection)

      # The main pool's connection is pinned by the test framework, so a
      # `checkout` on the main pool would return the very session being
      # killed (killing oneself is not the scenario under test). Use a
      # duplicate pool so the kill really comes from a separate session.
      killer_pool = build_duplicate_pool
      killer = killer_pool.checkout
      begin
        case connection.adapter_name
        when "Mysql2", "Trilogy"
          killer.execute("KILL #{session_id}")
        when "PostgreSQL"
          killer.execute("SELECT pg_terminate_backend(#{session_id})")
        end
      ensure
        killer.close
        killer_pool.disconnect!
      end
    end

    # Sever +connection+'s backend from the server side, so that the next
    # query on +connection+ fails with a connection error.
    # +connection+ is this test's leased (pinned) connection, so it is used
    # directly to issue the kill; no checkin is needed afterwards.
    def kill_session(connection)
      pid = session_id_of(connection)

      case connection.adapter_name
      when "Mysql2", "Trilogy"
        begin
          connection.execute("KILL #{pid}")
        rescue ActiveRecord::QueryCanceled
          # Killing our own session interrupts the KILL statement itself
          # ("Query execution was interrupted"). The session is dead,
          # which is exactly what we wanted, so this is a success.
        end
      when "PostgreSQL"
        begin
          connection.execute("SELECT pg_terminate_backend(#{pid})")
        rescue ActiveRecord::StatementInvalid
          # Terminating our own backend kills the connection before the
          # result is returned, so the terminate statement itself fails with
          # a connection error (e.g. ConnectionFailed, a subclass of
          # StatementInvalid). The session is dead, which is exactly what we
          # wanted, so this is a success.
        end
      end
    end

    # Restore a live connection after a kill test: the test transaction is
    # still "open" in the transaction manager (transaction_open? ==
    # current_transaction.open?), so the framework's after_teardown runs
    # unpin_connection! -> rollback_transaction, which must be able to talk
    # to a live session. verify! reconnects (restoring the transaction) so
    # that teardown's rollback completes cleanly.
    def restore_live_connection(connection)
      connection.verify!
    end

    # A duplicate pool for the same database, used to obtain a genuinely
    # separate session (the test framework pins the main pool's
    # connection, so checking out of the main pool would return that very
    # session). Modeled after test/cases/connection_pool_test.rb.
    def build_duplicate_pool
      config = ActiveRecord::Base.connection_pool.db_config
      db_config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
        config.env_name,
        config.name,
        config.configuration_hash
      )
      pool_config = ActiveRecord::ConnectionAdapters::PoolConfig.new(
        ActiveRecord::Base, db_config, :writing, :default
      )
      ActiveRecord::ConnectionAdapters::ConnectionPool.new(pool_config)
    end

    # The server-side session identifier of +connection+ (used to sever it
    # from the server side).
    #
    # `query_value` is used because the row shape differs per adapter: MySQL
    # returns arrays (`[[id]]`) while PostgreSQL returns hashes
    # (`[{"pg_backend_pid" => id}]`), so positional `[0][0]` access only
    # works on the former.
    def session_id_of(connection)
      case connection.adapter_name
      when "Mysql2", "Trilogy"
        connection.query_value("SELECT CONNECTION_ID()")
      when "PostgreSQL"
        connection.query_value("SELECT pg_backend_pid()")
      else
        skip("kill_session unsupported for #{connection.adapter_name}")
      end
    end

    # Spy on a connection method to capture its arguments, delegating to the
    # original implementation. Returns the captured call log. The singleton
    # method is automatically removed when the connection object is garbage
    # collected, and each test re-defines its own spy, so no explicit
    # restore is needed (and `undef_method` would break subsequent tests).
    def spy_on_method(object, method_name)
      original = object.method(method_name)
      captured = []
      object.define_singleton_method(method_name) do |*args, **kwargs, &block|
        captured << { args: args, kwargs: kwargs }
        original.call(*args, **kwargs, &block)
      end
      captured
    end

    # A distinct lock identifier for nested lock tests.
    def nested_lock_arg(index)
      if lock_arg.is_a?(Integer)
        LOCK_ID + index
      else
        "#{LOCK_NAME}_#{index}"
      end
    end

    LOCK_ID = 1234_5678
    LOCK_NAME = "advisory_locks_test"
end
