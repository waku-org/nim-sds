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
// Keep const char* here as these are inputs *to* the callback
typedef void (*MessageReadyCallback)(const char* messageID);
typedef void (*MessageSentCallback)(const char* messageID);
typedef void (*MissingDependenciesCallback)(const char* messageID, const char** missingDeps, size_t missingDepsCount);
typedef void (*PeriodicSyncCallback)(void* user_data);


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
CResult MarkDependenciesMet(void* handle, char*** messageIDs, size_t count);

/**
 * @brief Registers callback functions.
 * @param handle The opaque handle (void*) of the instance.
 * @param messageReady Callback for when a message is ready.
 * @param messageSent Callback for when an outgoing message is acknowledged.
 * @param missingDependencies Callback for when missing dependencies are detected.
 * @param periodicSync Callback for periodic sync suggestions.
 * @param user_data A pointer to user-defined data passed to callbacks.
 */
void RegisterCallbacks(void* handle,
                       void* messageReady,
                       void* messageSent,
                       void* missingDependencies,
                       void* periodicSync,
                       void* user_data); // Keep user_data, align with Nim proc

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
