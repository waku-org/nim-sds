package main

import (
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

// Test that consecutive calls return unique handles
func TestHandleUniqueness(t *testing.T) {
	channelID := "test-unique-handles"
	handle1, err1 := NewReliabilityManager(channelID)
	if err1 != nil || handle1 == nil {
		t.Fatalf("NewReliabilityManager (1) failed: %v", err1)
	}
	defer CleanupReliabilityManager(handle1)

	handle2, err2 := NewReliabilityManager(channelID)
	if err2 != nil || handle2 == nil {
		t.Fatalf("NewReliabilityManager (2) failed: %v", err2)
	}
	defer CleanupReliabilityManager(handle2)

	if handle1 == handle2 {
		t.Errorf("Expected unique handles, but both are %p", handle1)
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

// Test OnMessageReady callback
func TestCallback_OnMessageReady(t *testing.T) {
	channelID := "test-cb-ready"

	// Create sender and receiver handles
	handleSender, err := NewReliabilityManager(channelID)
	if err != nil {
		t.Fatalf("NewReliabilityManager (sender) failed: %v", err)
	}
	defer CleanupReliabilityManager(handleSender)

	handleReceiver, err := NewReliabilityManager(channelID)
	if err != nil {
		t.Fatalf("NewReliabilityManager (receiver) failed: %v", err)
	}
	defer CleanupReliabilityManager(handleReceiver)

	// Use a channel for signaling
	readyChan := make(chan MessageID, 1)

	callbacks := Callbacks{
		OnMessageReady: func(messageId MessageID) {
			// Non-blocking send to channel
			select {
			case readyChan <- messageId:
			default:
				// Avoid blocking if channel is full or test already timed out
			}
		},
	}

	// Register callback only on the receiver handle
	err = RegisterCallback(handleReceiver, callbacks)
	if err != nil {
		t.Fatalf("RegisterCallback failed: %v", err)
	}

	// Scenario: Wrap message on sender, unwrap on receiver
	payload := []byte("ready test")
	msgID := MessageID("cb-ready-1")

	// Wrap on sender
	wrappedMsg, err := WrapOutgoingMessage(handleSender, payload, msgID)
	if err != nil {
		t.Fatalf("WrapOutgoingMessage failed: %v", err)
	}

	// Unwrap on receiver
	_, _, err = UnwrapReceivedMessage(handleReceiver, wrappedMsg)
	if err != nil {
		t.Fatalf("UnwrapReceivedMessage failed: %v", err)
	}

	// Verification - Wait on channel with timeout
	select {
	case receivedMsgID := <-readyChan:
		// Mark as called implicitly since we received on channel
		if receivedMsgID != msgID {
			t.Errorf("OnMessageReady called with wrong ID: got %q, want %q", receivedMsgID, msgID)
		}
	case <-time.After(2 * time.Second):
		// If timeout occurs, the channel receive failed.
		t.Errorf("Timed out waiting for OnMessageReady callback on readyChan")
	}
}

// Test OnMessageSent callback (via causal history ACK)
func TestCallback_OnMessageSent(t *testing.T) {
	channelID := "test-cb-sent"

	// Create two handles
	handle1, err := NewReliabilityManager(channelID)
	if err != nil {
		t.Fatalf("NewReliabilityManager (1) failed: %v", err)
	}
	defer CleanupReliabilityManager(handle1)

	handle2, err := NewReliabilityManager(channelID)
	if err != nil {
		t.Fatalf("NewReliabilityManager (2) failed: %v", err)
	}
	defer CleanupReliabilityManager(handle2)

	var wg sync.WaitGroup
	sentCalled := false
	var sentMsgID MessageID
	var cbMutex sync.Mutex

	callbacks := Callbacks{
		OnMessageSent: func(messageId MessageID) {
			cbMutex.Lock()
			sentCalled = true
			sentMsgID = messageId
			cbMutex.Unlock()
			wg.Done()
		},
	}

	// Register callback on handle1 (the original sender)
	err = RegisterCallback(handle1, callbacks)
	if err != nil {
		t.Fatalf("RegisterCallback failed: %v", err)
	}

	// Scenario: handle1 sends msg1, handle2 receives msg1,
	// handle2 sends msg2 (acking msg1), handle1 receives msg2.

	// 1. handle1 sends msg1
	payload1 := []byte("sent test 1")
	msgID1 := MessageID("cb-sent-1")
	wrappedMsg1, err := WrapOutgoingMessage(handle1, payload1, msgID1)
	if err != nil {
		t.Fatalf("WrapOutgoingMessage (1) failed: %v", err)
	}
	// Note: msg1 is now in handle1's outgoing buffer

	// 2. handle2 receives msg1 (to update its state)
	_, _, err = UnwrapReceivedMessage(handle2, wrappedMsg1)
	if err != nil {
		t.Fatalf("UnwrapReceivedMessage (1) on handle2 failed: %v", err)
	}

	// 3. handle2 sends msg2 (will include msg1 in causal history)
	payload2 := []byte("sent test 2")
	msgID2 := MessageID("cb-sent-2")
	wrappedMsg2, err := WrapOutgoingMessage(handle2, payload2, msgID2)
	if err != nil {
		t.Fatalf("WrapOutgoingMessage (2) on handle2 failed: %v", err)
	}

	// 4. handle1 receives msg2 (should trigger ACK for msg1)
	wg.Add(1) // Expect OnMessageSent for msg1 on handle1
	_, _, err = UnwrapReceivedMessage(handle1, wrappedMsg2)
	if err != nil {
		t.Fatalf("UnwrapReceivedMessage (2) on handle1 failed: %v", err)
	}

	// Verification
	waitTimeout(&wg, 2*time.Second, t)

	cbMutex.Lock()
	defer cbMutex.Unlock()
	if !sentCalled {
		t.Errorf("OnMessageSent was not called")
	}
	// We primarily care that msg1 was ACKed.
	if sentMsgID != msgID1 {
		t.Errorf("OnMessageSent called with wrong ID: got %q, want %q", sentMsgID, msgID1)
	}
}

// Test OnMissingDependencies callback
func TestCallback_OnMissingDependencies(t *testing.T) {
	channelID := "test-cb-missing"

	// Use separate sender/receiver handles explicitly
	handleSender, err := NewReliabilityManager(channelID)
	if err != nil {
		t.Fatalf("NewReliabilityManager (sender) failed: %v", err)
	}
	defer CleanupReliabilityManager(handleSender)

	handleReceiver, err := NewReliabilityManager(channelID)
	if err != nil {
		t.Fatalf("NewReliabilityManager (receiver) failed: %v", err)
	}
	defer CleanupReliabilityManager(handleReceiver)

	var wg sync.WaitGroup
	missingCalled := false
	var missingMsgID MessageID
	var missingDepsList []MessageID
	var cbMutex sync.Mutex

	callbacks := Callbacks{
		OnMissingDependencies: func(messageId MessageID, missingDeps []MessageID) {
			cbMutex.Lock()
			missingCalled = true
			missingMsgID = messageId
			missingDepsList = missingDeps // Copy slice
			cbMutex.Unlock()
			wg.Done()
		},
	}

	// Register callback only on the receiver handle
	err = RegisterCallback(handleReceiver, callbacks)
	if err != nil {
		t.Fatalf("RegisterCallback failed: %v", err)
	}

	// Scenario: Sender sends msg1, then sender sends msg2 (depends on msg1),
	// then receiver receives msg2 (which hasn't seen msg1).

	// 1. Sender sends msg1
	payload1 := []byte("missing test 1")
	msgID1 := MessageID("cb-miss-1")
	_, err = WrapOutgoingMessage(handleSender, payload1, msgID1) // Assign to _
	if err != nil {
		t.Fatalf("WrapOutgoingMessage (1) on sender failed: %v", err)
	}

	// 2. Sender sends msg2 (depends on msg1)
	payload2 := []byte("missing test 2")
	msgID2 := MessageID("cb-miss-2")
	wrappedMsg2, err := WrapOutgoingMessage(handleSender, payload2, msgID2)
	if err != nil {
		t.Fatalf("WrapOutgoingMessage (2) failed: %v", err)
	}

	// 3. Receiver receives msg2 (haven't seen msg1)
	wg.Add(1) // Expect OnMissingDependencies
	_, _, err = UnwrapReceivedMessage(handleReceiver, wrappedMsg2)
	if err != nil {
		t.Fatalf("UnwrapReceivedMessage (2) on receiver failed: %v", err)
	}

	// Verification
	waitTimeout(&wg, 2*time.Second, t)

	cbMutex.Lock()
	defer cbMutex.Unlock()
	if !missingCalled {
		t.Errorf("OnMissingDependencies was not called")
	}
	if missingMsgID != msgID2 {
		t.Errorf("OnMissingDependencies called for wrong ID: got %q, want %q", missingMsgID, msgID2)
	}
	foundDep := false
	for _, dep := range missingDepsList {
		if dep == msgID1 {
			foundDep = true
			break
		}
	}
	if !foundDep {
		t.Errorf("OnMissingDependencies did not report %q as missing, got: %v", msgID1, missingDepsList)
	}
}

// Test OnPeriodicSync callback
func TestCallback_OnPeriodicSync(t *testing.T) {
	channelID := "test-cb-sync"
	handle, err := NewReliabilityManager(channelID)
	if err != nil {
		t.Fatalf("NewReliabilityManager failed: %v", err)
	}
	defer CleanupReliabilityManager(handle)

	syncCalled := false
	var cbMutex sync.Mutex
	// Use a channel to signal when the callback is hit
	syncChan := make(chan bool, 1)

	callbacks := Callbacks{
		OnPeriodicSync: func() {
			cbMutex.Lock()
			if !syncCalled { // Only signal the first time
				syncCalled = true
				syncChan <- true
			}
			cbMutex.Unlock()
		},
	}

	err = RegisterCallback(handle, callbacks)
	if err != nil {
		t.Fatalf("RegisterCallback failed: %v", err)
	}

	// Start periodic tasks
	err = StartPeriodicTasks(handle)
	if err != nil {
		t.Fatalf("StartPeriodicTasks failed: %v", err)
	}

	// --- Verification ---
	// Wait for the periodic sync callback with a timeout (needs to be longer than sync interval)
	select {
	case <-syncChan:
		// Success
	case <-time.After(10 * time.Second):
		t.Errorf("Timed out waiting for OnPeriodicSync callback")
	}

	cbMutex.Lock()
	defer cbMutex.Unlock()
	if !syncCalled {
		// This might happen if the timeout was too short
		t.Logf("Warning: OnPeriodicSync might not have been called within the test timeout")
	}
}

// Combined Test for multiple callbacks
func TestCallbacks_Combined(t *testing.T) {
	channelID := "test-cb-combined"

	// Create sender and receiver handles
	handleSender, err := NewReliabilityManager(channelID)
	if err != nil {
		t.Fatalf("NewReliabilityManager (sender) failed: %v", err)
	}
	defer CleanupReliabilityManager(handleSender)

	handleReceiver, err := NewReliabilityManager(channelID)
	if err != nil {
		t.Fatalf("NewReliabilityManager (receiver) failed: %v", err)
	}
	defer CleanupReliabilityManager(handleReceiver)

	// Channels for synchronization
	readyChan1 := make(chan bool, 1)
	sentChan1 := make(chan bool, 1)
	missingChan := make(chan []MessageID, 1)

	// Use maps for verification
	receivedReady := make(map[MessageID]bool)
	receivedSent := make(map[MessageID]bool)
	var cbMutex sync.Mutex

	callbacksReceiver := Callbacks{
		OnMessageReady: func(messageId MessageID) {
			cbMutex.Lock()
			receivedReady[messageId] = true
			cbMutex.Unlock()
			if messageId == "cb-comb-1" {
				// Use non-blocking send
				select {
				case readyChan1 <- true:
				default:
				}
			}
		},
		OnMessageSent: func(messageId MessageID) {
			// This callback is registered on Receiver, but Sent events
			// are typically relevant to the Sender. We don't expect this.
			t.Errorf("Unexpected OnMessageSent call on Receiver for %s", messageId)
		},
		OnMissingDependencies: func(messageId MessageID, missingDeps []MessageID) {
			// This callback is registered on Receiver, used for handleReceiver2 below
		},
	}

	callbacksSender := Callbacks{
		OnMessageReady: func(messageId MessageID) {
			// Not expected on sender in this test flow
		},
		OnMessageSent: func(messageId MessageID) {
			cbMutex.Lock()
			receivedSent[messageId] = true
			cbMutex.Unlock()
			if messageId == "cb-comb-1" {
				select {
				case sentChan1 <- true:
				default:
				}
			}
		},
		OnMissingDependencies: func(messageId MessageID, missingDeps []MessageID) {
			// Not expected on sender
		},
	}

	// Register callbacks
	err = RegisterCallback(handleReceiver, callbacksReceiver)
	if err != nil {
		t.Fatalf("RegisterCallback (Receiver) failed: %v", err)
	}
	err = RegisterCallback(handleSender, callbacksSender)
	if err != nil {
		t.Fatalf("RegisterCallback (Sender) failed: %v", err)
	}

	// --- Test Scenario ---
	msgID1 := MessageID("cb-comb-1")
	msgID2 := MessageID("cb-comb-2")
	msgID3 := MessageID("cb-comb-3")
	payload1 := []byte("combined test 1")
	payload2 := []byte("combined test 2")
	payload3 := []byte("combined test 3")

	// 1. Sender sends msg1
	wrappedMsg1, err := WrapOutgoingMessage(handleSender, payload1, msgID1)
	if err != nil {
		t.Fatalf("WrapOutgoingMessage (1) failed: %v", err)
	}

	// 2. Receiver receives msg1
	_, _, err = UnwrapReceivedMessage(handleReceiver, wrappedMsg1)
	if err != nil {
		t.Fatalf("UnwrapReceivedMessage (1) failed: %v", err)
	}

	// 3. Receiver sends msg2 (depends on msg1 implicitly via state)
	wrappedMsg2, err := WrapOutgoingMessage(handleReceiver, payload2, msgID2)
	if err != nil {
		t.Fatalf("WrapOutgoingMessage (2) on Receiver failed: %v", err)
	}

	// 4. Sender receives msg2 from Receiver (acks msg1 for sender)
	_, _, err = UnwrapReceivedMessage(handleSender, wrappedMsg2)
	if err != nil {
		t.Fatalf("UnwrapReceivedMessage (2) on Sender failed: %v", err)
	}

	// 5. Sender sends msg3 (depends on msg2)
	wrappedMsg3, err := WrapOutgoingMessage(handleSender, payload3, msgID3)
	if err != nil {
		t.Fatalf("WrapOutgoingMessage (3) failed: %v", err)
	}

	// 6. Create Receiver2, register missing deps callback
	handleReceiver2, err := NewReliabilityManager(channelID)
	if err != nil {
		t.Fatalf("NewReliabilityManager (Receiver2) failed: %v", err)
	}
	defer CleanupReliabilityManager(handleReceiver2)

	callbacksReceiver2 := Callbacks{
		OnMissingDependencies: func(messageId MessageID, missingDeps []MessageID) {
			if messageId == msgID3 {
				select {
				case missingChan <- missingDeps:
				default:
				}
			}
		},
	}
	err = RegisterCallback(handleReceiver2, callbacksReceiver2)
	if err != nil {
		t.Fatalf("RegisterCallback (Receiver2) failed: %v", err)
	}

	// 7. Receiver2 receives msg3 (should report missing msg1, msg2)
	_, _, err = UnwrapReceivedMessage(handleReceiver2, wrappedMsg3)
	if err != nil {
		t.Fatalf("UnwrapReceivedMessage (3) on Receiver2 failed: %v", err)
	}

	// --- Verification ---
	timeout := 5 * time.Second
	expectedReady1 := false
	expectedSent1 := false
	var reportedMissingDeps []MessageID
	missingDepsReceived := false

	receivedCount := 0
	expectedCount := 3 // ready1, sent1, missingDeps
	timer := time.NewTimer(timeout)
	defer timer.Stop()

	for receivedCount < expectedCount {
		select {
		case <-readyChan1:
			if !expectedReady1 { // Avoid double counting if signaled twice
				expectedReady1 = true
				receivedCount++
			}
		case <-sentChan1:
			if !expectedSent1 {
				expectedSent1 = true
				receivedCount++
			}
		case deps := <-missingChan:
			if !missingDepsReceived {
				reportedMissingDeps = deps
				missingDepsReceived = true
				receivedCount++
			}
		case <-timer.C:
			t.Fatalf("Timed out waiting for combined callbacks (received %d out of %d)", receivedCount, expectedCount)
		}
	}

	// Check results
	cbMutex.Lock()
	defer cbMutex.Unlock()

	if !expectedReady1 || !receivedReady[msgID1] {
		t.Errorf("OnMessageReady not called/verified for %s", msgID1)
	}
	if !expectedSent1 || !receivedSent[msgID1] {
		t.Errorf("OnMessageSent not called/verified for %s", msgID1)
	}
	if !missingDepsReceived {
		t.Errorf("OnMissingDependencies not called/verified for %s", msgID3)
	} else {
		foundDep1 := false
		foundDep2 := false
		for _, dep := range reportedMissingDeps {
			if dep == msgID1 {
				foundDep1 = true
			}
			if dep == msgID2 {
				foundDep2 = true
			}
		}
		if !foundDep1 || !foundDep2 {
			t.Errorf("OnMissingDependencies for %s reported wrong deps: got %v, want %s and %s", msgID3, reportedMissingDeps, msgID1, msgID2)
		}
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
