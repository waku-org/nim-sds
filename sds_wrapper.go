package main

/*
#cgo CFLAGS: -I${SRCDIR}/bindings
#cgo LDFLAGS: -L${SRCDIR}/bindings/generated -lbindings
#cgo LDFLAGS: -Wl,-rpath,${SRCDIR}/bindings/generated

#include <stdlib.h> // For C.free
#include "bindings/bindings.h" // Update include path

// Forward declarations for Go callback functions exported to C
// These are the functions Nim will eventually call via the pointers we give it.
extern void goMessageReadyCallback(char* messageID);
extern void goMessageSentCallback(char* messageID);
extern void goMissingDependenciesCallback(char* messageID, char** missingDeps, size_t missingDepsCount);
extern void goPeriodicSyncCallback();

// Helper function to call the C memory freeing functions
static void callFreeCResultError(CResult res) { FreeCResultError(res); }
static void callFreeCWrapResult(CWrapResult res) { FreeCWrapResult(res); }
static void callFreeCUnwrapResult(CUnwrapResult res) { FreeCUnwrapResult(res); }

*/
import "C"
import (
	"errors"
	"fmt"
	"sync"
	"unsafe"
)

// --- Go Types ---

// ReliabilityManagerHandle represents the opaque handle to the Nim object
type ReliabilityManagerHandle unsafe.Pointer

// MessageID is a type alias for string for clarity
type MessageID string

// Callbacks holds the Go functions to be called by the Nim library
type Callbacks struct {
	OnMessageReady        func(messageId MessageID)
	OnMessageSent         func(messageId MessageID)
	OnMissingDependencies func(messageId MessageID, missingDeps []MessageID)
	OnPeriodicSync        func()
}

// Global map to store callbacks associated with handles (necessary due to cgo limitations)
var (
	callbackRegistry = make(map[ReliabilityManagerHandle]*Callbacks)
	registryMutex    sync.RWMutex
)

// --- Go Wrapper Functions ---

// NewReliabilityManager creates a new instance of the Nim ReliabilityManager
func NewReliabilityManager(channelId string) (ReliabilityManagerHandle, error) {
	cChannelId := C.CString(channelId)
	defer C.free(unsafe.Pointer(cChannelId))

	handle := C.NewReliabilityManager(cChannelId)
	if handle == nil {
		// Note: Nim side currently just prints to stdout on creation failure
		return nil, errors.New("failed to create ReliabilityManager (check Nim logs/stdout)")
	}
	return ReliabilityManagerHandle(handle), nil
}

// CleanupReliabilityManager frees the resources associated with the handle
func CleanupReliabilityManager(handle ReliabilityManagerHandle) {
	if handle == nil {
		return
	}
	registryMutex.Lock()
	delete(callbackRegistry, handle)
	registryMutex.Unlock()
	C.CleanupReliabilityManager(unsafe.Pointer(handle))
}

// ResetReliabilityManager resets the state of the manager
func ResetReliabilityManager(handle ReliabilityManagerHandle) error {
	if handle == nil {
		return errors.New("handle is nil")
	}
	cResult := C.ResetReliabilityManager(unsafe.Pointer(handle))
	if !cResult.is_ok {
		errMsg := C.GoString(cResult.error_message)
		C.callFreeCResultError(cResult) // Free the error message
		return errors.New(errMsg)
	}
	return nil
}

