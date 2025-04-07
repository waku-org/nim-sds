package bindings

/*
#include <stddef.h> // For size_t
*/
import "C"
import (
	"fmt"
	"unsafe"
)

// --- Go Callback Implementations (Exported to C) ---

//export goMessageReadyCallback
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

//export goMessageSentCallback
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

//export goMissingDependenciesCallback
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

//export goPeriodicSyncCallback
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
