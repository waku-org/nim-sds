
// C API for libsds, built on the nim-ffi 0.2 framework.
//
// Parameters and results are marshalled as CBOR (RFC 8949): each request and
// response struct in library/libsds.nim is a CBOR map keyed by the exact field
// names; binary fields (message bytes, retrieval hints) are CBOR byte strings.
// Requests are passed in as a length-delimited CBOR buffer (reqCbor/reqCborLen)
// and results are delivered to the callback as a CBOR buffer (msg/len).
#ifndef __libsds__
#define __libsds__

#include <stddef.h>
#include <stdint.h>

// The possible returned values for the functions that return int
#define RET_OK                0
#define RET_ERR               1
#define RET_MISSING_CALLBACK  2

#ifdef __cplusplus
extern "C" {
#endif

// Result/event callback. On RET_OK, `msg` points to the CBOR-encoded payload of
// length `len` (an empty/void result is the single CBOR-null byte 0xf6). On
// RET_ERR, `msg` is the raw UTF-8 error string (NOT CBOR).
typedef void (*SdsCallBack) (int callerRet, const char* msg, size_t len, void* userData);

// Synchronous provider invoked by SDS-R to fetch a retrieval hint for a
// message id. The implementation allocates `*hint` (and sets `*hintLen`) with
// libc malloc; the library takes ownership and frees it with libc free.
typedef void (*SdsRetrievalHintProvider) (const char* messageId, char** hint, size_t* hintLen, void* userData);


// --- Core API Functions ---


// Create a context + ReliabilityManager. reqCbor: CBOR of
// {"config":{"participantId":"..."}} (empty participantId disables SDS-R).
// Returns the context handle, or NULL on failure. The callback also fires on
// async completion.
void* sds_create(const uint8_t* reqCbor, size_t reqCborLen, SdsCallBack callback, void* userData);

// Register an event listener for `eventName` (message_ready, message_sent,
// missing_dependencies, periodic_sync, repair_ready). The callback receives a
// CBOR EventEnvelope {"eventType":"<name>","payload":{...}}. Returns a listener
// id (> 0) usable with sds_remove_event_listener, or 0 if the callback is NULL.
uint64_t sds_add_event_listener(void* ctx, const char* eventName, SdsCallBack callback, void* userData);

// Remove a previously registered event listener. Returns RET_OK on success.
int sds_remove_event_listener(void* ctx, uint64_t listenerId);

// Register the retrieval-hint provider used by SDS-R.
int sds_set_retrieval_hint_provider(void* ctx, SdsRetrievalHintProvider callback, void* userData);

// reqCbor: CBOR of {"req":{"message":<bytes>,"messageId":"..","channelId":".."}}
// Result CBOR: {"message":<bytes>}
int sds_wrap_outgoing_message(void* ctx, SdsCallBack callback, void* userData, const uint8_t* reqCbor, size_t reqCborLen);

// reqCbor: CBOR of {"req":{"message":<bytes>}}
// Result CBOR: {"message":<bytes>,"channelId":"..","missingDeps":[{"messageId":"..","retrievalHint":<bytes>}]}
int sds_unwrap_received_message(void* ctx, SdsCallBack callback, void* userData, const uint8_t* reqCbor, size_t reqCborLen);

// reqCbor: CBOR of {"req":{"messageIds":["..",".."],"channelId":".."}}
int sds_mark_dependencies_met(void* ctx, SdsCallBack callback, void* userData, const uint8_t* reqCbor, size_t reqCborLen);

// No request payload — pass reqCbor=NULL, reqCborLen=0.
int sds_reset(void* ctx, SdsCallBack callback, void* userData, const uint8_t* reqCbor, size_t reqCborLen);

// No request payload — pass reqCbor=NULL, reqCborLen=0.
int sds_start_periodic_tasks(void* ctx, SdsCallBack callback, void* userData, const uint8_t* reqCbor, size_t reqCborLen);

// Tear down the context created by sds_create.
int sds_destroy(void* ctx);


#ifdef __cplusplus
}
#endif

#endif /* __libsds__ */
