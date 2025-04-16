import std/json
import ./json_base_event, ../../src/[message]

type JsonMessageSentEvent* = ref object of JsonEvent
  messageId*: MessageID

proc new*(T: type JsonMessageSentEvent, messageId: MessageID): T =
  # Returns a MessageSent event as indicated in
  # https://rfc.vac.dev/spec/36/#jsonmessageevent-type

  return JsonMessageSentEvent(eventType: "message_sent", messageId: messageId)

method `$`*(jsonMessageSent: JsonMessageSentEvent): string =
  $(%*jsonMessageSent)
