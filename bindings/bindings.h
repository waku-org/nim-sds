#ifndef BINDINGS_H
#define BINDINGS_H

#include <stddef.h> // For size_t
#include <stdint.h> // For standard integer types
#include <stdbool.h> // For bool type

#ifdef __cplusplus
extern "C" {
#endif


// Opaque struct declaration (handle replaces direct pointer usage)
typedef struct ReliabilityManager ReliabilityManager; // Keep forward declaration

// Define MessageID as a C string
typedef const char* MessageID; // Keep const for the typedef itself

// --- Result Types ---

typedef struct {
    bool is_ok;
    char* error_message;
} CResult;

typedef struct {
    CResult base_result;
    unsigned char* message;
    size_t message_len;
    MessageID* missing_deps;
    size_t missing_deps_count;
} CUnwrapResult;

typedef struct {
    CResult base_result;
    unsigned char* message;
    size_t message_len;
} CWrapResult;


// --- Callback Function Pointer Types ---

// Define event types (enum or constants)
typedef enum {
    EVENT_MESSAGE_READY = 1,
    EVENT_MESSAGE_SENT = 2,
    EVENT_MISSING_DEPENDENCIES = 3,
    EVENT_PERIODIC_SYNC = 4
} CEventType;

// Single callback type for all events
// Nim will call this, passing the handle and event-specific data
typedef void (*CEventCallback)(void* handle, CEventType eventType, void* data1, void* data2, size_t data3);


// --- Core API Functions ---

/**
 * @brief Creates a new ReliabilityManager instance.
 * @param channelId A unique identifier for the communication channel.
 * @return An opaque handle (void*) representing the instance, or NULL on failure.
 */
void* NewReliabilityManager(char* channelId);

/**
 * @brief Cleans up resources associated with a ReliabilityManager instance.
 * @param handle The opaque handle (void*) of the instance to clean up.
 */
void CleanupReliabilityManager(void* handle);

/**
 * @brief Resets the ReliabilityManager instance.
 * @param handle The opaque handle (void*) of the instance.
 * @return CResult indicating success or failure.
 */
CResult ResetReliabilityManager(void* handle);
/**
 * @brief Wraps an outgoing message.
 * @param handle The opaque handle (void*) of the instance.
 * @param message Pointer to the raw message content.
 * @param messageLen Length of the raw message content.
 * @param messageId A unique identifier for this message.
 * @return CWrapResult containing the wrapped message or an error.
 */
CWrapResult WrapOutgoingMessage(void* handle, void* message, size_t messageLen, char* messageId);
/**
 * @brief Unwraps a received message.
 * @param handle The opaque handle (void*) of the instance.
 * @param message Pointer to the received message data.
 * @param messageLen Length of the received message data.
 * @return CUnwrapResult containing the unwrapped content, missing dependencies, or an error.
 */
CUnwrapResult UnwrapReceivedMessage(void* handle, void* message, size_t messageLen);

/**
 * @brief Marks specified message dependencies as met.
 * @param handle The opaque handle (void*) of the instance.
 * @param messageIDs An array of message IDs to mark as met.
 * @param count The number of message IDs in the array.
 * @return CResult indicating success or failure.
 */
CResult MarkDependenciesMet(void* handle, char** messageIDs, size_t count); // Reverted to char**

/**
 * @brief Registers callback functions.
 * @param handle The opaque handle (void*) of the instance.
 * @param messageReady Callback for when a message is ready.
 * @param messageSent Callback for when an outgoing message is acknowledged.
 * @param eventCallback The single callback function to handle all events.
 * @param user_data A pointer to user-defined data (optional, could be managed in Go).
 */
void RegisterCallback(void* handle, CEventCallback eventCallback, void* user_data); // Renamed and simplified

/**
 * @brief Starts the background periodic tasks.
 * @param handle The opaque handle (void*) of the instance.
 */
void StartPeriodicTasks(void* handle);


// --- Memory Freeing Functions ---

void FreeCResultError(CResult result);
void FreeCWrapResult(CWrapResult result);
void FreeCUnwrapResult(CUnwrapResult result);


#ifdef __cplusplus
} // extern "C"
#endif

#endif // BINDINGS_H
