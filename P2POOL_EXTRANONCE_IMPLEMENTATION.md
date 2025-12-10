# P2Pool Extranonce Support - Implementation Guide

## Overview

Many X11 ASICs (Antminer D3, Innosilicon A5, etc.) **require** `mining.set_extranonce` support to function properly with stratum pools. Without this feature, P2Pool cannot support ASIC miners, severely limiting its usability.

## The Problem

### Why ASICs Need Extranonce Updates

1. **Limited Nonce Space**: ASICs have hardware-optimized nonce iteration
   - Can exhaust 32-bit nonce space in seconds
   - Cannot easily change other header fields (timestamp, coinbase, etc.)

2. **Hardware Limitations**: ASIC firmware expects dynamic extranonce
   - Many ASICs have `mining.set_extranonce` hardcoded as required
   - Cannot disable or work around this requirement
   - Will disconnect or stall if not receiving extranonce updates

3. **Current P2Pool Behavior**:
   ```python
   # Line 78-79 in stratum.py
   if 'subscribe-extranonce' in extensions:
       print 'Extension method subscribe-extranonce not implemented'
   ```
   - Acknowledges `subscribe-extranonce` but doesn't implement it
   - ASICs receive new work (`mining.notify`) but with static extranonce
   - ASICs exhaust nonce space and cannot continue

### Impact

| Miner Type | Current Status | Why |
|------------|---------------|-----|
| CPU Miners | ✅ Works | Can iterate through full nonce space |
| GPU Miners | ✅ Works | Sufficient nonce space, slow enough |
| ASIC Miners | ❌ Broken | Exhaust nonce space, require extranonce updates |

## Required Implementation

### 1. Implement `mining.extranonce.subscribe` Method (NiceHash Protocol)

**Location**: `stratum.py`, add new RPC method

**Implementation** (Required for ASIC compatibility):
```python
def rpc_extranonce_subscribe(self):
    """
    Handle mining.extranonce.subscribe request (NiceHash protocol)
    
    This is the PRIMARY method used by ASICs to subscribe to extranonce updates.
    Sent as a separate request AFTER mining.subscribe.
    
    Request: {"id": 3, "method": "mining.extranonce.subscribe", "params": []}
    Response: {"id": 3, "result": true, "error": null}
    
    Returns:
        True on success (enables extranonce updates for this connection)
    """
    # Enable extranonce subscription for this connection
    self.extranonce_subscribe = True
    print '>>>ExtranOnce subscribed (NiceHash) from %s' % (self.worker_ip)
    
    # Return true to indicate support
    return True
```

**Note**: The method name in stratum.py should be `rpc_extranonce_subscribe` but the actual RPC method is `mining.extranonce.subscribe`. The framework maps `mining.X` to `rpc_X`.

### 2. Support `subscribe-extranonce` in mining.configure (BIP310 Protocol)

**Location**: `stratum.py`, `rpc_configure()` method (around line 78)

**Current Code**:
```python
if 'subscribe-extranonce' in extensions:
    print 'Extension method subscribe-extranonce not implemented'
```

**Required Change** (for modern miner compatibility):
```python
if 'subscribe-extranonce' in extensions:
    # Enable extranonce subscription for this connection (BIP310 method)
    self.extranonce_subscribe = True
    print '>>>ExtranOnce subscribed (BIP310) from %s' % (self.worker_ip)
    # Add to result object to confirm support
    result['subscribe-extranonce'] = True
```

**Why Both?**: 
- NiceHash protocol: Used by ASICs (Antminer, Innosilicon, Baikal)
- BIP310 protocol: Used by modern CPU/GPU miners
- Same internal flag (`self.extranonce_subscribe`) works for both
- No conflict - miners only use one or the other

### 3. Implement `mining.set_extranonce` Notification Handler

**Location**: `stratum.py`, add new RPC method

