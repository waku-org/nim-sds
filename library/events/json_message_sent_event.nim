import std/json
import ./json_base_event, ../../src/[message]

type JsonMessageSentEvent* = ref object of JsonEvent
  messageId*: SdsMessageID

proc new*(T: type JsonMessageSentEvent, messageId: SdsMessageID): T =
  return JsonMessageSentEvent(eventType: "message_sent", messageId: messageId)

method `$`*(jsonMessageSent: JsonMessageSentEvent): string =
  $(%*jsonMessageSent)
