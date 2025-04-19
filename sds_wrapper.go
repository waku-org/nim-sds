package main

/*
#cgo CFLAGS: -I${SRCDIR}/bindings
#cgo LDFLAGS: -L${SRCDIR}/bindings/generated -lsds
#cgo LDFLAGS: -Wl,-rpath,${SRCDIR}/bindings/generated

#include <stdlib.h> // For C.free
#include "bindings/bindings.h" // Update include path

// Forward declaration for the single Go callback relay function
extern void globalCallbackRelay(void* handle, CEventType eventType, void* data1, void* data2, size_t data3);

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

// Global map to store callbacks associated with handles (needed for Go relay)
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
		return nil, errors.New("failed to create ReliabilityManager (check Nim logs/stdout)")
	}
	return ReliabilityManagerHandle(handle), nil
}

// CleanupReliabilityManager frees the resources associated with the handle
func CleanupReliabilityManager(handle ReliabilityManagerHandle) {
	if handle == nil {
		return
	}
	// Remove from Go registry first
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

	// Pass the pointer variable (cMessageIDsPtr) directly, which is of type **C.char
	cResult := C.MarkDependenciesMet(unsafe.Pointer(handle), cMessageIDsPtr, C.size_t(len(messageIDs)))

	if !cResult.is_ok {
		errMsg := C.GoString(cResult.error_message)
		C.callFreeCResultError(cResult)
		return errors.New(errMsg)
	}
	return nil
}

// RegisterCallback sets the single Go callback relay function
func RegisterCallback(handle ReliabilityManagerHandle, callbacks Callbacks) error {
	if handle == nil {
		return errors.New("handle is nil")
	}

	// Store the Go callbacks associated with this handle
	registryMutex.Lock()
	callbackRegistry[handle] = &callbacks
	registryMutex.Unlock()

	// Register the single global Go relay function with the Nim library
	// Nim will call globalCallbackRelay, passing the handle as the first argument.
	C.RegisterCallback(
		unsafe.Pointer(handle),
		(C.CEventCallback)(C.globalCallbackRelay), // Pass the Go relay function pointer
		nil,
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

// globalCallbackRelay is called by Nim for all events.
// It uses the handle to find the correct Go Callbacks struct and dispatch the call.

//export globalCallbackRelay
func globalCallbackRelay(handle unsafe.Pointer, eventType C.CEventType, data1 unsafe.Pointer, data2 unsafe.Pointer, data3 C.size_t) {
	goHandle := ReliabilityManagerHandle(handle)

	registryMutex.RLock()
	callbacks, ok := callbackRegistry[goHandle]
	registryMutex.RUnlock()

	if !ok || callbacks == nil {
		return
	}

	switch eventType {
		case C.EVENT_MESSAGE_READY:
			if callbacks.OnMessageReady != nil {
				msgIdStr := C.GoString((*C.char)(data1))
				callbacks.OnMessageReady(MessageID(msgIdStr))
			}
		case C.EVENT_MESSAGE_SENT:
			if callbacks.OnMessageSent != nil {
				msgIdStr := C.GoString((*C.char)(data1))
				callbacks.OnMessageSent(MessageID(msgIdStr))
			}
		case C.EVENT_MISSING_DEPENDENCIES:
			if callbacks.OnMissingDependencies != nil {
				msgIdStr := C.GoString((*C.char)(data1))
				depsCount := int(data3)
				deps := make([]MessageID, depsCount)
				if depsCount > 0 {
					// Convert C array of C strings (**char) to Go slice
					cDepsArray := (*[1 << 30]*C.char)(data2)[:depsCount:depsCount]
					for i, s := range cDepsArray {
						deps[i] = MessageID(C.GoString(s))
					}
				}
				callbacks.OnMissingDependencies(MessageID(msgIdStr), deps)
			}
		case C.EVENT_PERIODIC_SYNC:
			if callbacks.OnPeriodicSync != nil {
				callbacks.OnPeriodicSync()
			}
		default:
			fmt.Printf("Go: globalCallbackRelay: Received unknown event type %d for handle %v\n", eventType, goHandle)
	}
}
