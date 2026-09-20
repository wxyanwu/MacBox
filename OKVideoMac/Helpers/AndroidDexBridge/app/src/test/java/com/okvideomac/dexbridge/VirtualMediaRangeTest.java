package com.okvideomac.dexbridge;

import org.junit.Test;
import static org.junit.Assert.*;
import java.io.IOException;
import java.util.Arrays;

public final class VirtualMediaRangeTest {
    @Test public void repeatingBytesCannotProveCoordinates() {
        assertNull(VirtualMediaRange.prove(100000, new byte[8192], new byte[4096], "bytes 4104-100007/100008"));
    }
    @Test public void anotherSessionCannotInheritProof() {
        BridgeMediaSessionRegistry.Session a = new BridgeMediaSessionRegistry.Session("A", "http://127.0.0.1/media", java.util.Collections.emptyMap(), null);
        BridgeMediaSessionRegistry.Session b = new BridgeMediaSessionRegistry.Session("B", "http://127.0.0.1/media", java.util.Collections.emptyMap(), null);
        a.virtualRange = proof(100000,8); a.virtualRangeProbeAttempted = true;
        assertNull(b.virtualRange); assertFalse(b.virtualRangeProbeAttempted);
    }
    @Test public void credentialRevisionInvalidatesProof() {
        BridgeMediaSessionRegistry.Session a = new BridgeMediaSessionRegistry.Session("A", "http://127.0.0.1/media", java.util.Collections.emptyMap(), null);
        a.virtualRange = proof(100000,8); a.virtualRangeProbeAttempted = true;
        a.mergeHeaders(java.util.Collections.singletonMap("Authorization", "SECRET_TOKEN_DO_NOT_PERSIST"));
        assertNull(a.virtualRange); assertFalse(a.virtualRangeProbeAttempted);
    }
    @Test public void UnchangedHeaderSnapshotRetainsProof() {
        BridgeMediaSessionRegistry.Session a = new BridgeMediaSessionRegistry.Session("A", "http://127.0.0.1/media", java.util.Collections.emptyMap(), null);
        VirtualMediaRange verified = proof(100000,8); a.virtualRange = verified; a.virtualRangeProbeAttempted = true;
        a.mergeHeaders(java.util.Collections.emptyMap());
        assertSame(verified,a.virtualRange); assertTrue(a.virtualRangeProbeAttempted);
    }
    private byte[] head() {
        byte[] bytes = new byte[8192];
        for (int i = 0; i < bytes.length; i++) bytes[i] = (byte) ((i * 31 + i / 256) % 251);
        return bytes;
    }
    private VirtualMediaRange proof(long size, int prefix) {
        byte[] h = head();
        return VirtualMediaRange.prove(size, h, Arrays.copyOfRange(h, 4096, 8192),
                "bytes " + (4096 + prefix) + "-" + (size + prefix - 1) + "/" + (size + prefix));
    }
    @Test public void verifiesRealObservedCoordinateShape() throws Exception {
        VirtualMediaRange value = proof(2332265707L, 8);
        assertNotNull(value);
        assertEquals("bytes 15588863-2332265706/2332265707", value.downstreamRange("bytes=15588863-", "bytes 15588871-2332265714/2332265715"));
    }
    @Test public void noFixedEightByteAssumption() throws Exception {
        VirtualMediaRange value = proof(100000, 32);
        assertNotNull(value);
        assertEquals("bytes=4096-8223", value.upstreamRange("bytes=4096-8191"));
    }
    @Test public void firstResponseExpressesLogicalLength() throws Exception {
        assertEquals("bytes 0-99999/100000", proof(100000, 8).downstreamRange("bytes=0-", "bytes 0"));
    }
    @Test public void boundedRangeTranslatesOnlyEnd() throws Exception {
        assertEquals("bytes=4096-8199", proof(100000, 8).upstreamRange("bytes=4096-8191"));
    }
    @Test public void openRangeUnchanged() throws Exception {
        assertEquals("bytes=12345-", proof(100000, 8).upstreamRange("bytes=12345-"));
    }
    @Test public void boundsToKnownLogicalEOF() throws Exception {
        assertEquals("bytes=99990-100007", proof(100000, 8).upstreamRange("bytes=99990-200000"));
    }
    @Test public void supportsMoreThanFourGiB() throws Exception {
        VirtualMediaRange value = proof(6000000000L, 16);
        assertEquals("bytes 5000000000-5999999999/6000000000", value.downstreamRange("bytes=5000000000-", "bytes 5000000016-6000000015/6000000016"));
    }
    @Test public void mismatchedBytesCannotAuthorizeRepair() {
        byte[] h = head(), offset = Arrays.copyOfRange(h, 4096, 8192); offset[300] ^= 1;
        assertNull(VirtualMediaRange.prove(100000, h, offset, "bytes 4104-100007/100008"));
    }
    @Test public void insufficientOverlapCannotAuthorizeRepair() {
        assertNull(VirtualMediaRange.prove(100000, head(), new byte[4088], "bytes 4104-100007/100008"));
    }
    @Test public void inconsistentLengthRejected() {
        byte[] h = head();
        assertNull(VirtualMediaRange.prove(100001, h, Arrays.copyOfRange(h,4096,8192), "bytes 4104-100007/100008"));
    }
    @Test public void zeroShiftNeedsNoCompatibility() { assertNull(proof(100000, 0)); }
    @Test public void excessiveShiftRejected() { assertNull(proof(100000, 4097)); }
    @Test public void unknownLengthRemainsUnknown() {
        assertNull(VirtualMediaRange.prove(-1, head(), new byte[4096], "bytes 4104-100007/100008"));
    }
    @Test public void malformedContentRangeRejected() {
        for (String s : new String[] {"bytes 0", "bytes 4-2/10", "bytes 0-10/10", "bytes 0-9/*", "bytes 0-9/999999999999999999999", "SECRET_TOKEN_DO_NOT_PERSIST"})
            assertNull(VirtualMediaRange.contentRange(s));
    }
    @Test public void rangeArithmeticDoesNotOverflow() {
        assertArrayEquals(new long[]{0,Long.MAX_VALUE-1,Long.MAX_VALUE}, VirtualMediaRange.contentRange("bytes 0-9223372036854775806/9223372036854775807"));
    }
    @Test public void multiRangeAndSuffixFailClosed() {
        for (String s : new String[]{"bytes=-99", "bytes=0-1,4-5", "bytes=2-1", "bytes=9223372036854775808-"})
            assertNull(VirtualMediaRange.requestedRange(s));
    }
    @Test(expected=IOException.class) public void changedTotalBlocked() throws Exception {
        proof(100000,8).downstreamRange("bytes=4096-", "bytes 4104-100008/100009");
    }
    @Test(expected=IOException.class) public void changedOffsetBlocked() throws Exception {
        proof(100000,8).downstreamRange("bytes=4096-", "bytes 4105-100007/100008");
    }
    @Test(expected=IOException.class) public void seekAtEOFNotInvented() throws Exception {
        proof(100000,8).upstreamRange("bytes=100000-");
    }
    @Test public void validOrdinaryRangePreservesAllCoordinates() {
        assertArrayEquals(new long[]{4096,8191,5169745277L},VirtualMediaRange.contentRange("bytes 4096-8191/5169745277"));
    }
}
