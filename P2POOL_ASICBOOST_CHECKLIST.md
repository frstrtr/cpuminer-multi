# P2Pool ASICBoost Implementation Testing Checklist

## Current Status

✅ **cpuminer-multi** - BIP320 version-rolling protocol implemented and tested  
⚠️ **P2Pool** - ASICBoost implemented but not responding to `mining.configure`

## Issue Observed

When cpuminer connects to P2Pool (192.168.86.244:7903):
- ❌ P2Pool doesn't respond properly to `mining.configure` request
- ❌ Miner logs: "Stratum answer id is not correct!"
- ⚠️ Miner falls back to standard mining (no version-rolling)

---

## Testing Tasks for P2Pool Developers

### 1. Protocol Negotiation (`mining.configure`)

#### What to Check:
```python
# In p2pool/dash/stratum.py or similar

# Does your code handle this method?
def handle_mining_configure(self, id, params):
    # Should parse: [["version-rolling"], {"version-rolling.mask": "1fffe000", ...}]
    pass
```

#### Expected Behavior:
1. **Receive from miner:**
   ```json
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
   ```

2. **Pool should respond:**
   ```json
   {
     "id": 2,
     "result": {
       "version-rolling": true,
       "version-rolling.mask": "1fffe000"
     },
     "error": null
   }
   ```

3. **OR if not supported:**
   ```json
   {
     "id": 2,
     "result": null,
     "error": [20, "Not supported", null]
   }
   ```

#### Test This:
```bash
# On P2Pool machine, monitor stratum traffic
tail -f ~/p2pool-dash/data/dash/log | grep -i configure

# Look for:
# - Incoming mining.configure requests
# - Outgoing responses
# - Any errors or exceptions
```

---

### 2. Response ID Matching

#### Bug to Check:
The error "Stratum answer id is not correct!" suggests:
- Pool may be sending wrong `id` in response
- Pool may be sending response before it's ready
- Pool may be sending malformed JSON

#### What to Verify:
```python
# Response MUST have same ID as request
request_id = parsed_request['id']  # e.g., 2
response = {
    "id": request_id,  # ← MUST MATCH! Not 1, not 0, not null
    "result": {...},
    "error": null
}
```

#### Test Code Pattern:
```python
# Example fix in stratum handler
def handle_request(self, data):
    request = json.loads(data)
    method = request.get('method')
    req_id = request.get('id')  # Save this!
    
    if method == 'mining.configure':
        result = self.handle_configure(request['params'])
        response = {
            "id": req_id,  # Use saved ID, not hardcoded value
            "result": result,
            "error": None
        }
        self.send(json.dumps(response) + '\n')
```

---

### 3. Request Ordering

#### Timing Issue to Check:
The protocol flow should be:
```
1. Miner → Pool: mining.subscribe
2. Pool → Miner: [session_id, extranonce1, extranonce2_size]
3. Miner → Pool: mining.configure  ← Happens IMMEDIATELY after
4. Pool → Miner: {version-rolling: true/false}
5. Miner → Pool: mining.authorize
```

#### Potential Bug:
- Pool might not be ready to handle `mining.configure` immediately after `subscribe`
- Pool might be processing requests out of order
- Pool might be buffering responses incorrectly

#### Test This:
```python
# Add logging to see request order
import logging
logger = logging.getLogger('stratum')

def handle_message(self, message):
    request = json.loads(message)
    method = request.get('method')
    req_id = request.get('id')
    
    logger.info(f"RX: id={req_id} method={method}")
    # ... process request ...
    logger.info(f"TX: id={req_id} response sent")
```

---

### 4. Version Bits in Submit

#### What to Check:
Does P2Pool handle the 6-parameter submit format?

**Standard submit (5 params):**
```json
{
  "method": "mining.submit",
  "params": ["worker", "job_id", "xnonce2", "ntime", "nonce"]
}
```

**Version-rolling submit (6 params):**
```json
{
  "method": "mining.submit",
  "params": ["worker", "job_id", "xnonce2", "ntime", "nonce", "00004000"]
}
```

