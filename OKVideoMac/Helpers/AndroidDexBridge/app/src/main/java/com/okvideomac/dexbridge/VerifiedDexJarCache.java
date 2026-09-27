package com.okvideomac.dexbridge;

import android.system.Os;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/** Keeps incomplete downloads away from files that DexClassLoader can load. */
final class VerifiedDexJarCache {
    static final long MAX_BYTES = 16L * 1024L * 1024L;

    interface DownloadBody {
        void writeTo(String url, OutputStream output) throws Exception;
    }

    interface AtomicPublisher {
        void replace(File source, File destination) throws Exception;
    }

    static final class Failure extends IOException {
        final String stage;

        Failure(String stage, String message) {
            super("DEX_CACHE_" + stage.toUpperCase(Locale.ROOT) + ": " + message);
            this.stage = stage;
        }

        Failure(String stage, String message, Throwable cause) {
            super("DEX_CACHE_" + stage.toUpperCase(Locale.ROOT) + ": " + message,
                    cause);
            this.stage = stage;
        }
    }

    private final File directory;
    private final AtomicPublisher publisher;
    private final Map<String, Object> locks = new ConcurrentHashMap<>();

    VerifiedDexJarCache(File directory) {
        this(directory, (source, destination) -> Os.rename(
                source.getAbsolutePath(), destination.getAbsolutePath()
        ));
    }

    VerifiedDexJarCache(File directory, AtomicPublisher publisher) {
        this.directory = directory;
        this.publisher = publisher;
    }

    File load(String url, String rawMD5, DownloadBody download) throws Exception {
        String expectedMD5 = rawMD5.trim().toLowerCase(Locale.ROOT);
        if (!expectedMD5.isEmpty() && !expectedMD5.matches("[0-9a-f]{32}")) {
            throw new Failure("integrity", "插件配置的 MD5 格式无效");
        }
        String key = sha256(url + "\n" + expectedMD5);
        synchronized (locks.computeIfAbsent(key, ignored -> new Object())) {
            if (!directory.isDirectory() && !directory.mkdirs()) {
                throw new Failure("write", "无法创建插件缓存目录");
            }
            File output = new File(directory, key + ".jar");
            discardAbandonedParts(key);
            if (valid(output, expectedMD5)) return output;

            // Earlier releases used a URL-only cache key. A zero-byte file
            // left read-only by an interrupted request caused every retry to
            // fail when FileOutputStream tried to overwrite it. An intact old
            // entry may still be reused without touching account storage.
            File legacy = new File(directory, sha256(url) + ".jar");
            if (valid(legacy, expectedMD5)) return legacy;
            if (legacy.isFile() && legacy.length() == 0 && !legacy.delete()) {
                throw new Failure("write", "无法移除空的旧版插件缓存");
            }

            File part = File.createTempFile(key + ".part-", ".tmp", directory);
            try {
                try (FileOutputStream stream = new FileOutputStream(part)) {
                    // Android requires dynamically loaded code to be read-only.
                    // Mark the file while its write descriptor is already open,
                    // before writing any untrusted bytes.
                    if (!part.setReadOnly()) {
                        throw new Failure("write", "无法保护插件下载文件");
                    }
                    try {
                        download.writeTo(url, new BoundedOutputStream(stream));
                    } catch (Failure error) {
                        throw error;
                    } catch (Exception error) {
                        throw new Failure("download", "插件下载中断或失败", error);
                    }
                    stream.getFD().sync();
                }
                if (!valid(part, expectedMD5)) {
                    throw new Failure("integrity", "插件为空、格式无效或 MD5 不匹配");
                }
                try {
                    // Both paths are inside the private cache directory.
                    // Android's POSIX rename atomically replaces the target
                    // and is available throughout the API-24 support range.
                    publisher.replace(part, output);
                } catch (Exception error) {
                    throw new Failure("write", "无法发布已校验的插件", error);
                }
                return output;
            } finally {
                // If the process is killed, the next load also removes this
                // version's abandoned part files before trying again.
                if (part.exists()) part.delete();
            }
        }
    }

    private void discardAbandonedParts(String key) {
        File[] parts = directory.listFiles((dir, name) ->
                name.startsWith(key + ".part-") && name.endsWith(".tmp"));
        if (parts == null) return;
        for (File part : parts) {
            if (part.isFile()) part.delete();
        }
    }

    private static boolean valid(File file, String expectedMD5) throws Exception {
        if (!file.isFile() || file.length() < 4 || file.length() > MAX_BYTES) {
            return false;
        }
        try (FileInputStream input = new FileInputStream(file)) {
            byte[] magic = new byte[4];
            if (input.read(magic) != magic.length) return false;
            boolean archive = magic[0] == 'P' && magic[1] == 'K'
                    && magic[2] == 3 && magic[3] == 4;
            boolean dex = magic[0] == 'd' && magic[1] == 'e'
                    && magic[2] == 'x' && magic[3] == '\n';
            if (!archive && !dex) return false;
        } catch (IOException error) {
            return false;
        }
        return expectedMD5.isEmpty() || expectedMD5.equals(md5(file));
    }

    private static String md5(File file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("MD5");
        try (FileInputStream input = new FileInputStream(file)) {
            byte[] buffer = new byte[16_384];
            int count;
            while ((count = input.read(buffer)) != -1) {
                digest.update(buffer, 0, count);
            }
        }
        return hex(digest.digest());
    }

    static String sha256(String value) throws Exception {
        return hex(MessageDigest.getInstance("SHA-256")
                .digest(value.getBytes(StandardCharsets.UTF_8)));
    }

    private static String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder(bytes.length * 2);
        for (byte item : bytes) {
            result.append(String.format(Locale.ROOT, "%02x", item));
        }
        return result.toString();
    }

    private static final class BoundedOutputStream extends OutputStream {
        private final OutputStream output;
        private long written;

        BoundedOutputStream(OutputStream output) {
            this.output = output;
        }

        @Override public void write(int value) throws IOException {
            check(1);
            output.write(value);
        }

        @Override public void write(byte[] bytes, int offset, int length)
                throws IOException {
            check(length);
            output.write(bytes, offset, length);
        }

        private void check(int length) throws IOException {
            if (Thread.currentThread().isInterrupted()) {
                throw new Failure("cancelled", "插件下载已取消");
            }
            if (length < 0 || written + length > MAX_BYTES) {
                throw new Failure("integrity", "插件超过 16 MiB 限制");
            }
            written += length;
        }
    }
}