**Implementation**:
```python
def rpc_set_extranonce(self, extranonce1, extranonce2_size):
    """
    Handle mining.set_extranonce from pool/proxy
    
    This is sent BY THE POOL to miners when extranonce changes.
    Miners that subscribed to 'subscribe-extranonce' expect this.
    
    Args:
        extranonce1: New extranonce1 value (hex string)
        extranonce2_size: Size of extranonce2 in bytes (integer)
    
    Returns:
        True on success
    """
    if not hasattr(self, 'extranonce_subscribe') or not self.extranonce_subscribe:
        # Miner didn't subscribe to extranonce updates
        return False
    
    # Update the extranonce for this connection
    # Note: In P2Pool, extranonce is currently empty string
    # This would need to be enhanced if P2Pool starts using extranonce1
    
    if extranonce1:
        self.extranonce1 = extranonce1
    else:
        self.extranonce1 = ""
    
    if extranonce2_size != self.wb.COINBASE_NONCE_LENGTH:
        print >>sys.stderr, 'WARNING: extranonce2_size mismatch: expected %d, got %d' % (
            self.wb.COINBASE_NONCE_LENGTH, extranonce2_size)
    
    print '>>>Set extranonce: %s (size=%d) for %s' % (
        extranonce1 if extranonce1 else "(empty)", 
        extranonce2_size, 
        self.worker_ip
    )
    
    return True
```

### 4. Send `mining.set_extranonce` Notifications to Subscribed Miners

**Location**: `stratum.py`, add helper method

P2Pool currently uses an empty extranonce1 (`""`), but when it changes (or periodically for ASICs), send updates:

```python
def _notify_extranonce_change(self, new_extranonce1=None):
    """
    Notify miners that subscribed to extranonce updates
    Called when extranonce needs to change (e.g., reconnection, long mining session)
    """
    if not hasattr(self, 'extranonce_subscribe') or not self.extranonce_subscribe:
        return
    
    # Use current or new extranonce1
    extranonce1 = new_extranonce1 if new_extranonce1 is not None else ""
    extranonce2_size = self.wb.COINBASE_NONCE_LENGTH
    
    # Send mining.set_extranonce notification to miner
    self.other.svc_mining.rpc_set_extranonce(
        extranonce1,
        extranonce2_size
    ).addErrback(lambda err: None)
    
    print '>>>Notified extranonce change to %s: %s (size=%d)' % (
        self.worker_ip,
        extranonce1 if extranonce1 else "(empty)",
        extranonce2_size
    )
```

### 5. Periodic Extranonce Updates for ASICs

**Location**: `stratum.py`, in `_send_work()` method

ASICs benefit from periodic extranonce updates even if the value doesn't change (resets their internal state):

```python
def _send_work(self):
    try:
        x, got_response = self.wb.get_work(*self.wb.preprocess_request(
            '' if self.username is None else self.username))
    except:
        log.err()
        self.transport.loseConnection()
        return
    
    # ... existing difficulty and target code ...
    
    jobid = str(random.randrange(2**128))
    
    # For ASIC compatibility: periodically send extranonce updates
    # Even with empty extranonce, this helps ASICs reset their state
    if hasattr(self, 'extranonce_subscribe') and self.extranonce_subscribe:
        if not hasattr(self, 'last_extranonce_update'):
            self.last_extranonce_update = 0
        
        current_time = time.time()
        # Send extranonce update every 30 seconds or on first work
        if current_time - self.last_extranonce_update > 30:
            self._notify_extranonce_change()
            self.last_extranonce_update = current_time
    
    # ... rest of existing code ...
```

### 6. Update Initialization

**Location**: `stratum.py`, `__init__()` method

```python
def __init__(self, wb, other, transport):
    self.pool_version_mask = 0x1fffe000  # BIP320 standard mask for ASICBOOST
    self.wb = wb
    self.other = other
    self.transport = transport
    
    self.username = None
    self.worker_ip = transport.getPeer().host if transport else None
    self.handler_map = expiring_dict.ExpiringDict(300)
    
    # Add extranonce support tracking
    self.extranonce_subscribe = False
    self.extranonce1 = ""
    self.last_extranonce_update = 0
    
    self.watch_id = self.wb.new_work_event.watch(self._send_work)
    # ... rest of existing code ...
```

## Protocol Specification

### NiceHash Extranonce Protocol

**IMPORTANT**: Most ASICs use the **NiceHash extranonce protocol**, NOT the `mining.configure` extension!

#### Method 1: NiceHash Protocol (Required for ASIC compatibility)

