# ASICBoost/Version-Rolling Testing Guide

## Implementation Summary

This patch adds BIP320 version-rolling support to cpuminer-multi for testing P2Pool ASICBoost implementations. The miner now:

1. Sends `mining.configure` to negotiate version-rolling after `mining.subscribe`
2. Applies version bits to block headers during work generation
3. Submits shares with the 6th parameter `version_bits` when version-rolling is enabled

## Changes Made

### Files Modified:

1. **miner.h** - Added version-rolling fields to `struct stratum_ctx`:
   - `bool version_rolling` - Is version-rolling enabled?
   - `uint32_t version_mask` - Mask from pool (e.g., 0x1fffe000)
   - `uint32_t version_counter` - Counter for version bits
   - `int next_id` - ID counter for JSON-RPC requests

2. **util.c** - Added `stratum_configure()` function:
   - Sends `mining.configure` with version-rolling parameters
   - Parses pool response and enables version-rolling if supported
   - Called automatically after successful `mining.subscribe`
   - Gracefully handles pools that don't support version-rolling

3. **cpu-miner.c** - Modified work generation and submission:
   - `stratum_gen_work()` - Applies version bits to work->data[0] when version-rolling is enabled
   - `submit_upstream_work()` - Includes 6th parameter `version_bits` in mining.submit

## Protocol Flow

### 1. Connection Establishment
```
Client → Pool: mining.subscribe
Pool → Client: {result: [session_id, extranonce1, extranonce2_size]}
```

### 2. Version-Rolling Negotiation (New)
```
Client → Pool: mining.configure
{
  "id": 2,
  "method": "mining.configure",
  "params": [
    ["version-rolling"],
    {
      "version-rolling.mask": "1fffe000",
      "version-rolling.min-bit-count": 2
    }
  ]
}

Pool → Client: mining.configure response
{
  "id": 2,
  "result": {
    "version-rolling": true,
    "version-rolling.mask": "1fffe000"
  }
}
```

### 3. Authorization
```
Client → Pool: mining.authorize
Pool → Client: {result: true}
```

### 4. Work Distribution
```
Pool → Client: mining.notify (job)
```

### 5. Share Submission (Modified)
```
Client → Pool: mining.submit with version_bits
{
  "method": "mining.submit",
  "params": [
    "worker_name",
    "job_id",
    "extranonce2",
    "ntime",
    "nonce",
    "00004000"  ← NEW: 6th parameter (version_bits)
  ],
  "id": 4
}
```

## Testing Instructions

### Quick Test
```bash
cd /home/user0/Github/cpuminer-multi
./cpuminer -a x11 \
  -o stratum+tcp://192.168.86.244:7903 \
  -u XsFe6mGpLM3R6ZieYJXhsmGyYg8jn3Lth6 \
  -p x \
  -D
```

### Expected Output (Success)
```
[2025-12-09 11:17:45] Starting Stratum on stratum+tcp://192.168.86.244:7903
[2025-12-09 11:17:45] Binding thread 0 to cpu 0
[2025-12-09 11:17:45] Binding thread 1 to cpu 1
[2025-12-09 11:17:45] 2 miner threads started, using 'x11' algorithm.
[2025-12-09 11:17:45] Stratum connection to 192.168.86.244:7903
[2025-12-09 11:17:45] Stratum session id: ae6812eb4cd7735a302a8a9dd95cf71f
[2025-12-09 11:17:45] ✓ ASICBoost version-rolling enabled: mask=0x1fffe000
[2025-12-09 11:17:45] Stratum difficulty set to 0.01
[2025-12-09 11:17:46] thread 0: 2048 hashes, 9.8 MH/s
```

The key indicator is: **`✓ ASICBoost version-rolling enabled: mask=0x1fffe000`**

### Expected Output (Pool Doesn't Support)
```
[2025-12-09 11:17:45] Stratum connection to pool.example.com:3333
[2025-12-09 11:17:45] Stratum session id: abc123...
[2025-12-09 11:17:45] Stratum difficulty set to 1.0
```

No ASICBoost message = pool doesn't support it (graceful fallback).

### Debug Mode Output
With `-D` flag, you'll see:
```
[2025-12-09 11:17:46] DEBUG: Version rolling: 0x20000000 -> 0x20004000 (mask=0x1fffe000)
[2025-12-09 11:17:47] DEBUG: Submit with version_bits: 0x00004000
```

