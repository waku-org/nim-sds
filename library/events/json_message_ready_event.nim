import std/json
import ./json_base_event, ../../src/[message]

type JsonMessageReadyEvent* = ref object of JsonEvent
  messageId*: MessageID

proc new*(T: type JsonMessageReadyEvent, messageId: MessageID): T =
  return JsonMessageReadyEvent(eventType: "message_ready", messageId: messageId)

method `$`*(jsonMessageReady: JsonMessageReadyEvent): string =
  $(%*jsonMessageReady)
