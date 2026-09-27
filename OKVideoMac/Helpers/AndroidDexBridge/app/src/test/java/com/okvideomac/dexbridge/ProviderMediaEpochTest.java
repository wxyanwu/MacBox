package com.okvideomac.dexbridge;

import org.junit.Test;
import java.io.*;
import java.util.UUID;
import static org.junit.Assert.*;

public class ProviderMediaEpochTest {
    @Test public void switchedProxyCannotReturnBThroughOldACapability() throws Exception {
        String jar = UUID.randomUUID().toString();
        long a = ProviderMediaEpoch.current(jar);
        byte[][] target = {new byte[]{'A'}};
        InputStream proxy = new InputStream() {
            @Override public int read() { return target[0][0]; }
        };
        InputStream oldSession = ProviderMediaEpoch.guard(proxy, jar, a);
        assertEquals('A', oldSession.read());
        ProviderMediaEpoch.advance(jar);
        target[0] = new byte[]{'B'};
        assertThrows(IOException.class, oldSession::read);
        InputStream newSession = ProviderMediaEpoch.guard(proxy, jar, ProviderMediaEpoch.current(jar));
        assertEquals('B', newSession.read());
        ProviderMediaEpoch.advance(jar);
        target[0] = new byte[]{'A'};
        assertEquals('A', ProviderMediaEpoch.guard(proxy, jar, ProviderMediaEpoch.current(jar)).read());
        assertThrows(IOException.class, newSession::read);
    }

    @Test public void switchDuringBlockedReadIsRejectedBeforeBytesAreReturned() throws Exception {
        String jar = UUID.randomUUID().toString();
        long generation = ProviderMediaEpoch.current(jar);
        InputStream source = new InputStream() {
            @Override public int read() {
                ProviderMediaEpoch.advance(jar);
                return 'B';
            }
        };
        InputStream guarded = ProviderMediaEpoch.guard(source, jar, generation);
        assertThrows(IOException.class, () -> guarded.read(new byte[1], 0, 1));
    }

    @Test public void authorizationChangeCannotRelabelInFlightOrCachedPlayback() {
        String jar = UUID.randomUUID().toString();
        long resolvingA = ProviderMediaEpoch.advance(jar);
        ProviderMediaEpoch.requireCurrent(jar, resolvingA);
        long afterAuthorization = ProviderMediaEpoch.advance(jar);
        assertThrows(IllegalStateException.class, () -> ProviderMediaEpoch.requireCurrent(jar, resolvingA));
        ProviderMediaEpoch.requireCurrent(jar, afterAuthorization);
        long resolvingB = ProviderMediaEpoch.advance(jar);
        assertThrows(IllegalStateException.class, () -> ProviderMediaEpoch.requireCurrent(jar, afterAuthorization));
        ProviderMediaEpoch.requireCurrent(jar, resolvingB);
    }

    @Test public void independentJarIsUnaffected() throws Exception {
        String jar = UUID.randomUUID().toString();
        InputStream source = ProviderMediaEpoch.guard(new ByteArrayInputStream(new byte[]{'A'}), jar, ProviderMediaEpoch.current(jar));
        ProviderMediaEpoch.advance(UUID.randomUUID().toString());
        assertEquals('A', source.read());
    }
}
