# ASICBoost Implementation - Code Changes

## Summary
This document shows the exact code changes made to implement BIP320 version-rolling support in cpuminer-multi.

---

## File 1: miner.h

### Change 1: Add version-rolling fields to struct stratum_ctx

**Location:** Lines 436-465  
**Type:** Structure field additions

```diff
 struct stratum_ctx {
 	char *url;
 
 	CURL *curl;
 	char *curl_url;
 	char curl_err_str[CURL_ERROR_SIZE];
 	curl_socket_t sock;
 	size_t sockbuf_size;
 	char *sockbuf;
 	pthread_mutex_t sock_lock;
 
 	double next_diff;
 	double sharediff;
 
 	char *session_id;
 	size_t xnonce1_size;
 	unsigned char *xnonce1;
 	size_t xnonce2_size;
 	struct stratum_job job;
 	struct work work;
 	pthread_mutex_t work_lock;
 
 	int bloc_height;
+
+	// ASICBoost / Version Rolling (BIP320)
+	bool version_rolling;      // Is version-rolling enabled?
+	uint32_t version_mask;     // Mask from pool (e.g., 0x1fffe000)
+	uint32_t version_counter;  // Counter for version bits
+	int next_id;               // ID counter for JSON-RPC requests
 };
```

### Change 2: Add stratum_configure function declaration

**Location:** Lines 458-468  
**Type:** Function declaration

```diff
 bool stratum_socket_full(struct stratum_ctx *sctx, int timeout);
 bool stratum_send_line(struct stratum_ctx *sctx, char *s);
 char *stratum_recv_line(struct stratum_ctx *sctx);
 bool stratum_connect(struct stratum_ctx *sctx, const char *url);
 void stratum_disconnect(struct stratum_ctx *sctx);
 bool stratum_subscribe(struct stratum_ctx *sctx);
+bool stratum_configure(struct stratum_ctx *sctx);
 bool stratum_authorize(struct stratum_ctx *sctx, const char *user, const char *pass);
 bool stratum_handle_method(struct stratum_ctx *sctx, const char *s);
```

---

## File 2: util.c

### Change 1: Implement stratum_configure function

**Location:** After line 1360 (after stratum_subscribe function)  
**Type:** New function implementation

```diff
 	return ret;
 }
 
+bool stratum_configure(struct stratum_ctx *sctx)
+{
+	char *s, *sret = NULL;
+	json_t *val = NULL;
+	json_error_t err;
+	bool ret = false;
+
+	if (jsonrpc_2)
+		return true;
+
+	// Initialize next_id if not set
+	if (sctx->next_id == 0)
+		sctx->next_id = 2;
+
+	// Request version-rolling with 0x1fffe000 mask (13 bits)
+	s = (char*) malloc(512);
+	sprintf(s,
+		"{\"id\": %d, \"method\": \"mining.configure\", \"params\": "
+		"[[\"version-rolling\"], "
+		"{\"version-rolling.mask\": \"1fffe000\", "
+		"\"version-rolling.min-bit-count\": 2}]}",
+		sctx->next_id++);
+
+	if (!stratum_send_line(sctx, s)) {
+		applog(LOG_DEBUG, "Failed to send mining.configure");
+		ret = true; // Not fatal, continue without version-rolling
+		goto out;
+	}
+
+	// Wait for response
+	if (!socket_full(sctx->sock, 10)) {
+		applog(LOG_DEBUG, "mining.configure timeout (pool may not support it)");
+		ret = true; // Not fatal
+		goto out;
+	}
+
+	sret = stratum_recv_line(sctx);
+	if (!sret) {
+		ret = true; // Not fatal
+		goto out;
+	}
+
+	val = JSON_LOADS(sret, &err);
+	if (!val) {
+		applog(LOG_DEBUG, "JSON decode failed for mining.configure response");
+		ret = true; // Not fatal
+		goto out;
+	}
+
+	json_t *result = json_object_get(val, "result");
+	json_t *error = json_object_get(val, "error");
+
+	// Check if there's an error response
+	if (error && !json_is_null(error)) {
+		if (opt_debug)
+			applog(LOG_DEBUG, "Pool does not support mining.configure");
+		sctx->version_rolling = false;
+		ret = true;
+		goto out;
+	}
+
+	if (result && json_is_object(result)) {
+		json_t *vr = json_object_get(result, "version-rolling");
+		json_t *mask = json_object_get(result, "version-rolling.mask");
+		
+		if (json_is_true(vr) && mask) {
+			const char *mask_str = json_string_value(mask);
+			if (mask_str) {
+				sctx->version_rolling = true;
+				sctx->version_mask = strtoul(mask_str, NULL, 16);
+				sctx->version_counter = 0;
+				applog(LOG_INFO, "✓ ASICBoost version-rolling enabled: mask=0x%08x", sctx->version_mask);
+			} else {
+				sctx->version_rolling = false;
+			}
+			ret = true;
+		} else {
+			if (opt_debug)
+				applog(LOG_DEBUG, "Pool does not support version-rolling");
+			sctx->version_rolling = false;
+			ret = true;
+		}
+	} else {
+		sctx->version_rolling = false;
+		ret = true;
+	}
+
+out:
+	free(s);
+	if (sret)
+		free(sret);
+	if (val)
+		json_decref(val);
+
+	return ret;
+}
+
 extern bool opt_extranonce;
```

### Change 2: Call stratum_configure after subscribe

**Location:** In stratum_authorize function, after line 1376  
**Type:** Function call addition