#### Test Code:
```python
def handle_mining_submit(self, id, params):
    worker = params[0]
    job_id = params[1]
    xnonce2 = params[2]
    ntime = params[3]
    nonce = params[4]
    version_bits = params[5] if len(params) > 5 else None  # NEW
    
    if version_bits:
        # Reconstruct block header with version bits
        version = self.reconstruct_version(job_id, version_bits)
    else:
        # Standard version from job
        version = self.get_job_version(job_id)
```

---

### 5. Block Header Reconstruction

#### Critical Bug Area:
When version_bits is provided, pool must correctly reconstruct the block version:

```python
def reconstruct_version(self, job_id, version_bits_hex):
    """
    Reconstruct block version from version_bits parameter.
    
    Args:
        job_id: The job identifier
        version_bits_hex: Hex string like "00004000"
    
    Returns:
        Full block version as uint32
    """
    # Get base version from job
    job = self.get_job(job_id)
    base_version = job['version']  # e.g., 0x20000000
    
    # Parse version_bits
    version_bits = int(version_bits_hex, 16)  # e.g., 0x00004000
    
    # Get mask (negotiated in mining.configure)
    mask = self.version_mask  # e.g., 0x1fffe000
    
    # Reconstruct: (base & ~mask) | (bits & mask)
    reconstructed = (base_version & ~mask) | (version_bits & mask)
    
    return reconstructed
```

#### Test This:
```python
# Unit test
def test_version_reconstruction():
    base_version = 0x20000000
    version_bits = 0x00004000
    mask = 0x1fffe000
    
    result = (base_version & ~mask) | (version_bits & mask)
    expected = 0x20004000
    
    assert result == expected, f"Got {hex(result)}, expected {hex(expected)}"
```

---

### 6. Share Validation

#### What to Check:
When validating shares with version-rolling:

```python
def validate_share(self, worker, job_id, xnonce2, ntime, nonce, version_bits=None):
    """Validate miner's share submission."""
    
    # 1. Reconstruct block header
    if version_bits:
        version = self.reconstruct_version(job_id, version_bits)
    else:
        version = self.get_job_version(job_id)
    
    # 2. Build full block header
    header = self.build_header(
        version=version,
        prev_hash=job['prev_hash'],
        merkle_root=self.calculate_merkle_root(job, xnonce2),
        ntime=ntime,
        nbits=job['nbits'],
        nonce=nonce
    )
    
    # 3. Hash and check difficulty
    block_hash = hash_header(header)
    
    if not meets_difficulty(block_hash, job['difficulty']):
        return False, "low difficulty share"
    
    return True, None
```

#### Test Cases:
- [ ] Share without version_bits (backward compatibility)
- [ ] Share with version_bits = 0x00000000
- [ ] Share with version_bits = 0x00004000
- [ ] Share with version_bits = 0x1fffe000 (max allowed)
- [ ] Share with invalid version_bits (should reject)

---

### 7. Mask Validation

#### Security Check:
Ensure miners can't manipulate non-allowed bits:

```python
def validate_version_bits(self, version_bits_hex):
    """Ensure version_bits only uses allowed mask."""
    version_bits = int(version_bits_hex, 16)
    
    # Check if any bits outside mask are set
    if version_bits & ~self.version_mask != 0:
        raise ValueError(f"Invalid version_bits: {version_bits_hex} exceeds mask")
    
    return version_bits
```

#### Test This:
```python
# Should accept
validate_version_bits("00004000")  # Within mask
validate_version_bits("1fffe000")  # Full mask

# Should reject
validate_version_bits("20000000")  # Outside mask (version bit)
validate_version_bits("e0000000")  # Outside mask (high bits)
```

---

### 8. Logging and Debugging

