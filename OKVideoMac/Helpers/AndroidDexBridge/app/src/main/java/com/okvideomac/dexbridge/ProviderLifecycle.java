package com.okvideomac.dexbridge;

import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.locks.Lock;
import java.util.concurrent.locks.ReentrantReadWriteLock;

/** A reset may never destroy an instance still executing a provider call. */
final class ProviderLifecycle {
    private final ConcurrentHashMap<String, ReentrantReadWriteLock> groups =
            new ConcurrentHashMap<>();

    Lease acquire(String group, boolean reset) throws InterruptedException {
        ReentrantReadWriteLock gate = groups.computeIfAbsent(
                group, ignored -> new ReentrantReadWriteLock());
        Lock lock = reset ? gate.writeLock() : gate.readLock();
        if (reset) {
            // Do not queue a writer behind an authorization call: its callback
            // may itself need a read lease. The caller can retry recovery once
            // the foreground operation has finished.
            if (!lock.tryLock()) {
                throw new IllegalStateException("Provider is busy; retry recovery after the active request finishes");
            }
        } else {
            lock.lockInterruptibly();
        }
        return new Lease(lock);
    }

    static final class Lease implements AutoCloseable {
        private Lock lock;
        Lease(Lock lock) { this.lock = lock; }
        @Override public void close() {
            if (lock != null) {
                lock.unlock();
                lock = null;
            }
        }
    }
}
