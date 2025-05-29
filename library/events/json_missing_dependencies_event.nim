import std/json
import ./json_base_event, ../../src/[message]

type JsonMissingDependenciesEvent* = ref object of JsonEvent
  messageId*: SdsMessageID
  missingDeps: seq[SdsMessageID]

proc new*(
    T: type JsonMissingDependenciesEvent,
    messageId: SdsMessageID,
    missingDeps: seq[SdsMessageID],
): T =
  return JsonMissingDependenciesEvent(
    eventType: "missing_dependencies", messageId: messageId, missingDeps: missingDeps
  )

method `$`*(jsonMissingDependencies: JsonMissingDependenciesEvent): string =
  $(%*jsonMissingDependencies)
