package com.okvideomac.dexbridge;

import java.io.InputStream;
import java.io.ByteArrayOutputStream;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import okhttp3.Call;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import org.json.JSONArray;
import org.json.JSONObject;

/** Acceptance-only: at most five 8193-byte reads, six seconds each. No URLs,
 * arbitrary headers, exception text or media payload can enter the result. */
final class MediaRangeAudit {
    private static final OkHttpClient CLIENT = new OkHttpClient.Builder()
            .followRedirects(false).followSslRedirects(false)
            .retryOnConnectionFailure(false).callTimeout(6, TimeUnit.SECONDS).build();

    static JSONObject run(BridgeMediaSessionRegistry.Session session,
                          Map<String, String> headers, boolean supported) {
        JSONObject result = new JSONObject();
        JSONArray reads = new JSONArray();
        try {
            result.put("reads", reads);
            if (!supported) return result.put("outcome", "unsupported_owner_proxy");
            Sample head = read(session.upstreamURL, headers, 0, 8192, false);
            reads.put(head.metadata.put("path", "upstream_head"));
            Sample offset = read(session.upstreamURL, headers, 4096, 4096, false);
            reads.put(offset.metadata.put("path", "upstream_overlap"));
            int overlap = Math.min(head.bytes.length - 4096, offset.bytes.length);
            result.put("overlapBytes", Math.max(0, overlap));
            result.put("overlapEqual", overlap >= 1024
                    && Arrays.equals(Arrays.copyOfRange(head.bytes, 4096, 4096 + overlap), Arrays.copyOf(offset.bytes, overlap)));
            String relay = "http://127.0.0.1:" + BridgeServer.PORT + "/proxy/media/" + session.id;
            Sample bridged = read(relay, java.util.Collections.emptyMap(), 4096, 4096, false);
            reads.put(bridged.metadata.put("path", "bridge_overlap"));
            result.put("bridgeBytesEqual", Arrays.equals(offset.bytes, bridged.bytes));
            int shared = Math.min(offset.bytes.length, bridged.bytes.length);
            result.put("bridgeOverlapBytes", shared);
            result.put("bridgeOverlapEqual", shared >= 1024
                    && Arrays.equals(Arrays.copyOf(offset.bytes, shared), Arrays.copyOf(bridged.bytes, shared)));
            // Only a probe candidate: its validity requires tail EOF and range
            // evidence. Never feed this inferred number into the player.
            long candidate = head.length;
            if (candidate > 8192) {
                Sample tail = read(session.upstreamURL, headers, candidate - 4096, 4096, true);
                reads.put(tail.metadata.put("path", "upstream_tail"));
                Sample tailAgain = read(session.upstreamURL, headers, candidate - 4096, 4096, true);
                reads.put(tailAgain.metadata.put("path", "upstream_tail_repeat"));
                result.put("tailRepeatEqual", Arrays.equals(tail.bytes, tailAgain.bytes));
                result.put("candidateLength", candidate);
                result.put("candidateTailEOF", tail.eof && tail.bytes.length == 4096);
            }
            return result.put("outcome", "completed");
        } catch (Exception error) {
            try { result.put("outcome", "incomplete"); } catch (Exception ignored) { }
            return result;
        }
    }

    private static Sample read(String url, Map<String, String> headers, long start, int count, boolean openEnded) throws Exception {
        Request.Builder builder = new Request.Builder().url(url);
        for (Map.Entry<String, String> h : headers.entrySet()) {
            if (!h.getKey().equalsIgnoreCase("Range") && !h.getKey().equalsIgnoreCase("Accept-Encoding"))
                builder.header(h.getKey(), h.getValue());
        }
        builder.header("Range", "bytes=" + start + "-" + (openEnded ? "" : Long.toString(start + count - 1)));
        builder.header("Accept-Encoding", "identity");
        Call call = CLIENT.newCall(builder.build());
        try (Response response = call.execute()) {
            JSONObject metadata = new JSONObject().put("offset", start).put("budget", count + 1)
                    .put("status", response.code())
                    .put("contentRange", BridgeServer.safeByteMetadata(response.header("Content-Range")))
                    .put("contentLength", BridgeServer.safeByteMetadata(response.header("Content-Length")));
            long length = -1;
            try { length = Long.parseLong(response.header("Content-Length")); } catch (Exception ignored) { }
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            boolean eof = false;
            if (response.body() != null && response.isSuccessful()) {
                InputStream input = response.body().byteStream();
                byte[] buffer = new byte[4096];
                while (bytes.size() < count + 1) {
                    int n = input.read(buffer, 0, Math.min(buffer.length, count + 1 - bytes.size()));
                    if (n == -1) { eof = true; break; }
                    bytes.write(buffer, 0, n);
                }
            }
            byte[] sample = bytes.toByteArray();
            metadata.put("bytes", sample.length).put("eof", eof).put("sha256", digest(sample));
            if (start == 0 && sample.length >= 8) {
                String signature = sample[4] == 'f' && sample[5] == 't' && sample[6] == 'y' && sample[7] == 'p'
                        ? "iso_bmff" : sample[0] == 0x1a && sample[1] == 0x45 && (sample[2] & 255) == 0xdf && (sample[3] & 255) == 0xa3
                        ? "ebml" : "other";
                metadata.put("containerSignature", signature);
            }
            return new Sample(metadata, sample, length, eof);
        } finally { call.cancel(); }
    }

    private static String digest(byte[] bytes) throws Exception {
        StringBuilder result = new StringBuilder();
        for (byte value : MessageDigest.getInstance("SHA-256").digest(bytes))
            result.append(String.format(java.util.Locale.ROOT, "%02x", value & 255));
        return result.toString();
    }
    private static final class Sample {
        final JSONObject metadata;
        final byte[] bytes;
        final long length;
        final boolean eof;
        Sample(JSONObject metadata, byte[] bytes, long length, boolean eof) {
            this.metadata = metadata; this.bytes = bytes; this.length = length; this.eof = eof;
        }
    }
}
