import std/json
import ./json_base_event, ../../src/[message]

type JsonMessageSentEvent* = ref object of JsonEvent
  messageId*: MessageID

proc new*(T: type JsonMessageSentEvent, messageId: MessageID): T =
  return JsonMessageSentEvent(eventType: "message_sent", messageId: messageId)

method `$`*(jsonMessageSent: JsonMessageSentEvent): string =
  $(%*jsonMessageSent)
