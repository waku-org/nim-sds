import std/json
import ./json_base_event, ../../src/[message]

type JsonMessageReadyEvent* = ref object of JsonEvent
  messageId*: MessageID

proc new*(T: type JsonMessageReadyEvent, messageId: MessageID): T =
  # Returns a MessageReady event as indicated in
  # https://rfc.vac.dev/spec/36/#jsonmessageevent-type

  return JsonMessageReadyEvent(eventType: "message_ready", messageId: messageId)

method `$`*(jsonMessageReady: JsonMessageReadyEvent): string =
  $(%*jsonMessageReady)
