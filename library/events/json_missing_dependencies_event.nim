import std/json
import ./json_base_event, ../../src/[message]

type JsonMissingDependenciesEvent* = ref object of JsonEvent
  messageId*: MessageID
  missingDeps: seq[MessageID]

proc new*(
    T: type JsonMissingDependenciesEvent,
    messageId: MessageID,
    missingDeps: seq[MessageID],
): T =
  # Returns a MissingDependencies event as indicated in
  # https://rfc.vac.dev/spec/36/#jsonmessageevent-type

  return JsonMissingDependenciesEvent(
    eventType: "missing_dependencies", messageId: messageId, missingDeps: missingDeps
  )

method `$`*(jsonMissingDependencies: JsonMissingDependenciesEvent): string =
  $(%*jsonMissingDependencies)