// WrapOutgoingMessage wraps a message with reliability metadata
func WrapOutgoingMessage(handle ReliabilityManagerHandle, message []byte, messageId MessageID) ([]byte, error) {
	if handle == nil {
		return nil, errors.New("handle is nil")
	}
	cMessageId := C.CString(string(messageId))
	defer C.free(unsafe.Pointer(cMessageId))

	var cMessagePtr unsafe.Pointer
	if len(message) > 0 {
		cMessagePtr = C.CBytes(message) // C.CBytes allocates memory that needs to be freed
		defer C.free(cMessagePtr)
	} else {
		cMessagePtr = nil
	}
	cMessageLen := C.size_t(len(message))

	cWrapResult := C.WrapOutgoingMessage(unsafe.Pointer(handle), cMessagePtr, cMessageLen, cMessageId)

	if !cWrapResult.base_result.is_ok {
		errMsg := C.GoString(cWrapResult.base_result.error_message)
		C.callFreeCWrapResult(cWrapResult) // Free error and potentially allocated message
		return nil, errors.New(errMsg)
	}

	// Copy the wrapped message from C memory to Go slice
	// Explicitly cast the message pointer to unsafe.Pointer
	wrappedMessage := C.GoBytes(unsafe.Pointer(cWrapResult.message), C.int(cWrapResult.message_len))
	C.callFreeCWrapResult(cWrapResult) // Free the C-allocated message buffer

	return wrappedMessage, nil
}

// UnwrapReceivedMessage unwraps a received message
func UnwrapReceivedMessage(handle ReliabilityManagerHandle, message []byte) ([]byte, []MessageID, error) {
	if handle == nil {
		return nil, nil, errors.New("handle is nil")
	}

	var cMessagePtr unsafe.Pointer
	if len(message) > 0 {
		cMessagePtr = C.CBytes(message)
		defer C.free(cMessagePtr)
	} else {
		cMessagePtr = nil
	}
	cMessageLen := C.size_t(len(message))

	cUnwrapResult := C.UnwrapReceivedMessage(unsafe.Pointer(handle), cMessagePtr, cMessageLen)

	if !cUnwrapResult.base_result.is_ok {
		errMsg := C.GoString(cUnwrapResult.base_result.error_message)
		C.callFreeCUnwrapResult(cUnwrapResult) // Free error and potentially allocated fields
		return nil, nil, errors.New(errMsg)
	}

	// Copy unwrapped message content
	// Explicitly cast the message pointer to unsafe.Pointer
	unwrappedContent := C.GoBytes(unsafe.Pointer(cUnwrapResult.message), C.int(cUnwrapResult.message_len))

	// Copy missing dependencies
	missingDeps := make([]MessageID, cUnwrapResult.missing_deps_count)
	if cUnwrapResult.missing_deps_count > 0 {
		// Convert C array of C strings to Go slice of strings
		cDepsArray := (*[1 << 30]*C.char)(unsafe.Pointer(cUnwrapResult.missing_deps))[:cUnwrapResult.missing_deps_count:cUnwrapResult.missing_deps_count]
		for i, s := range cDepsArray {
			missingDeps[i] = MessageID(C.GoString(s))
		}
	}

	C.callFreeCUnwrapResult(cUnwrapResult) // Free C-allocated message, deps array, and strings

	return unwrappedContent, missingDeps, nil
}

// MarkDependenciesMet informs the library that dependencies are met
func MarkDependenciesMet(handle ReliabilityManagerHandle, messageIDs []MessageID) error {
	if handle == nil {
		return errors.New("handle is nil")
	}
	if len(messageIDs) == 0 {
		return nil // Nothing to do
	}

	// Convert Go string slice to C array of C strings (char**)
	cMessageIDs := make([]*C.char, len(messageIDs))
	for i, id := range messageIDs {
		cMessageIDs[i] = C.CString(string(id))
		defer C.free(unsafe.Pointer(cMessageIDs[i])) // Ensure each CString is freed
	}

	// Create a pointer (**C.char) to the first element of the slice
	var cMessageIDsPtr **C.char
	if len(cMessageIDs) > 0 {
		cMessageIDsPtr = &cMessageIDs[0]
	} else {
		cMessageIDsPtr = nil // Handle empty slice case
	}

	// Pass the address of the pointer variable (&cMessageIDsPtr), which is of type ***C.char
	cResult := C.MarkDependenciesMet(unsafe.Pointer(handle), &cMessageIDsPtr, C.size_t(len(messageIDs)))

	if !cResult.is_ok {
		errMsg := C.GoString(cResult.error_message)
		C.callFreeCResultError(cResult)
		return errors.New(errMsg)
	}
	return nil
}