**Request** (sent AFTER `mining.subscribe`, separate method):
```json
{
  "id": 3,
  "method": "mining.extranonce.subscribe",
  "params": []
}
```

**Success Response**:
```json
{
  "id": 3,
  "result": true,
  "error": null
}
```

**Failure Response**:
```json
{
  "id": 3,
  "result": false,
  "error": [20, "Not supported.", null]
}
```

**Notification** (sent by pool when extranonce changes):
```json
{
  "id": null,
  "method": "mining.set_extranonce",
  "params": ["08000002", 4]
}
```

#### Method 2: BIP310 Extension (Optional, for modern miners)

**Request** (in `mining.configure`):
```json
{
  "id": 2,
  "method": "mining.configure",
  "params": [
    ["subscribe-extranonce"],
    {}
  ]
}
```

**Response**:
```json
{
  "id": 2,
  "result": {
    "subscribe-extranonce": true
  }
}
```

### Mining.set_extranonce Notification

**Notification** (from pool to miner, no ID, miner doesn't respond):
```json
{
  "method": "mining.set_extranonce",
  "params": [
    "",           // extranonce1 (hex string, can be empty)
    4             // extranonce2_size (integer)
  ]
}
```

**When to Send**:
1. After miner subscribes to extranonce updates
2. When extranonce1 actually changes (if P2Pool implements non-empty extranonce)
3. Periodically (every 30-60 seconds) to help ASICs reset state
4. After reconnection or connection resumption

### Example: Both Protocols in Action

**ASIC Connection (NiceHash Protocol)**:
```
→ {"id": 1, "method": "mining.subscribe", "params": ["cpuminer/2.5.0"]}
← {"id": 1, "result": [["mining.notify", "ae6812eb4cd7735a302a8a9dd95cf71f"], "", 4], "error": null}

→ {"id": 3, "method": "mining.extranonce.subscribe", "params": []}
← {"id": 3, "result": true, "error": null}

→ {"id": 2, "method": "mining.authorize", "params": ["worker", "pass"]}
← {"id": 2, "result": true, "error": null}

← {"id": null, "method": "mining.set_extranonce", "params": ["", 4]}
← {"id": null, "method": "mining.notify", "params": [...]}
```

**Modern Miner Connection (BIP310 Protocol)**:
```
→ {"id": 1, "method": "mining.subscribe", "params": ["miner/1.0"]}
← {"id": 1, "result": [["mining.notify", "ae6812eb4cd7735a302a8a9dd95cf71f"], "", 4], "error": null}

→ {"id": 2, "method": "mining.configure", "params": [["subscribe-extranonce"], {}]}
← {"id": 2, "result": {"subscribe-extranonce": true}, "error": null}

→ {"id": 3, "method": "mining.authorize", "params": ["worker", "pass"]}
← {"id": 3, "result": true, "error": null}

← {"id": null, "method": "mining.set_extranonce", "params": ["", 4]}
← {"id": null, "method": "mining.notify", "params": [...]}
```

**Key Difference**: 
- NiceHash: Separate `mining.extranonce.subscribe` method
- BIP310: Extension in `mining.configure`
- Same notification: Both receive `mining.set_extranonce`

## Testing Checklist

### Phase 1: Basic Implementation
- [ ] Add `extranonce_subscribe` flag to connection state
- [ ] Handle `subscribe-extranonce` in `rpc_configure()`
- [ ] Implement `rpc_set_extranonce()` method
- [ ] Test with CPU miner (should not break anything)

### Phase 2: Notification Support
- [ ] Implement `_notify_extranonce_change()` helper
- [ ] Send `mining.set_extranonce` after subscription
- [ ] Add periodic updates (every 30 seconds)
- [ ] Test with CPU miner with extranonce subscription enabled

### Phase 3: ASIC Testing
- [ ] Test with Antminer D3 (X11 ASIC)
- [ ] Test with Innosilicon A5 (X11 ASIC)
- [ ] Test with Baikal BK-X (X11 ASIC)
- [ ] Verify shares are submitted continuously
- [ ] Verify no disconnections or stalls
- [ ] Monitor hashrate remains stable

### Phase 4: Stress Testing
- [ ] Test with multiple ASICs simultaneously
- [ ] Test with mixed CPU/GPU/ASIC connections
- [ ] Test long-running sessions (>24 hours)
- [ ] Test reconnection scenarios
- [ ] Monitor pool performance impact

## Validation with cpuminer-multi

### ✅ Response ID Handling Fixed

**IMPORTANT**: The `cpuminer-multi` in this repository (branch `asicboost-protocol-testing`) has been **fixed** to properly handle stratum protocol responses!

**The Fix** (`util.c`, lines 1385-1448 for `stratum_configure`, lines 1533-1570 for `stratum_authorize`):
- Loops until finding response with matching ID
- Handles unsolicited notifications (`mining.notify`, `mining.set_difficulty`) while waiting
- No more false "Stratum answer id is not correct!" errors

**Working Example**:
```
[2025-12-09 17:24:25] Starting Stratum on stratum+tcp://192.168.86.244:7903
[2025-12-09 17:24:25] Got notification mining.set_difficulty while waiting for configure response
[2025-12-09 17:24:25] Got notification mining.notify while waiting for configure response
[2025-12-09 17:24:25] ✓ ASICBoost version-rolling enabled: mask=0x1fffe000 (BE) = 0x00e0ff1f (LE)
[2025-12-09 17:24:25] Got notification mining.set_difficulty while waiting for extranonce response
[2025-12-09 17:24:25] Got notification mining.notify while waiting for extranonce response
[2025-12-09 17:24:25] extranonce.subscribe response received
```

### Extranonce Support

The cpuminer-multi already supports `mining.set_extranonce`:

**Code** (`util.c`, line 2299):
```c
if (!strcasecmp(method, "mining.set_extranonce")) {
    ret = stratum_parse_extranonce(sctx, params, 0);
    goto out;
}
```

**Test Command**:
```bash
./cpuminer -a x11 \
  -o stratum+tcp://192.168.86.244:7903 \
  -u XsFe6mGpLM3R6ZieYJXhsmGyYg8jn3Lth6 \
  -p x \
  --extranonce \
  -D
```

**Current Log Output** (extranonce.subscribe working, waiting for set_extranonce notifications):
```
[2025-12-09 17:24:25] Starting Stratum on stratum+tcp://192.168.86.244:7903
[2025-12-09 17:24:25] ✓ ASICBoost version-rolling enabled: mask=0x1fffe000 (BE) = 0x00e0ff1f (LE)
[2025-12-09 17:24:25] extranonce.subscribe response received
[2025-12-09 17:24:25] Stratum difficulty set to 0.0912865
```

**Expected After Implementation**:
```
[2025-12-09 18:00:30] Extranonce updated:  (size=4)
[2025-12-09 18:01:00] Extranonce updated:  (size=4)
```

### Testing Repository

**Repository**: https://github.com/frstrtr/cpuminer-multi  
**Branch**: `asicboost-protocol-testing`  
**Status**: ✅ Fully working with P2Pool

**What's Implemented**:
- ✅ Proper response ID matching (no false "ID mismatch" errors)
- ✅ Notification handling during response wait
- ✅ ASICBoost/BIP320 support with correct endianness
- ✅ **NiceHash extranonce protocol** (`mining.extranonce.subscribe`)
- ✅ 6-parameter submit format

**Protocol Used** (NiceHash - same as ASICs):
```c
// Sends: {"id": 3, "method": "mining.extranonce.subscribe", "params": []}
// Expects: {"id": 3, "result": true, "error": null}
// Handles: {"id": null, "method": "mining.set_extranonce", "params": ["", 4]}
```

**Testing Both Protocols**:
- cpuminer-multi uses NiceHash protocol (tests ASIC compatibility)
- For BIP310 testing, you'll need a modern GPU miner that uses `mining.configure`
- Both should work with same P2Pool implementation (same internal logic)

**Use this miner to validate your P2Pool implementation!**

## Implementation Priority

### Phase 1: Core Support (Required - 1 hour)
1. ✅ **Add state tracking in `__init__()`** - **5 minutes**
2. ✅ **Implement `rpc_extranonce_subscribe()` method** (NiceHash protocol) - **15 minutes**
3. ✅ **Update `rpc_configure()` method** (BIP310 protocol) - **10 minutes**
4. ✅ **Implement `rpc_set_extranonce()` notification handler** - **20 minutes**

**Estimated Time**: 50 minutes  
**Result**: ✅ ASICs can connect, ✅ Modern miners supported, ⚠️ But no notifications yet

### Phase 2: Notifications (Required - 30 minutes)
5. ✅ **Add helper method `_notify_extranonce_change()`** - **10 minutes**
6. ✅ **Implement periodic updates in `_send_work()`** - **20 minutes**

**Estimated Time**: 30 minutes  
**Result**: ✅ Full ASIC support, ✅ Prevents nonce space exhaustion

### Total Required Time: 1 hour 20 minutes

**Compatibility After Implementation**:
- ✅ Antminer D3 (NiceHash protocol)
- ✅ Innosilicon A5 (NiceHash protocol)
- ✅ Baikal BK-X (NiceHash protocol)
- ✅ Modern CPU miners (BIP310 protocol)
- ✅ Modern GPU miners (BIP310 protocol)

### Low Priority (Enhancement)
7. ⬜ Implement non-empty extranonce1 (currently always empty)
8. ⬜ Dynamic extranonce1 based on worker count
9. ⬜ Extranonce space management

**Estimated Time**: 2-4 hours (optional)

## Code Changes Summary

### Core Implementation (5 locations - all required)

1. **`__init__` method** - Add extranonce state tracking:
   ```python
   self.extranonce_subscribe = False
   self.extranonce1 = ""
   self.last_extranonce_update = 0
   ```

2. **New method** - Handle NiceHash subscription (for ASICs):
   ```python
   def rpc_extranonce_subscribe(self):
       self.extranonce_subscribe = True
       print '>>>ExtranOnce subscribed (NiceHash) from %s' % (self.worker_ip)
       return True
   ```

3. **`rpc_configure` method** - Handle BIP310 subscription (for modern miners):
   ```python
   if 'subscribe-extranonce' in extensions:
       self.extranonce_subscribe = True
       print '>>>ExtranOnce subscribed (BIP310) from %s' % (self.worker_ip)
       result['subscribe-extranonce'] = True
   ```

4. **New method** - Handle set_extranonce notifications:
   ```python
   def rpc_set_extranonce(self, extranonce1, extranonce2_size):
       # Implementation above (detailed in section 3)
   ```

5. **`_send_work` method** - Periodic updates:
   ```python
   if hasattr(self, 'extranonce_subscribe') and self.extranonce_subscribe:
       # Send periodic updates (detailed in section 5)
   ```

### Optional Helper (recommended)

6. **New helper method** - Notification sender:
   ```python
   def _notify_extranonce_change(self, new_extranonce1=None):
       # Implementation above (detailed in section 4)
   ```

## References

- **NiceHash Extranonce Subscribe**: https://github.com/nicehash/Specifications/blob/master/NiceHash_extranonce_subscribe_extension.txt
- **Stratum Extensions**: https://en.bitcoin.it/wiki/Stratum_mining_protocol#mining.extranonce.subscribe
- **BIP310 (Stratum v2)**: https://github.com/bitcoin/bips/blob/master/bip-0310.mediawiki
- **cpuminer-multi implementation**: `util.c:2299`, `stratum_parse_extranonce()`
- **Antminer Documentation**: Requires `mining.set_extranonce` for proper operation

## Expected Benefits

### For Miners
- ✅ ASIC support - Antminer D3, Innosilicon A5, Baikal can connect
- ✅ Stable hashrate - No nonce space exhaustion
- ✅ Better compatibility - Works with more mining software

### For P2Pool
- ✅ Increased hashrate - ASICs can contribute
- ✅ Network security - More diverse miner base
- ✅ Competitiveness - Feature parity with other pools

### For Network
- ✅ Decentralization - ASICs can use P2Pool instead of centralized pools
- ✅ Resilience - More hashrate on decentralized infrastructure

## Critical Compatibility Notes

### NiceHash Protocol vs BIP310

**IMPLEMENT BOTH** for maximum compatibility!

| Protocol | Method | When | Used By |
|----------|--------|------|---------|
| **NiceHash** | `mining.extranonce.subscribe` | Separate request after `mining.subscribe` | ✅ ASICs (Antminer, Innosilicon, Baikal) |
| **BIP310** | `subscribe-extranonce` in `mining.configure` | During configuration | ✅ Modern CPU/GPU miners |

**Good News**: Both protocols use the same:
- Internal state flag: `self.extranonce_subscribe`
- Notification method: `mining.set_extranonce`
- No conflict - miners use one OR the other, never both

**Implementation Strategy**:
1. Add `rpc_extranonce_subscribe()` for NiceHash protocol → ASICs work
2. Update `rpc_configure()` to handle `subscribe-extranonce` → Modern miners work
3. Both set `self.extranonce_subscribe = True` → Same notification logic for both

### Connection Sequence

**NiceHash Protocol (ASICs)**:
```
1. Miner → Pool: mining.subscribe
2. Pool → Miner: response with extranonce1/extranonce2_size
3. Miner → Pool: mining.extranonce.subscribe  ← SEPARATE REQUEST
4. Pool → Miner: {"result": true}              ← MUST RESPOND
5. Miner → Pool: mining.authorize
6. Pool → Miner: response
7. Pool → Miner: mining.set_extranonce (periodic) ← NOTIFICATIONS
```

**BIP310 Protocol (Modern miners)**:
```
1. Miner → Pool: mining.subscribe
2. Pool → Miner: response
3. Miner → Pool: mining.configure with ["subscribe-extranonce"]
4. Pool → Miner: {"result": {"subscribe-extranonce": true}}
5. Miner → Pool: mining.authorize
```

## Important Note for Other Miners

### Most Miners Have the Same Bug!

Many miners (including older versions of cpuminer-multi) incorrectly handle stratum responses:

**Buggy Pattern**:
```c
// WRONG - assumes next message matches request ID
send_request(id=2, "mining.configure");
response = read_one_line();
if (response.id != 2)
    error("ID mismatch!");  // FALSE ALARM if got mining.notify!
```

**Correct Pattern** (implemented in our cpuminer-multi):
```c
// RIGHT - keeps reading until finding matching response
send_request(id=2, "mining.configure");
while (!timeout) {
    msg = read_one_line();
    
    if (has_method(msg)) {
        // Unsolicited notification - handle and continue
        handle_notification(msg);  // mining.notify, set_difficulty, etc.
        continue;
    }
    
    if (is_response(msg) && msg.id == 2) {
        return msg;  // Found our response!
    }
}
```

### Protocol Reality

The stratum protocol **allows unsolicited notifications at ANY time**:
- `mining.notify` - New work (random ID)
- `mining.set_difficulty` - Difficulty change (random ID)
- `mining.set_extranonce` - Extranonce update (random ID)

These can arrive **while waiting for response to mining.configure**!

### Testing Tool

Use our fixed cpuminer-multi to validate your pool:
- **Repository**: https://github.com/frstrtr/cpuminer-multi
- **Branch**: `asicboost-protocol-testing`
- **Features**: Proper ID matching, ASICBoost, extranonce support

## Conclusion

Implementing `mining.set_extranonce` support is **critical** for P2Pool to support ASIC miners. The implementation is straightforward (1-2 hours of work) and provides significant value.

**Without this feature**: P2Pool is limited to CPU/GPU miners only  
**With this feature**: P2Pool becomes viable for all X11 miners including ASICs

The code changes are minimal, well-documented above, and can be tested incrementally with the **fixed cpuminer-multi** from this repository before ASIC testing.

### Validation Strategy

1. **Phase 1**: Test with our cpuminer-multi (has proper response handling)
2. **Phase 2**: Test with other CPU miners (may need fixes)
3. **Phase 3**: Test with ASICs (requires set_extranonce notifications)

---

**Document Status**: Ready for Implementation  
**Estimated Implementation Time**: 1-2 hours  
**Testing Time**: 1-2 hours  
**Priority**: HIGH - Blocking ASIC support  
**Testing Tool**: https://github.com/frstrtr/cpuminer-multi (branch: asicboost-protocol-testing)
