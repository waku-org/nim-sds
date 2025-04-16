import std/json
import ./json_base_event

type JsonPeriodicSyncEvent* = ref object of JsonEvent

proc new*(T: type JsonPeriodicSyncEvent): T =
  # Returns a PeriodicSync event as indicated in
  # https://rfc.vac.dev/spec/36/#jsonmessageevent-type

  return JsonPeriodicSyncEvent(eventType: "periodic_sync")

method `$`*(jsonPeriodicSync: JsonPeriodicSyncEvent): string =
  $(%*jsonPeriodicSync)
