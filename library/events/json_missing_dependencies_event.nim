import std/json
import ./json_base_event, ../../src/[message]

type JsonMissingDependenciesEvent* = ref object of JsonEvent
  messageId*: SdsMessageID
  missingDeps: seq[SdsMessageID]
  channelId*: SdsChannelID

proc new*(
    T: type JsonMissingDependenciesEvent,
    messageId: SdsMessageID,
    missingDeps: seq[SdsMessageID],
    channelId: SdsChannelID,
): T =
  return JsonMissingDependenciesEvent(
    eventType: "missing_dependencies", messageId: messageId, missingDeps: missingDeps, channelId: channelId
  )

method `$`*(jsonMissingDependencies: JsonMissingDependenciesEvent): string =
  $(%*jsonMissingDependencies)