// RegisterCallbacks sets the Go callback functions
func RegisterCallbacks(handle ReliabilityManagerHandle, callbacks Callbacks) error {
	if handle == nil {
		return errors.New("handle is nil")
	}

	registryMutex.Lock()
	callbackRegistry[handle] = &callbacks
	registryMutex.Unlock()

	// Pass the C relay functions to Nim
	// Nim will store these function pointers. When Nim calls them, they execute the C relay,
	// Pass pointers to the exported Go functions directly.
	// Nim expects function pointers matching the C callback typedefs.
	// Cgo makes the exported Go functions available as C function pointers.
	// Cast these function pointers to unsafe.Pointer to match the void* expected by the C function.
	C.RegisterCallbacks(
		unsafe.Pointer(handle),
		unsafe.Pointer(C.goMessageReadyCallback),
		unsafe.Pointer(C.goMessageSentCallback),
		unsafe.Pointer(C.goMissingDependenciesCallback),
		unsafe.Pointer(C.goPeriodicSyncCallback),
		unsafe.Pointer(handle), // Pass handle as user_data
	)
	return nil
}

// StartPeriodicTasks starts the background tasks in the Nim library
func StartPeriodicTasks(handle ReliabilityManagerHandle) error {
	if handle == nil {
		return errors.New("handle is nil")
	}
	C.StartPeriodicTasks(unsafe.Pointer(handle))
	// Assuming StartPeriodicTasks doesn't return an error status in C API
	return nil
}

// --- Go Callback Implementations (Exported to C) ---

func goMessageReadyCallback(messageID *C.char) {
	msgIdStr := C.GoString(messageID)
	registryMutex.RLock()
	defer registryMutex.RUnlock()

	// Find the correct Go callback based on handle (this is tricky without handle passed)
	// For now, iterate through all registered callbacks. This is NOT ideal for multiple managers.
	// A better approach would involve passing the handle back through user_data if possible,
	// or maintaining a single global callback handler if only one manager instance is expected.
	// Let's assume a single instance for simplicity for now.
	for _, callbacks := range callbackRegistry {
		if callbacks != nil && callbacks.OnMessageReady != nil {
			// Run in a goroutine to avoid blocking the C thread
			go callbacks.OnMessageReady(MessageID(msgIdStr))
		}
	}
	fmt.Printf("Go: Message Ready: %s\n", msgIdStr) // Debug print
}

func goMessageSentCallback(messageID *C.char) {
	msgIdStr := C.GoString(messageID)
	registryMutex.RLock()
	defer registryMutex.RUnlock()

	for _, callbacks := range callbackRegistry {
		if callbacks != nil && callbacks.OnMessageSent != nil {
			go callbacks.OnMessageSent(MessageID(msgIdStr))
		}
	}
	fmt.Printf("Go: Message Sent: %s\n", msgIdStr) // Debug print
}

func goMissingDependenciesCallback(messageID *C.char, missingDeps **C.char, missingDepsCount C.size_t) {
	msgIdStr := C.GoString(messageID)
	deps := make([]MessageID, missingDepsCount)
	if missingDepsCount > 0 {
		// Convert C array of C strings to Go slice
		cDepsArray := (*[1 << 30]*C.char)(unsafe.Pointer(missingDeps))[:missingDepsCount:missingDepsCount]
		for i, s := range cDepsArray {
			deps[i] = MessageID(C.GoString(s))
		}
	}

	registryMutex.RLock()
	defer registryMutex.RUnlock()

	for _, callbacks := range callbackRegistry {
		if callbacks != nil && callbacks.OnMissingDependencies != nil {
			go callbacks.OnMissingDependencies(MessageID(msgIdStr), deps)
		}
	}
	fmt.Printf("Go: Missing Deps for %s: %v\n", msgIdStr, deps) // Debug print
}

func goPeriodicSyncCallback() {
	registryMutex.RLock()
	defer registryMutex.RUnlock()

	for _, callbacks := range callbackRegistry {
		if callbacks != nil && callbacks.OnPeriodicSync != nil {
			go callbacks.OnPeriodicSync()
		}
	}
	fmt.Println("Go: Periodic Sync Requested") // Debug print
}
