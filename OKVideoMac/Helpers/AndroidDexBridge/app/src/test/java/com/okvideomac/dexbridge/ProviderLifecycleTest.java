package com.okvideomac.dexbridge;

import org.junit.Test;
import java.util.concurrent.*;
import static org.junit.Assert.*;

public class ProviderLifecycleTest {
    @Test public void activeDetailPreventsDestroyWithoutBlockingAuthorization() throws Exception {
        ProviderLifecycle lifecycle = new ProviderLifecycle();
        ExecutorService worker = Executors.newSingleThreadExecutor();
        try {
            try (ProviderLifecycle.Lease detail = lifecycle.acquire("jar-a", false)) {
                assertTrue(worker.submit(() -> {
                    try (ProviderLifecycle.Lease reset = lifecycle.acquire("jar-a", true)) {
                        return false;
                    } catch (IllegalStateException expected) { return true; }
                }).get(2, TimeUnit.SECONDS));
                // Authorization callbacks and unrelated jars remain usable.
                assertTrue(worker.submit(() -> {
                    try (ProviderLifecycle.Lease callback = lifecycle.acquire("jar-a", false);
                         ProviderLifecycle.Lease other = lifecycle.acquire("jar-b", true)) {
                        return true;
                    }
                }).get(2, TimeUnit.SECONDS));
            }
            try (ProviderLifecycle.Lease reset = lifecycle.acquire("jar-a", true)) {
                assertNotNull(reset);
            }
        } finally { worker.shutdownNow(); }
    }

    @Test public void resetProtectsNewRequestsAndWaitingRequestCanBeCancelled() throws Exception {
        ProviderLifecycle lifecycle = new ProviderLifecycle();
        ExecutorService worker = Executors.newSingleThreadExecutor();
        CountDownLatch started = new CountDownLatch(1);
        CountDownLatch cancelled = new CountDownLatch(1);
        try (ProviderLifecycle.Lease reset = lifecycle.acquire("jar-a", true)) {
            Future<?> request = worker.submit(() -> {
                started.countDown();
                try (ProviderLifecycle.Lease ignored = lifecycle.acquire("jar-a", false)) {
                    fail("A request entered a resetting provider");
                } catch (InterruptedException expected) { cancelled.countDown(); }
            });
            assertTrue(started.await(2, TimeUnit.SECONDS));
            request.cancel(true);
            assertTrue(cancelled.await(2, TimeUnit.SECONDS));
        } finally { worker.shutdownNow(); }
    }
}
