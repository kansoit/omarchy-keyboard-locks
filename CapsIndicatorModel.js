// Registration coordinator for the self-registered refresh bind.
//
// The widget adds its Caps_Lock bind at runtime so the dot refreshes the
// instant caps is pressed, without the user editing any config. Hyprland
// clears runtime binds on every config reload, so the shell listens for
// configreloaded and re-adds it.
//
// Several monitors mean several widget instances in the same shell. Checking
// for the bind and adding it are two hyprctl calls, so instances racing at
// startup could both decide to add it and double up. A shared module keeps a
// single slot per attempt: only the first instance of each attempt may walk
// the check-and-add path, and the rest rely on the bind that one adds plus the
// widget's own poll.
var _attempt = 0
var _claimed = -1

// Bump the attempt when runtime binds are wiped (config reload), letting the
// shell re-add the bind. Idempotent: every instance may call it.
function invalidate() {
  _attempt++
}

// Try to take the single registration slot for the current attempt. Returns
// true exactly once per attempt.
function claimRegistration() {
  if (_claimed === _attempt) return false
  _claimed = _attempt
  return true
}