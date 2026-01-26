
import chronos, chronos/selectors2

## Notice that this module extends current nim-chronos functionality to provide
## proper shutdown of the thread's dispatcher.
##
## This is necessary because nim-chronos does not provide a way to close
## the selector associated with a thread's dispatcher, which may lead to
## resource leaks.
##
## Therefore, this ideally should be contributed back to nim-chronos.

when defined(windows):
  proc safeCloseHandle(h: HANDLE): Result[void, string] =
    let res = closeHandle(h)
    if res == 0:  # WINBOOL FALSE
      return err("Failed to close handle error code: " & osErrorMsg(osLastError()))
    return ok()

  proc closeDispatcher*(loop: PDispatcher): Result[void, string] =
    ? safeCloseHandle(loop.ioPort)
    for i in loop.handles.items:
      closeHandle(i)
    loop.handles.clear()
    return ok()

elif defined(macosx) or defined(freebsd) or defined(netbsd) or
     defined(openbsd) or defined(dragonfly) or defined(macos) or
     defined(linux) or defined(android) or defined(solaris):

  proc closeDispatcher*(loop: PDispatcher): Result[void, string] =
    ## Close selector associated with current thread's dispatcher.
    try:
      loop.getIoHandler().close()
    except IOSelectorsException as e:
      return err("Exception in closeDispatcher: " & e.msg)
    return ok()

proc shutdown*(): Result[void, string] {.raises: [].} =
  ## Performs final cleanup of all dispatcher resources.
  ## Notice that this should be called only when sure that no new async tasks will be scheduled.
  ##
  ## This routine shall be called only after `pollFor` has completed. Upon
  ## invocation, all streams are assumed to have been closed.
  ## 
  ## Then, it assumes the thread's dispatcher has explicitly been stopped, destroyed and will never
  ## be used again.

  let disp = getThreadDispatcher()
  return ok()
