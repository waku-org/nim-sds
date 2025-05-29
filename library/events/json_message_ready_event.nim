import std/json
import ./json_base_event, ../../src/[message]

type JsonMessageReadyEvent* = ref object of JsonEvent
  messageId*: SdsMessageID

proc new*(T: type JsonMessageReadyEvent, messageId: SdsMessageID): T =
  return JsonMessageReadyEvent(eventType: "message_ready", messageId: messageId)

method `$`*(jsonMessageReady: JsonMessageReadyEvent): string =
  $(%*jsonMessageReady)