#### Add Comprehensive Logging:
```python
import logging
logger = logging.getLogger('stratum.asicboost')

class StratumServer:
    def handle_mining_configure(self, id, params):
        logger.info(f"Received mining.configure from {self.client_ip}")
        logger.debug(f"  params: {params}")
        
        # Process version-rolling
        if "version-rolling" in params[0]:
            mask = params[1].get("version-rolling.mask", "1fffe000")
            logger.info(f"  Negotiating version-rolling with mask={mask}")
            
            self.version_rolling = True
            self.version_mask = int(mask, 16)
            
            response = {
                "id": id,
                "result": {
                    "version-rolling": True,
                    "version-rolling.mask": mask
                },
                "error": None
            }
            logger.info(f"  Enabled version-rolling for {self.client_ip}")
        else:
            response = {"id": id, "result": {}, "error": None}
        
        return response
    
    def handle_mining_submit(self, id, params):
        if len(params) > 5:
            version_bits = params[5]
            logger.debug(f"Submit with version_bits={version_bits}")
        else:
            logger.debug(f"Submit without version_bits (standard)")
```

---

### 9. Network Capture Testing

#### Capture Actual Traffic:
```bash
# On P2Pool machine
sudo tcpdump -i any -A 'host 192.168.86.245 and port 7903' > stratum_traffic.log

# Let it run for 30 seconds while miner connects
# Then analyze:
grep -A 5 "mining.configure" stratum_traffic.log
grep -A 5 "mining.submit" stratum_traffic.log
```

#### What to Look For:
- ✅ mining.configure request present
- ✅ Response with matching id
- ✅ version-rolling in response
- ✅ mining.submit with 6 parameters
- ❌ Malformed JSON
- ❌ Missing newlines (\n)
- ❌ Wrong IDs

---

### 10. Integration Test Script

#### Test P2Pool Manually:
```python
#!/usr/bin/env python3
"""Test P2Pool ASICBoost protocol."""

import socket
import json
import time

def test_asicboost_protocol(host='192.168.86.244', port=7903):
    """Simulate cpuminer connecting to P2Pool."""
    
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.connect((host, port))
    
    def send(msg):
        data = json.dumps(msg) + '\n'
        print(f"TX: {data.strip()}")
        sock.send(data.encode())
    
    def recv():
        data = sock.recv(4096).decode().strip()
        print(f"RX: {data}")
        return json.loads(data) if data else None
    
    # 1. Subscribe
    send({
        "id": 1,
        "method": "mining.subscribe",
        "params": ["cpuminer-test"]
    })
    resp = recv()
    print(f"Subscribe response: {resp}\n")
    
    # 2. Configure (ASICBoost)
    send({
        "id": 2,
        "method": "mining.configure",
        "params": [
            ["version-rolling"],
            {"version-rolling.mask": "1fffe000", "version-rolling.min-bit-count": 2}
        ]
    })
    resp = recv()
    print(f"Configure response: {resp}\n")
    
    # Check response
    if resp and resp.get('id') == 2:
        result = resp.get('result', {})
        if result.get('version-rolling'):
            print("✅ ASICBoost version-rolling ENABLED")
            print(f"   Mask: {result.get('version-rolling.mask')}")
        else:
            print("⚠️  Version-rolling not supported by pool")
    else:
        print(f"❌ ERROR: Invalid response or wrong ID")
        print(f"   Expected id=2, got id={resp.get('id') if resp else 'null'}")
    
    # 3. Authorize
    send({
        "id": 3,
        "method": "mining.authorize",
        "params": ["XsFe6mGpLM3R6ZieYJXhsmGyYg8jn3Lth6", "x"]
    })
    resp = recv()
    print(f"Authorize response: {resp}\n")
    
    sock.close()

if __name__ == '__main__':
    test_asicboost_protocol()
```

**Run this:**
```bash
python3 test_asicboost.py
```

---

## Expected Test Results

### ✅ Success Indicators:
- `mining.configure` request logged by P2Pool
- Response with matching ID (id=2)
- Response contains `"version-rolling": true`
- Response contains mask `"1fffe000"`
- Miner logs: "✓ ASICBoost version-rolling enabled: mask=0x1fffe000"
- Shares accepted with 6 parameters

