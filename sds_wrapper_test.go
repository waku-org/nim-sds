package main
import (
	"fmt"
	"sync"
	"testing"
	"time"
)

// Test basic creation, cleanup, and reset
func TestLifecycle(t *testing.T) {
	channelID := "test-lifecycle"
	handle, err := NewReliabilityManager(channelID)
	if err != nil {
		t.Fatalf("NewReliabilityManager failed: %v", err)
	}
	if handle == nil {
		t.Fatal("NewReliabilityManager returned a nil handle")
	}
	defer CleanupReliabilityManager(handle) // Ensure cleanup even on test failure

	err = ResetReliabilityManager(handle)
	if err != nil {
		t.Errorf("ResetReliabilityManager failed: %v", err)
	}
}

// Test wrapping and unwrapping a simple message
func TestWrapUnwrap(t *testing.T) {
	channelID := "test-wrap-unwrap"
	handle, err := NewReliabilityManager(channelID)
	if err != nil {
		t.Fatalf("NewReliabilityManager failed: %v", err)
	}
	defer CleanupReliabilityManager(handle)

	originalPayload := []byte("hello reliability")
	messageID := MessageID("msg-wrap-1")

	wrappedMsg, err := WrapOutgoingMessage(handle, originalPayload, messageID)
	if err != nil {
		t.Fatalf("WrapOutgoingMessage failed: %v", err)
	}
	if len(wrappedMsg) == 0 {
		t.Fatal("WrapOutgoingMessage returned empty bytes")
	}

	// Simulate receiving the wrapped message
	unwrappedPayload, missingDeps, err := UnwrapReceivedMessage(handle, wrappedMsg)
	if err != nil {
		t.Fatalf("UnwrapReceivedMessage failed: %v", err)
	}

	if string(unwrappedPayload) != string(originalPayload) {
		t.Errorf("Unwrapped payload mismatch: got %q, want %q", unwrappedPayload, originalPayload)
	}
	if len(missingDeps) != 0 {
		t.Errorf("Expected 0 missing dependencies, got %d: %v", len(missingDeps), missingDeps)
	}
}

// Test dependency handling
func TestDependencies(t *testing.T) {
	channelID := "test-deps"
	handle, err := NewReliabilityManager(channelID)
	if err != nil {
		t.Fatalf("NewReliabilityManager failed: %v", err)
	}
	defer CleanupReliabilityManager(handle)

	// 1. Send message 1 (will become a dependency)
	payload1 := []byte("message one")
	msgID1 := MessageID("msg-dep-1")
	wrappedMsg1, err := WrapOutgoingMessage(handle, payload1, msgID1)
	if err != nil {
		t.Fatalf("WrapOutgoingMessage (1) failed: %v", err)
	}
	// Simulate receiving msg1 to add it to history (implicitly acknowledges it)
	_, _, err = UnwrapReceivedMessage(handle, wrappedMsg1)
	if err != nil {
		t.Fatalf("UnwrapReceivedMessage (1) failed: %v", err)
	}

	// 2. Send message 2 (depends on message 1 implicitly via causal history)
	payload2 := []byte("message two")
	msgID2 := MessageID("msg-dep-2")
	wrappedMsg2, err := WrapOutgoingMessage(handle, payload2, msgID2)
	if err != nil {
		t.Fatalf("WrapOutgoingMessage (2) failed: %v", err)
	}

	// 3. Create a new manager to simulate a different peer receiving msg2 without msg1
	handle2, err := NewReliabilityManager(channelID) // Same channel ID
	if err != nil {
		t.Fatalf("NewReliabilityManager (2) failed: %v", err)
	}
	defer CleanupReliabilityManager(handle2)

	// 4. Unwrap message 2 on the second manager - should report msg1 as missing
	_, missingDeps, err := UnwrapReceivedMessage(handle2, wrappedMsg2)
	if err != nil {
		t.Fatalf("UnwrapReceivedMessage (2) on handle2 failed: %v", err)
	}

	if len(missingDeps) == 0 {
		t.Fatalf("Expected missing dependencies, got none")
	}
	foundDep1 := false
	for _, dep := range missingDeps {
		if dep == msgID1 {
			foundDep1 = true
			break
		}
	}
	if !foundDep1 {
		t.Errorf("Expected missing dependency %q, got %v", msgID1, missingDeps)
	}

	// 5. Mark the dependency as met
	err = MarkDependenciesMet(handle2, []MessageID{msgID1})
	if err != nil {
		t.Fatalf("MarkDependenciesMet failed: %v", err)
	}
}

