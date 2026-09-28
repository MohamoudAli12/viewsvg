#+build !linux
package main

import "core:fmt"

// Live reload is implemented with inotify, so it's Linux-only for now.
Watcher :: struct {}

watcher_start :: proc(w: ^Watcher, path: string) {
	fmt.eprintln("warning: live reload is not supported on this platform")
}

watcher_poll :: proc(w: ^Watcher) -> bool {
	return false
}

watcher_stop :: proc(w: ^Watcher) {}