## Verification Points

### 1. Check Miner Logs
Look for:
- ✅ `✓ ASICBoost version-rolling enabled: mask=0x1fffe000`
- ✅ No errors during mining.configure
- ✅ Shares being submitted successfully
- ✅ Debug logs showing version bits (with -D flag)

### 2. Check P2Pool Logs
On P2Pool side, verify:
```
>>>Authorize: XsFe6mGpLM3R6ZieYJXhsmGyYg8jn3Lth6 from 192.168.86.245
Miner using version-rolling: mask=1fffe000
```

### 3. Network Capture (Optional)
Use tcpdump to verify protocol:
```bash
sudo tcpdump -i any -A 'host 192.168.86.244 and port 7903'
```

Look for:
- `mining.configure` being sent
- Response with `"version-rolling": true`
- `mining.submit` with 6 parameters

## Compatibility

### Backward Compatible
- ✅ Works with pools that don't support version-rolling
- ✅ Gracefully falls back to standard 5-parameter submit
- ✅ No changes to mining efficiency (CPU mining)

### Protocol Compliant
- ✅ Follows BIP320 specification
- ✅ Uses standard 0x1fffe000 mask (13 bits, positions 13-25)
- ✅ Proper hexadecimal formatting for version_bits

## Performance Notes

**Important:** Version-rolling provides **NO performance benefit for CPU mining**. This implementation is purely for:
- Testing P2Pool ASICBoost infrastructure
- Protocol validation
- Development and debugging
- Educational purposes

ASICBoost's efficiency gains come from ASIC midstate optimization, which doesn't apply to CPU mining.

## Troubleshooting

### Problem: No version-rolling message
**Solution:** Pool may not support it. This is normal and expected with most pools.

### Problem: Connection fails after mining.configure
**Solution:** Pool may reject unknown methods. Check P2Pool implementation.

### Problem: Shares rejected
**Possible causes:**
1. P2Pool not reconstructing block header correctly from version_bits
2. Version bits being applied incorrectly
3. Pool expecting different format

**Debug:** Enable `-D` flag and check:
- Version bits in submit match what was applied to work
- P2Pool logs for version reconstruction

### Problem: Build errors
**Solution:**
```bash
cd /home/user0/Github/cpuminer-multi
make clean
./build.sh
```

## Code References

### stratum_configure() - util.c:1368
Handles version-rolling negotiation:
- Sends mining.configure request
- Parses pool response
- Sets version_rolling flag and mask

### stratum_gen_work() - cpu-miner.c:1830
Applies version bits to work:
```c
if (sctx->version_rolling && sctx->version_mask) {
    uint32_t version_bits = ((sctx->version_counter++ & 0x1fff) << 13);
    work->data[0] = (current_version & ~sctx->version_mask) | 
                    (version_bits & sctx->version_mask);
}
```

### submit_upstream_work() - cpu-miner.c:1206
Includes version_bits in submit:
```c
if (stratum.version_rolling && stratum.version_mask) {
    uint32_t version_bits = nversion & stratum.version_mask;
    snprintf(s, JSON_BUF_LEN,
        "{\"method\": \"mining.submit\", \"params\": "
        "[\"%s\", \"%s\", \"%s\", \"%s\", \"%s\", \"%08x\"], \"id\":4}",
        rpc_user, work->job_id, xnonce2str, ntimestr, noncestr, version_bits);
}
```

## Testing Matrix

| Pool Type | Expected Behavior | Test Status |
|-----------|------------------|-------------|
| P2Pool with ASICBoost | Version-rolling enabled | ✅ To test |
| Standard pool | Graceful fallback | ✅ To test |
| Legacy pool | Works normally | ✅ To test |

## Next Steps

1. **Test with P2Pool**: Run against local P2Pool instance
2. **Verify Protocol**: Check P2Pool logs for correct handling
3. **Monitor Shares**: Ensure shares are accepted
4. **Debug Issues**: Use -D flag if problems occur

## Additional Resources

- BIP320: https://github.com/bitcoin/bips/blob/master/bip-0320.mediawiki
- BIP310: https://github.com/bitcoin/bips/blob/master/bip-0310.mediawiki
- Stratum Protocol: https://braiins.com/stratum-v1/docs

## Support

For issues or questions:
1. Check debug output with `-D` flag
2. Review P2Pool logs
3. Verify network connectivity
4. Test with standard pool first