// Test callbacks
func TestCallbacks(t *testing.T) {
	channelID := "test-callbacks"
	handle, err := NewReliabilityManager(channelID)
	if err != nil {
		t.Fatalf("NewReliabilityManager failed: %v", err)
	}
	defer CleanupReliabilityManager(handle)

	var wg sync.WaitGroup
	receivedReady := make(map[MessageID]bool)
	receivedSent := make(map[MessageID]bool)
	receivedMissing := make(map[MessageID][]MessageID)
	syncRequested := false
	var cbMutex sync.Mutex // Protect access to callback tracking maps/vars

	callbacks := Callbacks{
		OnMessageReady: func(messageId MessageID) {
			fmt.Printf("Test: OnMessageReady received: %s\n", messageId)
			cbMutex.Lock()
			receivedReady[messageId] = true
			cbMutex.Unlock()
			wg.Done()
		},
		OnMessageSent: func(messageId MessageID) {
			fmt.Printf("Test: OnMessageSent received: %s\n", messageId)
			cbMutex.Lock()
			receivedSent[messageId] = true
			cbMutex.Unlock()
			wg.Done()
		},
		OnMissingDependencies: func(messageId MessageID, missingDeps []MessageID) {
			fmt.Printf("Test: OnMissingDependencies received for %s: %v\n", messageId, missingDeps)
			cbMutex.Lock()
			receivedMissing[messageId] = missingDeps
			cbMutex.Unlock()
			wg.Done()
		},
		OnPeriodicSync: func() {
			fmt.Println("Test: OnPeriodicSync received")
			cbMutex.Lock()
			syncRequested = true
			cbMutex.Unlock()
			// Don't wg.Done() here, it might be called multiple times
		},
	}

	err = RegisterCallback(handle, callbacks)
	if err != nil {
		t.Fatalf("RegisterCallback failed: %v", err)
	}

	// Start tasks AFTER registering callbacks
	err = StartPeriodicTasks(handle)
	if err != nil {
		t.Fatalf("StartPeriodicTasks failed: %v", err)
	}

	// --- Test Scenario ---

	// 1. Send msg1
	wg.Add(1) // Expect OnMessageSent for msg1 eventually
	payload1 := []byte("callback test 1")
	msgID1 := MessageID("cb-msg-1")
	wrappedMsg1, err := WrapOutgoingMessage(handle, payload1, msgID1)
	if err != nil {
		t.Fatalf("WrapOutgoingMessage (1) failed: %v", err)
	}

	// 2. Receive msg1 (triggers OnMessageReady for msg1, OnMessageSent for msg1 via causal history)
	wg.Add(1) // Expect OnMessageReady for msg1
	_, _, err = UnwrapReceivedMessage(handle, wrappedMsg1)
	if err != nil {
		t.Fatalf("UnwrapReceivedMessage (1) failed: %v", err)
	}

	// 3. Send msg2 (depends on msg1)
	wg.Add(1) // Expect OnMessageSent for msg2 eventually
	payload2 := []byte("callback test 2")
	msgID2 := MessageID("cb-msg-2")
	wrappedMsg2, err := WrapOutgoingMessage(handle, payload2, msgID2)
	if err != nil {
		t.Fatalf("WrapOutgoingMessage (2) failed: %v", err)
	}

	// 4. Receive msg2 (triggers OnMessageReady for msg2, OnMessageSent for msg2)
	wg.Add(1) // Expect OnMessageReady for msg2
	_, _, err = UnwrapReceivedMessage(handle, wrappedMsg2)
	if err != nil {
		t.Fatalf("UnwrapReceivedMessage (2) failed: %v", err)
	}

	// --- Verification ---
	// Wait for expected callbacks with a timeout
	waitTimeout(&wg, 5*time.Second, t)

	cbMutex.Lock()
	defer cbMutex.Unlock()

	if !receivedReady[msgID1] {
		t.Errorf("OnMessageReady not called for %s", msgID1)
	}
	if !receivedReady[msgID2] {
		t.Errorf("OnMessageReady not called for %s", msgID2)
	}
	if !receivedSent[msgID1] {
		t.Errorf("OnMessageSent not called for %s", msgID1)
	}
	if !receivedSent[msgID2] {
		t.Errorf("OnMessageSent not called for %s", msgID2)
	}
	// We didn't explicitly test missing deps in this path
	if len(receivedMissing) > 0 {
		t.Errorf("Unexpected OnMissingDependencies calls: %v", receivedMissing)
	}
	// Periodic sync is harder to guarantee in a short test, just check if it was ever true
	if !syncRequested {
	 t.Logf("Warning: OnPeriodicSync might not have been called within the test timeout")
	}
}

// Helper function to wait for WaitGroup with a timeout
func waitTimeout(wg *sync.WaitGroup, timeout time.Duration, t *testing.T) {
	c := make(chan struct{})
	go func() {
		defer close(c)
		wg.Wait()
	}()
	select {
	case <-c:
		// Completed normally
	case <-time.After(timeout):
		t.Fatalf("Timed out waiting for callbacks")
	}
}
