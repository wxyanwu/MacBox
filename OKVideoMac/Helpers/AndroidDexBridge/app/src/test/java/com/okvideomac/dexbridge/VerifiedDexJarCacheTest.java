package com.okvideomac.dexbridge;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import static org.junit.Assert.*;

public final class VerifiedDexJarCacheTest {
    @Rule public TemporaryFolder temporary = new TemporaryFolder();

    private static final byte[] JAR = new byte[] {
            'P', 'K', 3, 4, 7, 8, 9, 10
    };

    private static VerifiedDexJarCache cache(File directory) {
        return new VerifiedDexJarCache(directory, (source, destination) ->
                Files.move(
                        source.toPath(), destination.toPath(),
                        StandardCopyOption.ATOMIC_MOVE,
                        StandardCopyOption.REPLACE_EXISTING
                )
        );
    }

    @Test public void readOnlyEmptyLegacyCacheRecoversWithoutTouchingOtherFiles()
            throws Exception {
        File directory = temporary.newFolder("jars");
        String url = "https://example.invalid/fixture.jar";
        File legacy = new File(
                directory, VerifiedDexJarCache.sha256(url) + ".jar"
        );
        assertTrue(legacy.createNewFile());
        assertTrue(legacy.setReadOnly());
        File unrelated = new File(directory, "unrelated-account-data");
        Files.write(unrelated.toPath(), new byte[] {42});

        File loaded = cache(directory).load(
                url, md5(JAR), (ignored, output) -> output.write(JAR)
        );

        assertArrayEquals(JAR, Files.readAllBytes(loaded.toPath()));
        assertFalse(legacy.exists());
        assertArrayEquals(new byte[] {42}, Files.readAllBytes(unrelated.toPath()));
    }

    @Test public void interruptedDownloadCannotPublishPartialJar() throws Exception {
        File directory = temporary.newFolder("jars");
        VerifiedDexJarCache cache = cache(directory);
        String url = "https://example.invalid/interrupted.jar";
        try {
            cache.load(url, md5(JAR), (ignored, output) -> {
                output.write(JAR, 0, 4);
                throw new IOException("connection interrupted");
            });
            fail("partial download was accepted");
        } catch (VerifiedDexJarCache.Failure error) {
            assertEquals("download", error.stage);
        }
        assertEquals(0, directory.listFiles().length);

        File loaded = cache.load(
                url, md5(JAR), (ignored, output) -> output.write(JAR)
        );
        assertArrayEquals(JAR, Files.readAllBytes(loaded.toPath()));
    }

    @Test public void wrongMD5CannotReplacePreviouslyVerifiedVersion()
            throws Exception {
        File directory = temporary.newFolder("jars");
        VerifiedDexJarCache cache = cache(directory);
        String url = "https://example.invalid/version.jar";
        File previous = cache.load(
                url, md5(JAR), (ignored, output) -> output.write(JAR)
        );
        byte[] changed = Arrays.copyOf(JAR, JAR.length);
        changed[7] = 11;
        try {
            cache.load(url, md5(changed),
                    (ignored, output) -> output.write(JAR));
            fail("incorrect version was accepted");
        } catch (VerifiedDexJarCache.Failure error) {
            assertEquals("integrity", error.stage);
        }
        assertArrayEquals(JAR, Files.readAllBytes(previous.toPath()));
        assertEquals(1, directory.listFiles().length);
    }

    @Test public void simultaneousRequestsForSameVersionDownloadOnce()
            throws Exception {
        File directory = temporary.newFolder("jars");
        VerifiedDexJarCache cache = cache(directory);
        AtomicInteger downloads = new AtomicInteger();
        CountDownLatch start = new CountDownLatch(1);
        ExecutorService workers = Executors.newFixedThreadPool(2);
        try {
            java.util.concurrent.Callable<File> load = () -> {
                start.await();
                return cache.load("https://example.invalid/shared.jar", md5(JAR),
                        (ignored, output) -> {
                            downloads.incrementAndGet();
                            output.write(JAR);
                        });
            };
            Future<File> first = workers.submit(load);
            Future<File> second = workers.submit(load);
            start.countDown();
            assertEquals(first.get(5, TimeUnit.SECONDS),
                    second.get(5, TimeUnit.SECONDS));
            assertEquals(1, downloads.get());
        } finally {
            workers.shutdownNow();
        }
    }

    private static String md5(byte[] bytes) throws Exception {
        byte[] digest = MessageDigest.getInstance("MD5").digest(bytes);
        StringBuilder result = new StringBuilder();
        for (byte value : digest) {
            result.append(String.format("%02x", value));
        }
        return result.toString();
    }
}