### ❌ Current Failure:
- "Stratum answer id is not correct!" in miner log
- No ASICBoost message in miner log
- Miner falls back to standard mode

---

## Quick Debug Commands

```bash
# On P2Pool machine (192.168.86.244)

# 1. Check if stratum is listening
netstat -tlnp | grep 7903

# 2. Monitor P2Pool logs
tail -f ~/p2pool-dash/data/dash/log | grep -i "configure\|version\|245"

# 3. Capture stratum traffic
sudo tcpdump -i any -A 'port 7903' | tee stratum_capture.log

# 4. Check P2Pool Python process
ps aux | grep p2pool

# 5. Check for Python errors
tail -100 ~/p2pool-dash/data/dash/log | grep -i "error\|exception\|traceback"
```

```bash
# On miner machine (192.168.86.245)

# 1. Check miner status
ps aux | grep cpuminer

# 2. Monitor miner logs
tail -f ~/cpuminer-multi/miner.log | grep -i "asicboost\|configure\|version"

# 3. Restart miner with debug
pkill cpuminer
cd ~/cpuminer-multi
./cpuminer -a x11 -o stratum+tcp://192.168.86.244:7903 \
  -u XsFe6mGpLM3R6ZieYJXhsmGyYg8jn3Lth6 -p x -D 2>&1 | tee debug.log
```

---

## Common Bugs to Check

### Bug #1: Wrong Response ID
```python
# ❌ WRONG - Hardcoded ID
response = {"id": 1, "result": {...}}

# ✅ CORRECT - Use request ID
response = {"id": request['id'], "result": {...}}
```

### Bug #2: Not Handling mining.configure
```python
# ❌ WRONG - Method not recognized
if method == 'subscribe':
    ...
elif method == 'authorize':
    ...
# mining.configure falls through, no response sent

# ✅ CORRECT - Handle all methods
elif method == 'mining.configure':
    return self.handle_configure(id, params)
```

### Bug #3: Mask Parsing Error
```python
# ❌ WRONG - Treating as int instead of hex string
mask = params[1]['version-rolling.mask']  # "1fffe000"
self.mask = mask  # String!

# ✅ CORRECT - Parse hex
mask_str = params[1]['version-rolling.mask']
self.mask = int(mask_str, 16)  # 0x1fffe000
```

### Bug #4: Missing Newline in Response
```python
# ❌ WRONG - No newline
sock.send(json.dumps(response))

# ✅ CORRECT - Add newline
sock.send(json.dumps(response) + '\n')
```

### Bug #5: Not Checking Params Length
```python
# ❌ WRONG - Assumes 6 params always
version_bits = params[5]  # IndexError if only 5 params!

# ✅ CORRECT - Check length
version_bits = params[5] if len(params) > 5 else None
```

---

## Testing Checklist

- [ ] P2Pool receives `mining.configure` request
- [ ] P2Pool logs show configure handling
- [ ] P2Pool sends response with correct ID
- [ ] Response includes `version-rolling` in result
- [ ] Response includes correct `mask` value
- [ ] Miner logs show "✓ ASICBoost version-rolling enabled"
- [ ] Miner submits shares with 6 parameters
- [ ] P2Pool accepts shares with version_bits
- [ ] P2Pool correctly reconstructs block version
- [ ] Share validation works with version-rolling
- [ ] Backward compatibility: accepts 5-param submits
- [ ] No crashes or exceptions in P2Pool logs

---

## Contact

Once you fix the issues, test with:
```bash
# On miner machine
ssh user0@192.168.86.245
cd ~/cpuminer-multi
pkill cpuminer
./cpuminer -a x11 -o stratum+tcp://192.168.86.244:7903 \
  -u XsFe6mGpLM3R6ZieYJXhsmGyYg8jn3Lth6 -p x -D
```

Look for: **"✓ ASICBoost version-rolling enabled: mask=0x1fffe000"**

That message means everything is working! 🎉
