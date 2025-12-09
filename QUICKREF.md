# ASICBoost/Version-Rolling Quick Reference

## ⚠️ WARNING: Protocol Stub Only

**This is NOT a performance optimization!**

- ❌ Mining is NOT faster
- ❌ No midstate reuse (core ASICBoost feature)
- ❌ No computational benefit
- ✅ Protocol testing only

This implementation only speaks the BIP320 protocol for testing P2Pool infrastructure.

---

## What Was Implemented

✅ **BIP320 Version-Rolling Support** for testing P2Pool ASICBoost implementations

## Key Changes

| File | What Changed | Why |
|------|-------------|-----|
| **miner.h** | Added version-rolling fields to stratum_ctx | Store negotiation state |
| **util.c** | Added stratum_configure() function | Negotiate version-rolling with pool |
| **cpu-miner.c** | Modified work generation & submit | Apply version bits & include in submit |

## Quick Commands

```bash
# Build
./build.sh

# Quick test
./test_asicboost.sh

# Full test with P2Pool
./cpuminer -a x11 -o stratum+tcp://192.168.86.244:7903 \
  -u XsFe6mGpLM3R6ZieYJXhsmGyYg8jn3Lth6 -p x -D

# Test with standard pool (should fallback gracefully)
./cpuminer -a x11 -o stratum+tcp://pool.example.com:3333 \
  -u worker -p x
```

## Success Indicators

### ✅ Version-Rolling Enabled
```
[11:17:45] Stratum session id: ae6812eb4cd7735a302a8a9dd95cf71f
[11:17:45] ✓ ASICBoost version-rolling enabled: mask=0x1fffe000  ← THIS!
[11:17:45] Stratum difficulty set to 0.01
```

### ✅ Graceful Fallback (No Support)
```
[11:17:45] Stratum session id: abc123def456
[11:17:45] Stratum difficulty set to 1.0
```
(No ASICBoost message = working normally without version-rolling)

## Debug Output (with -D flag)

```
[11:17:46] DEBUG: Version rolling: 0x20000000 -> 0x20004000 (mask=0x1fffe000)
[11:17:47] DEBUG: Submit with version_bits: 0x00004000
```

## Protocol Flow

```
Client                          Pool
  │                              │
  ├─► mining.subscribe ─────────►│
  │◄──────────── [session] ─────┤
  │                              │
  ├─► mining.configure ──────────►│  ← NEW
  │◄─── {version-rolling:true} ─┤  ← NEW
  │                              │
  ├─► mining.authorize ─────────►│
  │◄────────── {result:true} ────┤
  │                              │
  │◄────── mining.notify ────────┤
  │                              │
  ├─► mining.submit [5 params] ─►│  ← Was this
  ├─► mining.submit [6 params] ─►│  ← Now this (with version_bits)
  │                              │
```

## Version Bits Explained

```
Block Version:  0x20000000
                ││││││││
Mask:          0x1fffe000  (13 bits at positions 13-25)
                  ││││││
Applied Bits:  0x00004000  (varies per work unit)
                    ││
Result:        0x20004000  (combined version)
```

## Submit Format

### Standard (Before)
```json
["user", "job_id", "xnonce2", "ntime", "nonce"]
```

### With Version-Rolling (After)
```json
["user", "job_id", "xnonce2", "ntime", "nonce", "00004000"]
                                                    ^^^^^^^^
                                                    version_bits
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| No ASICBoost message | Normal - pool doesn't support it |
| Build fails | Run `make clean && ./build.sh` |
| Connection fails | Check pool address and port |
| Shares rejected | Enable `-D` flag and check logs |

## Important Notes

⚠️ **No Performance Benefit for CPUs** - This is for testing ONLY  
✅ **Backward Compatible** - Works with all pools  
✅ **Safe** - Graceful fallback if not supported  
✅ **BIP320 Compliant** - Follows specification exactly  

## Files to Read

1. **ASICBOOST_TESTING.md** - Full testing guide
2. **IMPLEMENTATION_SUMMARY.md** - Technical details
3. **CHANGES.md** - Code changes
4. **test_asicboost.sh** - Automated test

## One-Line Summary

> Added BIP320 version-rolling to cpuminer-multi for testing P2Pool ASICBoost: auto-negotiates with `mining.configure`, applies version bits to work, submits with 6th parameter. Backward compatible, graceful fallback.

---

**Status:** ✅ Ready to Test  
**Date:** December 9, 2025  
**Compatibility:** All pools (version-rolling optional)