```diff
 bool stratum_authorize(struct stratum_ctx *sctx, const char *user, const char *pass)
 {
 	json_t *val = NULL, *res_val, *err_val;
 	char *s, *sret;
 	json_error_t err;
 	bool ret = false;
 	int req_id = 0;
 
+	// Try to negotiate version-rolling after successful subscribe
+	if (!jsonrpc_2) {
+		stratum_configure(sctx);
+	}
+
 	if (jsonrpc_2) {
 		s = (char*) malloc(300 + strlen(user) + strlen(pass));
 		sprintf(s, "{\"method\": \"login\", \"params\": {"
 			"\"login\": \"%s\", \"pass\": \"%s\", \"agent\": \"%s\"}, \"id\": 1}",
 			user, pass, USER_AGENT);
```

---

## File 3: cpu-miner.c

### Change 1: Apply version bits in stratum_gen_work

**Location:** In stratum_gen_work function, around line 1830  
**Type:** Logic addition

```diff
 		} else {
 			work->data[17] = le32dec(sctx->job.ntime);
 			work->data[18] = le32dec(sctx->job.nbits);
 			// required ?
 			work->data[20] = 0x80000000;
 			work->data[31] = 0x00000280;
 		}
 
+		// Apply version bits if version-rolling is enabled (ASICBoost/BIP320)
+		if (sctx->version_rolling && sctx->version_mask) {
+			// Use counter to vary version bits across different work units
+			uint32_t version_bits = ((sctx->version_counter++ & 0x1fff) << 13);
+			uint32_t current_version = work->data[0];
+			work->data[0] = (current_version & ~sctx->version_mask) | 
+			                (version_bits & sctx->version_mask);
+			if (opt_debug && (sctx->version_counter & 0xFF) == 1) {
+				applog(LOG_DEBUG, "Version rolling: 0x%08x -> 0x%08x (mask=0x%08x)",
+					current_version, work->data[0], sctx->version_mask);
+			}
+		}
+
 		if (opt_showdiff || opt_max_diff > 0.)
 			calc_network_diff(work);
```

### Change 2: Include version_bits in submit

**Location:** In submit_upstream_work function, around line 1206  
**Type:** Conditional logic modification

```diff
 			bin2hex(ntimestr, (const unsigned char *)(&ntime), 4);
 			bin2hex(noncestr, (const unsigned char *)(&nonce), 4);
 			if (opt_algo == ALGO_DECRED) {
 				xnonce2str = abin2hex((unsigned char*)(&work->data[36]), stratum.xnonce1_size);
 			} else if (opt_algo == ALGO_SIA) {
 				uint16_t high_nonce = swab32(work->data[9]) >> 16;
 				xnonce2str = abin2hex((unsigned char*)(&high_nonce), 2);
 			} else {
 				xnonce2str = abin2hex(work->xnonce2, work->xnonce2_len);
 			}
-			snprintf(s, JSON_BUF_LEN,
-					"{\"method\": \"mining.submit\", \"params\": [\"%s\", \"%s\", \"%s\", \"%s\", \"%s\"], \"id\":4}",
-					rpc_user, work->job_id, xnonce2str, ntimestr, noncestr);
+			
+			// Include version_bits parameter if version-rolling is enabled (BIP320)
+			if (stratum.version_rolling && stratum.version_mask) {
+				uint32_t nversion = work->data[0];
+				// Extract version bits that were applied
+				uint32_t version_bits = nversion & stratum.version_mask;
+				
+				snprintf(s, JSON_BUF_LEN,
+						"{\"method\": \"mining.submit\", \"params\": [\"%s\", \"%s\", \"%s\", \"%s\", \"%s\", \"%08x\"], \"id\":4}",
+						rpc_user, work->job_id, xnonce2str, ntimestr, noncestr, version_bits);
+				
+				if (opt_debug)
+					applog(LOG_DEBUG, "Submit with version_bits: 0x%08x", version_bits);
+			} else {
+				snprintf(s, JSON_BUF_LEN,
+						"{\"method\": \"mining.submit\", \"params\": [\"%s\", \"%s\", \"%s\", \"%s\", \"%s\"], \"id\":4}",
+						rpc_user, work->job_id, xnonce2str, ntimestr, noncestr);
+			}
 			free(xnonce2str);
```

---

## Documentation Files Created

### 1. ASICBOOST_TESTING.md
- Comprehensive testing guide
- Protocol overview and examples
- Troubleshooting section
- Verification checklist

### 2. test_asicboost.sh
- Automated test script
- Quick connectivity verification
- Result interpretation guide

### 3. IMPLEMENTATION_SUMMARY.md
- Complete implementation overview
- Technical details and notes
- Testing instructions
- Compatibility information

---

## Statistics

- **Files Modified:** 3 (miner.h, util.c, cpu-miner.c)
- **Files Created:** 3 (ASICBOOST_TESTING.md, test_asicboost.sh, IMPLEMENTATION_SUMMARY.md)
- **Lines Added:** ~200
- **New Functions:** 1 (stratum_configure)
- **Modified Functions:** 3 (stratum_authorize, stratum_gen_work, submit_upstream_work)
- **New Struct Fields:** 4 (version_rolling, version_mask, version_counter, next_id)

---

## Build and Test

```bash
# Build
cd /home/user0/Github/cpuminer-multi
./build.sh

# Quick test
./test_asicboost.sh

# Full test
./cpuminer -a x11 \
  -o stratum+tcp://192.168.86.244:7903 \
  -u XsFe6mGpLM3R6ZieYJXhsmGyYg8jn3Lth6 \
  -p x \
  -D
```

---

## Verification

✅ **Compilation:** Clean build with no errors  
✅ **Backward Compatibility:** Works with standard pools  
✅ **Protocol Compliance:** Follows BIP320 specification  
✅ **Error Handling:** Graceful fallback on unsupported pools  
✅ **Debug Support:** Verbose logging with -D flag  

---

**Implementation Complete:** December 9, 2025
